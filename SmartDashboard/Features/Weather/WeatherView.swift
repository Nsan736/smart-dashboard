import Charts
import CoreLocation
import SwiftUI

struct WeatherView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.weather
        NavigationStack {
            List {
                Section {
                    sourcePicker
                }
                if let cached = store.cached {
                    let snapshot = cached.value
                    Section(snapshot.placeName) {
                        currentView(snapshot.current)
                    }
                    Section("今後2時間の雨") {
                        rainView(snapshot)
                        NavigationLink {
                            RadarView(center: Self.coordinate(of: snapshot))
                        } label: {
                            Label("雨雲レーダー", systemImage: "cloud.rain")
                        }
                    }
                    if let coordinate = Self.coordinate(of: snapshot) {
                        Section {
                            MapContainerView(center: coordinate, spanMeters: 4000, pin: coordinate, isInteractive: false)
                                .frame(height: 170)
                                .listRowInsets(EdgeInsets())
                            NavigationLink("地図を開く") { FullMapView(center: coordinate) }
                        }
                    }
                    Section("今後24時間") {
                        hourlyView(snapshot)
                    }
                    Section("7日間") {
                        ForEach(snapshot.daily) { day in
                            dailyRow(day, offset: snapshot.utcOffsetSeconds)
                        }
                    }
                } else if !store.isLoading {
                    ContentUnavailableView("天気は未取得です", systemImage: "cloud.sun", description: Text("右上の更新ボタンで取得できます"))
                }
                Section {
                    DataStatusView(fetchedAt: store.cached?.fetchedAt, note: store.autoRefreshNote, error: store.errorMessage)
                } footer: {
                    Text("気象データ: Open-Meteo.com (CC BY 4.0)")
                }
            }
            .navigationTitle("天気")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: store.isLoading || env.rain.isLoading) {
                        await store.refreshManually()
                        await env.refreshRainManually()
                    }
                }
            }
            .refreshable {
                await store.refreshManually()
                await env.refreshRainManually()
            }
            .task {
                await store.refreshIfStale()
                await env.refreshRainIfStale()
            }
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        let settings = env.settings
        Picker("地点", selection: Binding(
            get: { settings.weatherUsesCurrentLocation ? "current" : (settings.selectedPlace?.id.uuidString ?? "current") },
            set: { newValue in
                if newValue == "current" {
                    settings.weatherUsesCurrentLocation = true
                } else {
                    settings.selectedPlaceID = UUID(uuidString: newValue)
                    settings.weatherUsesCurrentLocation = false
                }
                Task { await env.weather.refreshIfStale() }
            }
        )) {
            Label("現在地", systemImage: "location").tag("current")
            ForEach(settings.places) { place in
                Text(place.name).tag(place.id.uuidString)
            }
        }
        NavigationLink("地点を登録・編集") { PlacesEditorView() }
    }

    private func currentView(_ c: WeatherSnapshot.Current) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: WeatherCode.symbol(c.weatherCode))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 52))
                VStack(alignment: .leading) {
                    BigValue(value: String(format: "%.1f", c.temperature), unit: "°C", size: 60)
                    Text(WeatherCode.label(c.weatherCode))
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    metric("体感", String(format: "%.1f°C", c.apparentTemperature), "thermometer.medium")
                    metric("湿度", String(format: "%.0f%%", c.humidity), "humidity")
                }
                GridRow {
                    metric("風速", String(format: "%.1f m/s", c.windSpeed), "wind")
                    metric("気圧", String(format: "%.0f hPa", c.pressure), "barometer")
                }
                GridRow {
                    metric("降水量", String(format: "%.1f mm", c.precipitation), "drop")
                    Color.clear.frame(height: 1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 横スクロール。1画面にちょうど6時間分が入る幅にし、項目の途中で切れないよう時間単位で止める。
    private func hourlyView(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 0) {
                    ForEach(snapshot.upcomingHours(now: Date())) { hour in
                        VStack(spacing: 6) {
                            Text(Self.hourText(hour.time, offset: snapshot.utcOffsetSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: WeatherCode.symbol(hour.weatherCode))
                                .symbolRenderingMode(.multicolor)
                                .font(.title2)
                                .frame(height: 28)
                            Text(hour.temperature.map { String(format: "%.0f°", $0) } ?? "-")
                                .font(.headline)
                                .monospacedDigit()
                            Text(hour.precipitationProbability.map { String(format: "%.0f%%", $0) } ?? "-")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .containerRelativeFrame(.horizontal, count: 6, spacing: 0)
                    }
                }
                .scrollTargetLayout()
                .padding(.bottom, 10)
            }
            .scrollTargetBehavior(.viewAligned)
            Label("横にスクロールできます", systemImage: "arrow.left.and.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    static func coordinate(of snapshot: WeatherSnapshot) -> CLLocationCoordinate2D? {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// 雨の要約と、直近1時間(ナウキャスト、5分刻み)・今後2時間(予報モデル、15分刻み)の棒グラフ
    @ViewBuilder
    private func rainView(_ snapshot: WeatherSnapshot) -> some View {
        let now = Date()
        let slots = snapshot.upcomingRain(now: now)
        VStack(alignment: .leading, spacing: 8) {
            if let outlook = env.rainOutlook(now: now) {
                Text(outlook.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let later = outlook.later {
                    Text(later)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = outlook.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let nowcast = env.rain.cached, env.rainOutlook(now: now)?.note == nil {
                let points = Self.nowcastBars(nowcast.value, now: now)
                if !points.isEmpty {
                    Text("直近1時間(気象庁ナウキャスト・\(Formatters.ageLabel(nowcast.fetchedAt, now: now)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(points) { point in
                        BarMark(x: .value("分後", point.minutes), y: .value("強さ", point.value), width: .fixed(12))
                            .foregroundStyle(.blue)
                    }
                    .chartXScale(domain: -5...65)
                    .chartXAxis { AxisMarks(values: [0, 15, 30, 45, 60]) }
                    .chartYScale(domain: 0...max(5.0, (points.map(\.value).max() ?? 0) * 1.2))
                    .chartYAxisLabel("mm/h(目安)")
                    .frame(height: 110)
                }
            }
            if !slots.isEmpty {
                Text("今後2時間(予報モデル。15分値は1時間値からの補間)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Chart(slots) { slot in
                    BarMark(
                        x: .value("分後", Int((slot.time.timeIntervalSince(now) / 60).rounded())),
                        y: .value("降水量", slot.precipitation),
                        width: .fixed(14)
                    )
                    .foregroundStyle(.teal)
                }
                .chartXScale(domain: -15...125)
                .chartXAxis { AxisMarks(values: [0, 30, 60, 90, 120]) }
                .chartYScale(domain: 0...max(1.0, (slots.map(\.precipitation).max() ?? 0) * 1.2))
                .chartYAxisLabel("mm / 15分")
                .frame(height: 110)
            } else if env.rainOutlook(now: now) == nil {
                Text("雨の予報は未取得です").foregroundStyle(.secondary)
            }
            Text("横軸は今からの分数です。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    struct NowcastBar: Identifiable {
        let minutes: Int
        let value: Double
        var id: Int { minutes }
    }

    /// 実況を0分として、5分刻みで並べる
    static func nowcastBars(_ nowcast: RainNowcast, now: Date) -> [NowcastBar] {
        guard let observed = nowcast.points.last(where: { !$0.isForecast }) else { return [] }
        var seen = Set<Int>()
        return nowcast.points
            .filter { $0.time >= observed.time }
            .map { NowcastBar(minutes: Int(($0.time.timeIntervalSince(observed.time) / 60).rounded()), value: RainLevel.representative($0.level)) }
            .filter { $0.minutes <= 60 && seen.insert($0.minutes).inserted }
    }

    /// 1行に詰め込まず3段にする。天気のラベルは省略しない。
    private func dailyRow(_ day: WeatherSnapshot.Day, offset: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(Self.dayText(day.date, offset: offset))
                    .font(.body.weight(.semibold))
                Image(systemName: WeatherCode.symbol(day.weatherCode))
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 28)
                Spacer(minLength: 4)
                Text(day.temperatureMax.map { String(format: "%.0f°", $0) } ?? "-")
                    .foregroundStyle(.red)
                Text("/").foregroundStyle(.secondary)
                Text(day.temperatureMin.map { String(format: "%.0f°", $0) } ?? "-")
                    .foregroundStyle(.blue)
            }
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline) {
                Text(WeatherCode.label(day.weatherCode))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Label(day.precipitationProbability.map { String(format: "%.0f%%", $0) } ?? "-", systemImage: "umbrella")
                    .foregroundStyle(.blue)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.subheadline)
            Text(Self.sunText(day, offset: offset))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    static func sunText(_ day: WeatherSnapshot.Day, offset: Int) -> String {
        var parts: [String] = []
        if let sunrise = day.sunrise { parts.append("日の出 \(minuteText(sunrise, offset: offset))") }
        if let sunset = day.sunset { parts.append("日の入 \(minuteText(sunset, offset: offset))") }
        if let uv = day.uvIndexMax { parts.append(String(format: "UV %.1f", uv)) }
        return parts.joined(separator: "・")
    }

    private static func formatter(_ format: String, offset: Int) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(secondsFromGMT: offset)
        f.dateFormat = format
        return f
    }

    static func hourText(_ date: Date, offset: Int) -> String {
        formatter("H時", offset: offset).string(from: date)
    }

    static func minuteText(_ date: Date, offset: Int) -> String {
        formatter("H:mm", offset: offset).string(from: date)
    }

    static func dayText(_ date: Date, offset: Int) -> String {
        formatter("M/d(E)", offset: offset).string(from: date)
    }
}

/// 天気に使う地点(緯度経度)の登録
struct PlacesEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""

    private var parsed: SavedPlace? {
        guard let lat = Double(latitude), let lon = Double(longitude),
              (-90...90).contains(lat), (-180...180).contains(lon),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return SavedPlace(name: name.trimmingCharacters(in: .whitespaces), latitude: lat, longitude: lon)
    }

    var body: some View {
        let settings = env.settings
        Form {
            Section("登録済み") {
                if settings.places.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(settings.places) { place in
                    VStack(alignment: .leading) {
                        Text(place.name)
                        Text(String(format: "%.2f, %.2f", place.latitude, place.longitude))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { settings.places.remove(atOffsets: $0) }
                .onMove { settings.places.move(fromOffsets: $0, toOffset: $1) }
            }
            Section {
                TextField("名前(例: 自宅)", text: $name)
                TextField("緯度(例: 35.68)", text: $latitude)
                    .keyboardType(.numbersAndPunctuation)
                TextField("経度(例: 139.77)", text: $longitude)
                    .keyboardType(.numbersAndPunctuation)
                Button("追加") {
                    if let place = parsed {
                        settings.places.append(place)
                        name = ""
                        latitude = ""
                        longitude = ""
                    }
                }
                .disabled(parsed == nil)
            } header: {
                Text("地点を追加")
            } footer: {
                Text("緯度経度は小数第2位(約1km)に丸めて天気の取得に使います。")
            }
        }
        .keyboardDismissable()
        .navigationTitle("地点")
        .toolbar { EditButton() }
    }
}

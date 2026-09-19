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
                    if let latitude = snapshot.latitude, let longitude = snapshot.longitude {
                        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
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
                    Section("3日間") {
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
                    RefreshToolbarButton(isLoading: store.isLoading) { await store.refreshManually() }
                }
            }
            .refreshable { await store.refreshManually() }
            .task { await store.refreshIfStale() }
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
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hourlyView(_ snapshot: WeatherSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
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
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func dailyRow(_ day: WeatherSnapshot.Day, offset: Int) -> some View {
        HStack {
            Text(Self.dayText(day.date, offset: offset))
                .frame(width: 84, alignment: .leading)
            Image(systemName: WeatherCode.symbol(day.weatherCode))
                .symbolRenderingMode(.multicolor)
                .frame(width: 30)
            Text(WeatherCode.label(day.weatherCode))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Text(day.precipitationProbability.map { String(format: "%.0f%%", $0) } ?? "-")
                .foregroundStyle(.blue)
                .frame(width: 48, alignment: .trailing)
            Text(day.temperatureMax.map { String(format: "%.0f°", $0) } ?? "-")
                .foregroundStyle(.red)
                .frame(width: 40, alignment: .trailing)
            Text(day.temperatureMin.map { String(format: "%.0f°", $0) } ?? "-")
                .foregroundStyle(.blue)
                .frame(width: 40, alignment: .trailing)
        }
        .font(.body.weight(.medium))
        .monospacedDigit()
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
        .navigationTitle("地点")
        .toolbar { EditButton() }
    }
}

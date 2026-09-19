import SwiftUI

/// 各機能の要約をカードで並べる。ここから新しい通信は起こさず、各Storeのキャッシュを表示する。
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var motion = MotionSensors()
    @State private var device = DeviceStatus()
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    timerCard
                    nextTrainCard
                    trainInfoCard
                    weatherCard
                    exchangeCard
                    sensorCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ホーム")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: env.weather.isLoading || env.exchange.isLoading || env.trains.isLoadingInfo) {
                        await env.weather.refreshManually()
                        await env.refreshRainManually()
                        await env.exchange.refreshIfStale()
                        await env.trains.refreshInfoManually()
                    }
                }
            }
        }
        .onAppear { isVisible = true; startSensors() }
        .onDisappear { isVisible = false; stopSensors() }
        .onChange(of: scenePhase) { _, phase in
            guard isVisible else { return }
            if phase == .active { startSensors() } else { stopSensors() }
        }
    }

    private func startSensors() {
        motion.startLight()
        device.start()
    }

    private func stopSensors() {
        motion.stop()
        device.stop()
    }

    // MARK: - タイマー

    @ViewBuilder
    private var timerCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let running = env.timers.runningTimers(now: context.date)
            if !running.isEmpty || env.timers.stopwatch.isRunning {
                HomeCard(title: "タイマー", symbol: "timer") {
                    ForEach(running) { timer in
                        HStack {
                            Text(timer.label).foregroundStyle(.secondary).lineLimit(2)
                            Spacer(minLength: 8)
                            BigValue(value: TimeText.countdown(timer.remaining(now: context.date)), size: 34)
                        }
                    }
                    if env.timers.stopwatch.isRunning {
                        HStack {
                            Text("ストップウォッチ").foregroundStyle(.secondary)
                            Spacer()
                            BigValue(value: TimeText.countdown(env.timers.stopwatch.elapsed(now: context.date)), size: 34)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 電車

    @ViewBuilder
    private var nextTrainCard: some View {
        let store = env.trains
        if !store.stations.isEmpty {
            HomeCard(title: "次の電車", symbol: "tram") {
                ForEach(store.stations) { station in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(station.stationName)・\(station.directionName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let timetable = store.timetables[station.id] {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                if let next = TimetableCalculator.upcoming(in: timetable, now: context.date, count: 1, resolver: env.settings.dayTypeResolver).first {
                                    BigValue(value: NextTrainRow.countdown(to: next.date, now: context.date), size: 34)
                                    Text(NextTrainRow.describe(next)).font(.footnote)
                                } else {
                                    Text("該当する列車がありません").foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("時刻表が未ダウンロードです").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var trainInfoCard: some View {
        let store = env.trains
        if !store.lines.isEmpty {
            HomeCard(title: "運行情報", symbol: "exclamationmark.bubble", fetchedAt: store.info?.fetchedAt) {
                ForEach(store.lines) { line in
                    let item = store.info?.value.first { $0.railwayID == line.railwayID }
                    TrainStatusLine(name: line.railwayName, item: item)
                }
            }
        }
    }

    // MARK: - 天気

    private var weatherCard: some View {
        HomeCard(title: "天気", symbol: "cloud.sun", fetchedAt: env.weather.cached?.fetchedAt) {
            if let snapshot = env.weather.cached?.value {
                HStack(spacing: 14) {
                    Image(systemName: WeatherCode.symbol(snapshot.current.weatherCode))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 40))
                    BigValue(value: String(format: "%.1f", snapshot.current.temperature), unit: "°C", size: 44)
                    Spacer(minLength: 4)
                    Text(WeatherCode.label(snapshot.current.weatherCode))
                        .font(.headline)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(snapshot.placeName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let today = snapshot.daily.first {
                    HStack {
                        Text("最高 \(today.temperatureMax.map { String(format: "%.0f°", $0) } ?? "-")").foregroundStyle(.red)
                        Text("最低 \(today.temperatureMin.map { String(format: "%.0f°", $0) } ?? "-")").foregroundStyle(.blue)
                        Spacer()
                        Text("降水 \(today.precipitationProbability.map { String(format: "%.0f%%", $0) } ?? "-")")
                    }
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                if let outlook = env.rainOutlook() {
                    Label(outlook.headline, systemImage: "umbrella")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let later = outlook.later {
                        Text(later).font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = outlook.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text(env.weather.errorMessage ?? "未取得です").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 為替

    private var exchangeCard: some View {
        HomeCard(title: "為替(日次)", symbol: "yensign.circle", fetchedAt: env.exchange.cached?.fetchedAt) {
            if let rates = env.exchange.cached?.value {
                ForEach(env.settings.exchangeCodes.prefix(5), id: \.self) { code in
                    HStack {
                        Text(code).font(.headline)
                        Spacer()
                        if let yen = rates.yenPerUnit(code) {
                            BigValue(value: ExchangeView.yenText(yen), unit: "円", size: 26)
                        } else {
                            Text("-").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(env.exchange.errorMessage ?? "未取得です").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - センサー

    private var sensorCard: some View {
        HomeCard(title: "センサー", symbol: "gauge.with.dots.needle.33percent") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    sensorValue("画面の明るさ", String(format: "%.0f%%", device.brightness * 100))
                    sensorValue("歩数", motion.pedometerAvailability.unavailableText
                        ?? motion.stepsToday.map { "\($0) 歩" } ?? "-")
                }
                GridRow {
                    sensorValue("気圧", motion.altimeterAvailability.unavailableText
                        ?? motion.pressureHPa.map { String(format: "%.1f hPa", $0) } ?? "-")
                    sensorValue("外気温(予報値)", env.weather.cached.map { String(format: "%.1f°C", $0.value.current.temperature) } ?? "-")
                }
            }
        }
    }

    private func sensorValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HomeCard<Content: View>: View {
    let title: String
    let symbol: String
    var fetchedAt: Date?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let fetchedAt {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(Formatters.ageLabel(fetchedAt, now: context.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

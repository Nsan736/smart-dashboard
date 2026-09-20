import SwiftUI

/// 各機能の要約をカードで並べる。ここから新しい通信は起こさず、各Storeのキャッシュを表示する。
struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var motion = MotionSensors()
    @State private var location = LocationSensors()
    @State private var device = DeviceStatus()
    @State private var isVisible = false
    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(env.settings.homeLayout.visible) { kind in
                        card(kind)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ホーム")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("編集") { isEditing = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: env.weather.isLoading || env.exchange.isLoading || env.trains.isLoadingInfo
                                         || env.warnings.isLoading || env.quakes.isLoading) {
                        // 非表示にしたカードのデータは取得しない
                        let layout = env.settings.homeLayout
                        if layout.needsWeather { await env.weather.refreshManually() }
                        if layout.needsRain { await env.refreshRainManually() }
                        if layout.needsWarnings { await env.refreshWarningsManually() }
                        if layout.needsQuakes { await env.quakes.refreshManually() }
                        if layout.needsExchange { await env.exchange.refreshIfStale() }
                        if layout.needsTrainInfo { await env.trains.refreshInfoManually() }
                    }
                }
            }
            .sheet(isPresented: $isEditing) { HomeLayoutEditor() }
        }
        .onAppear {
            isVisible = true
            startSensors()
            // 遅れの取得は、ホームの電車カードを表示している間だけ
            updateTrainVisibility()
        }
        .onDisappear {
            isVisible = false
            stopSensors()
            env.live.setVisible("home", false)
        }
        .task { await env.live.loadIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            guard isVisible else { return }
            if phase == .active { startSensors() } else { stopSensors() }
        }
        .onChange(of: env.settings.homeLayout) { _, _ in
            guard isVisible else { return }
            startSensors()
            updateTrainVisibility()
            Task { await env.refreshStaleData() }
        }
    }

    @ViewBuilder
    private func card(_ kind: HomeCardKind) -> some View {
        switch kind {
        case .timer: timerCard
        case .nextTrain: nextTrainCard
        case .trainInfo: trainInfoCard
        case .weather: weatherCard
        case .rain: rainCard
        case .exchange: exchangeCard
        case .speed: speedCard
        case .sensors: sensorCard
        case .warnings: WarningHomeCard()
        case .quakes: QuakeHomeCard()
        case .pressure: PressureHomeCard()
        }
    }

    /// 遅れの取得は、ホームの電車カードを表示している間だけ
    private func updateTrainVisibility() {
        env.live.setVisible("home", env.settings.homeLayout.shows(.nextTrain) && !env.trains.stations.isEmpty)
    }

    private func startSensors() {
        // 非表示にしたカードのセンサーは動かさない
        let layout = env.settings.homeLayout
        let showsSpeed = layout.shows(.speed)
        motion.onPedometerUpdate = { [location] snapshot, date in location.addPedometer(snapshot, at: date) }
        if layout.shows(.sensors) || showsSpeed { motion.startLight() } else { motion.stop() }
        if layout.shows(.sensors) { device.start() } else { device.stop() }
        // 速度は高精度のGPSを使う。方位は使わない。
        if showsSpeed { location.start(includesHeading: false) } else { location.stop() }
    }

    private func stopSensors() {
        motion.stop()
        device.stop()
        location.stop()
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
                                    let live = HomeTrainLine.text(for: station, env: env, now: context.date)
                                    BigValue(value: NextTrainRow.countdown(to: next.date.addingTimeInterval(live?.delaySeconds ?? 0), now: context.date), size: 34)
                                    Text(NextTrainRow.describe(next)).font(.footnote)
                                    if let live {
                                        Text(live.text)
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(TrainColors.color(live.tone))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
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
            } else {
                Text(env.weather.errorMessage ?? "未取得です").foregroundStyle(.secondary)
            }
        }
    }

    private var rainCard: some View {
        HomeCard(title: "雨の要約", symbol: "umbrella", fetchedAt: env.rain.cached?.fetchedAt) {
            if let outlook = env.rainOutlook() {
                Text(outlook.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let later = outlook.later {
                    Text(later).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let note = outlook.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    private var speedCard: some View {
        HomeCard(title: "速度", symbol: "speedometer") {
            SpeedReadout(location: location, size: 44)
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

/// ホームの電車カードの1行。「その電車は今◯駅(あと◯駅)」。遅れがあれば補正した値を使う。
@MainActor
enum HomeTrainLine {
    static func text(for station: RegisteredStation, env: AppEnvironment, now: Date) -> (text: String, delaySeconds: TimeInterval, tone: DelaySource.Tone)? {
        guard let schedule = env.live.schedules[station.railwayID],
              let index = schedule.stationIDs.firstIndex(of: station.stationID) else { return nil }
        let line = BoardLine(railwayID: station.railwayID, name: station.railwayName, schedule: schedule,
                             shape: env.trains.shapes[station.railwayID],
                             positions: env.live.positions(for: station.railwayID, now: now, includesWaiting: true))
        guard let approach = TrainPositionCalculator.approaches(to: index, direction: station.directionID,
                                                                positions: line.positions, now: now, limit: 1).first else { return nil }
        var text = "その電車は" + TrainBoard.whereaboutsText(approach, in: line)
        if case .realtime(let seconds) = approach.position.delay, seconds >= 60 {
            text += "・" + approach.position.delay.label
        } else if approach.position.delay == .lineDelayed {
            text += "・" + approach.position.delay.label
        }
        return (text, approach.position.delay.seconds, approach.position.delay.tone)
    }
}

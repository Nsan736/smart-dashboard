import CoreLocation
import Foundation

/// スクリプトに渡すデータの出どころ(本物か、仮のデータか)。値は種類ごとの JSON の文字列。
@MainActor
protocol ScriptDataSource: AnyObject {
    /// 始めたときのデータ(setup の時点で app.* から読める)
    func initialData() -> [String: String]
    /// 変わった種類だけを onUpdate で渡す
    func start(onUpdate: @escaping ([String: String]) -> Void)
    /// 画面を閉じたとき。センサーも必ず止める。
    func stop()
    /// バックグラウンドに回ったとき(センサーも止め、戻ったら動かし直す)
    func pause()
    func resume()
    func setSensor(_ kind: ScriptSensorKind, on: Bool)
}

/// アプリがすでに取得・保存しているデータを、許可した種類だけ渡す。通信は一切しない(ディスクのキャッシュを読むだけ)。
/// 変わったかどうかは5秒ごとに作り直して比べ、変わった種類だけを渡す。センサーは ScriptSensorHub が0.1秒ごとにまとめて渡す。
@MainActor
final class ScriptLiveData: ScriptDataSource {
    static let refreshInterval = 5.0

    private let env: AppEnvironment
    let requested: [ScriptPermission]
    let granted: Set<ScriptPermission>
    private var last: [String: String] = [:]
    private var timer: Timer?
    private var onUpdate: (([String: String]) -> Void)?
    private let sensors: ScriptSensorHub?

    init(env: AppEnvironment, requested: [ScriptPermission], granted: Set<ScriptPermission>) {
        // JSON に書いていない種類は、許可の記録があっても渡さない
        let allowed = granted.intersection(requested)
        self.env = env
        self.requested = requested
        self.granted = allowed
        sensors = allowed.contains(.sensors) ? ScriptSensorHub() : nil
    }

    func initialData() -> [String: String] {
        last = build(now: Date())
        var result = last
        if let sensors { result[ScriptDataKind.sensors.rawValue] = sensors.json }
        return result
    }

    func start(onUpdate: @escaping ([String: String]) -> Void) {
        self.onUpdate = onUpdate
        sensors?.onChange = { [weak self] json in self?.onUpdate?([ScriptDataKind.sensors.rawValue: json]) }
        startTimer()
        // まだ読み込んでいないキャッシュ(ディスクだけ)を読んでから、もう一度作る
        Task { [weak self] in
            await self?.loadCaches()
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onUpdate = nil
        sensors?.stopAll()
        sensors?.onChange = nil
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        sensors?.pause()
    }

    func resume() {
        guard onUpdate != nil else { return }
        startTimer()
        refresh()
        sensors?.resume()
    }

    func setSensor(_ kind: ScriptSensorKind, on: Bool) {
        sensors?.set(kind, on: on)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard let onUpdate else { return }
        let current = build(now: Date())
        let changed = current.filter { last[$0.key] != $0.value }
        last = current
        if !changed.isEmpty { onUpdate(changed) }
    }

    private func loadCaches() async {
        if granted.contains(.weather) || granted.contains(.pressure) || granted.contains(.locationCoarse) {
            await env.weather.loadCacheIfNeeded()
        }
        if granted.contains(.weather) {
            await env.rain.loadCacheIfNeeded()
            await env.warnings.loadCacheIfNeeded()
        }
        if granted.contains(.quake) { await env.quakes.loadCacheIfNeeded() }
        if granted.contains(.exchange) { await env.exchange.loadCacheIfNeeded() }
        if granted.contains(.trains) { await env.live.loadIfNeeded() }
    }

    // MARK: - 作る

    func build(now: Date) -> [String: String] {
        var result: [String: String] = [:]
        for kind in ScriptDataKind.allCases where kind != .sensors && kind.isAllowed(granted) {
            result[kind.rawValue] = object(kind, now: now).map { ScriptJSON.string($0) } ?? "null"
        }
        return result
    }

    private var coarse: Bool { granted.contains(.locationCoarse) }
    private var precise: Bool { granted.contains(.locationPrecise) }

    private func object(_ kind: ScriptDataKind, now: Date) -> [String: Any]? {
        switch kind {
        case .weather:
            guard let cached = env.weather.cached else { return nil }
            let snapshot = cached.value
            var nowcast: RainNowcast?
            if let latitude = snapshot.latitude, let longitude = snapshot.longitude, let value = env.rain.cached?.value,
               RainNowcastStore.covers(value, latitude: latitude, longitude: longitude) {
                nowcast = value
            }
            var coordinate: ScriptAppData.Coordinate?
            if precise, let latitude = snapshot.latitude, let longitude = snapshot.longitude {
                coordinate = (latitude: latitude, longitude: longitude)
            }
            return ScriptAppData.weather(snapshot, fetchedAt: cached.fetchedAt, rain: env.rainOutlook(now: now), nowcast: nowcast,
                                         place: coarse ? weatherPlace(snapshot) : nil, coordinate: coordinate, now: now)
        case .warnings:
            guard let cached = env.warnings.cached else { return nil }
            return ScriptAppData.warnings(cached.value, fetchedAt: cached.fetchedAt, includesArea: coarse)
        case .quakes:
            guard let cached = env.quakes.cached else { return nil }
            return ScriptAppData.quakes(cached.value.quakes, fetchedAt: cached.fetchedAt,
                                        homePrefecture: coarse ? (env.currentPrefecture ?? bestLocation()?.prefecture) : nil)
        case .pressure:
            let measured = env.pressure.samples.filter { $0.time > now.addingTimeInterval(-25 * 3600) }
            let forecast = env.pressureForecast
            guard !measured.isEmpty || !forecast.isEmpty else { return nil }
            return ScriptAppData.pressure(measured: measured, forecast: forecast,
                                          change: PressureChange.make(measured: measured, forecast: forecast, now: now),
                                          latest: env.pressure.latestHPa,
                                          forecastFetchedAt: env.pressureHistory.outlookFetchedAt ?? env.weather.cached?.fetchedAt, now: now)
        case .exchange:
            guard let cached = env.exchange.cached else { return nil }
            return ScriptAppData.exchange(cached.value, fetchedAt: cached.fetchedAt, codes: env.settings.exchangeCodes)
        case .trains:
            return trains(now: now)
        case .places:
            return ScriptAppData.places(env.waypoints.waypoints, origin: placesOrigin(), includesCoordinates: precise)
        case .location:
            guard let location = bestLocation() else { return nil }
            return ScriptAppData.location(location, coarse: coarse, precise: precise)
        case .sensors:
            return nil
        case .calendar:
            return ScriptAppData.calendar(now: now, resolver: env.settings.dayTypeResolver)
        case .permissions:
            return ScriptAppData.permissions(requested: requested, granted: granted)
        }
    }

    private func trains(now: Date) -> [String: Any] {
        let store = env.trains
        let live = env.live
        let names = store.railwayNames
        let registered = store.registeredRailways.map { (railwayID: $0.railwayID, name: names[$0.railwayID] ?? ODPTID.tail($0.railwayID)) }
        let resolver = env.settings.dayTypeResolver
        let boards = store.stations.compactMap { station -> ScriptAppData.StationBoard? in
            guard let table = store.timetables[station.id] else { return nil }
            return ScriptAppData.StationBoard(station: station,
                                              upcoming: TimetableCalculator.upcoming(in: table, now: now, count: ScriptDataLimit.departures, resolver: resolver))
        }
        var items: [ScriptAppData.TrainItem] = []
        for railway in registered where items.count < ScriptDataLimit.positions {
            guard let schedule = live.schedules[railway.railwayID] else { continue }
            let line = BoardLine(railwayID: railway.railwayID, name: railway.name, schedule: schedule,
                                 shape: store.shapes[railway.railwayID], positions: [])
            for position in live.positions(for: railway.railwayID, now: now) {
                items.append(ScriptAppData.TrainItem(railwayID: railway.railwayID, railwayName: railway.name, position: position,
                                                     fromName: line.stationName(position.fromStation),
                                                     toName: line.stationName(position.toStation),
                                                     nextName: position.upcoming.first.map { line.stationName($0.station) }))
            }
        }
        return ScriptAppData.trains(info: store.info?.value ?? [], infoFetchedAt: store.info?.fetchedAt, registeredLines: registered,
                                    boards: boards, positions: items, dayType: resolver.dayType(of: now), now: now)
    }

    // MARK: - 位置(最後に分かった位置。新しく測位はしない)

    /// 天気の地点の名前(おおよその地域を許可したとき)。現在地なら都道府県と市区町村まで、登録地点なら地点の名前。
    private func weatherPlace(_ snapshot: WeatherSnapshot) -> String? {
        guard snapshot.sourceID == "current" else { return snapshot.placeName }
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return nil }
        if let place = env.placeNames.cachedPlace(latitude: latitude, longitude: longitude) {
            let name = [place.prefecture, place.municipality].compactMap { $0 }.joined()
            if !name.isEmpty { return name }
        }
        if let area = env.warnings.cached?.value.area { return area.prefecture + area.name }
        return nil
    }

    /// 端末が覚えている位置、地点の一覧で測った位置、天気の現在地のうち、一番新しいもの
    func bestLocation() -> ScriptAppData.Location? {
        var candidates: [ScriptAppData.Location] = []
        if let last = env.location.lastKnown, last.horizontalAccuracy >= 0 {
            candidates.append(ScriptAppData.Location(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude,
                                                     altitude: last.verticalAccuracy > 0 ? last.altitude : nil,
                                                     accuracy: last.horizontalAccuracy, time: last.timestamp))
        }
        if let origin = env.waypoints.origin {
            candidates.append(ScriptAppData.Location(latitude: origin.latitude, longitude: origin.longitude, altitude: origin.height,
                                                     accuracy: nil, time: origin.time))
        }
        if let cached = env.weather.cached, cached.value.sourceID == "current",
           let latitude = cached.value.latitude, let longitude = cached.value.longitude {
            candidates.append(ScriptAppData.Location(latitude: latitude, longitude: longitude, altitude: nil, accuracy: nil, time: cached.fetchedAt))
        }
        guard var best = candidates.max(by: { $0.time < $1.time }) else { return nil }
        if let place = env.placeNames.cachedPlace(latitude: best.latitude, longitude: best.longitude) {
            best.prefecture = place.prefecture
            best.city = place.municipality
        } else if let cached = env.weather.cached, cached.value.sourceID == "current",
                  let latitude = cached.value.latitude, let longitude = cached.value.longitude,
                  WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: best.latitude, longitude: best.longitude) < 3000,
                  let area = env.warnings.cached?.value.area {
            best.prefecture = area.prefecture
            best.city = area.name
        }
        return best
    }

    /// 地点の方角・距離の起点。地点の一覧で測った位置(高さつき)を使い、それより5分以上新しい位置があれば、そちらを使う。
    private func placesOrigin() -> ScriptAppData.Origin? {
        let best = bestLocation()
        if let origin = env.waypoints.origin, best.map({ $0.time.timeIntervalSince(origin.time) < 300 }) ?? true {
            return ScriptAppData.Origin(latitude: origin.latitude, longitude: origin.longitude, height: origin.height, time: origin.time)
        }
        return best.map { ScriptAppData.Origin(latitude: $0.latitude, longitude: $0.longitude, height: $0.altitude, time: $0.time) }
    }
}

/// 試しの実行とプレビューで渡す仮のデータ。JSON に書いた種類は、すべて許可したものとして扱う(実際のデータは渡さない)。
@MainActor
final class ScriptMockDataSource: ScriptDataSource {
    let requested: [ScriptPermission]
    private var active: Set<String> = []
    private var timer: Timer?
    private var onUpdate: (([String: String]) -> Void)?
    private var paused = false

    init(requested: [ScriptPermission]) {
        self.requested = requested
    }

    func initialData() -> [String: String] {
        ScriptMockData.all(requested: requested, now: Date())
    }

    func start(onUpdate: @escaping ([String: String]) -> Void) {
        self.onUpdate = onUpdate
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        active = []
        onUpdate = nil
    }

    func pause() {
        paused = true
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        paused = false
        updateTimer()
    }

    func setSensor(_ kind: ScriptSensorKind, on: Bool) {
        guard requested.contains(.sensors) else { return }
        if on { active.insert(kind.rawValue) } else { active.remove(kind.rawValue) }
        push()
        updateTimer()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard !paused, !active.isEmpty, onUpdate != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
    }

    private func push() {
        onUpdate?([ScriptDataKind.sensors.rawValue: ScriptJSON.string(ScriptMockData.sensors(now: Date(), active: active))])
    }
}

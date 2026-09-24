import CoreLocation
import Foundation
import Observation

/// 位置の提供元。実際のGPSと、デバッグの仮想の移動を差し替えられるようにする。
@MainActor
protocol MovementLocationSource: AnyObject {
    var onSample: ((RideSample) -> Void)? { get set }
    var isVirtual: Bool { get }
    func start()
    func stop()
}

/// 実際のGPS。移動タブを表示している間だけ、高精度で測位する。
@MainActor
final class GPSMovementSource: NSObject, CLLocationManagerDelegate, MovementLocationSource {
    var onSample: ((RideSample) -> Void)?
    var onAvailability: ((SensorAvailability, Bool) -> Void)?
    let isVirtual = false

    private let manager = CLLocationManager()
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        wantsUpdates = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        default:
            onAvailability?(.denied, false)
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }

    private func begin() {
        onAvailability?(.available, manager.accuracyAuthorization == .reducedAccuracy)
        manager.startUpdatingLocation()
    }

    // CLLocationManager は作成したスレッド(メイン)でデリゲートを呼ぶ
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        MainActor.assumeIsolated {
            guard wantsUpdates else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: begin()
            case .notDetermined: break
            default: onAvailability?(.denied, reduced)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CLLocation は Sendable ではないので、必要な値だけを取り出してから渡す
        let samples = locations.filter { $0.horizontalAccuracy >= 0 }.map {
            RideSample(time: $0.timestamp, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                       accuracy: $0.horizontalAccuracy, speed: $0.speedAccuracy >= 0 ? max(-1, $0.speed) : -1)
        }
        MainActor.assumeIsolated {
            for sample in samples { onSample?(sample) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let isDenied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated {
            if isDenied { onAvailability?(.denied, false) }
        }
    }
}

/// デバッグの仮想の移動。地図に引いた線や、GPXの記録に沿って、仮想の位置を出す。
@MainActor
@Observable
final class MovementDebugSession {
    enum RunState: Equatable {
        case idle
        case running
        case paused
    }

    enum Kind: Equatable {
        case route
        case gpx
    }

    var plan: VirtualPlan {
        didSet { save() }
    }
    private(set) var runState: RunState = .idle
    private(set) var kind: Kind = .route
    private(set) var mover: VirtualMover?
    private(set) var replay: GPXReplay?
    private(set) var clock = VirtualClock(start: Date())
    private(set) var lastSample: RideSample?
    private(set) var isFinished = false
    /// 地図のタップで点を置く
    var placesPoints = false
    /// 選んでいる点(移動・削除・停車の設定)
    var selectedPoint: Int?
    var gpxTrack: GPXCodec.Track?
    var gpxMessage: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generator = SystemRandomNumberGenerator()
    private static let planKey = "movement.debugPlan"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        plan = defaults.data(forKey: Self.planKey).flatMap { try? JSONDecoder().decode(VirtualPlan.self, from: $0) } ?? VirtualPlan()
    }

    var isActive: Bool { runState != .idle }

    /// 仮想の位置(GPSなしの区間でも、線の上の位置は分かる)
    var position: GeoPoint? {
        switch kind {
        case .route: return mover?.position
        case .gpx: return lastSample?.point
        }
    }

    var isInGap: Bool { kind == .route && (mover?.isInGap ?? false) }

    func startRoute(now: Date) -> Bool {
        plan.normalize()
        guard plan.points.count >= 2 else { return false }
        mover = VirtualMover(plan: plan)
        replay = nil
        kind = .route
        clock = VirtualClock(start: plan.startClock ?? now)
        lastSample = nil
        isFinished = false
        runState = .running
        return true
    }

    func startReplay(now: Date) -> Bool {
        guard let track = gpxTrack, let first = track.samples.first else { return false }
        replay = GPXReplay(samples: track.samples)
        mover = nil
        kind = .gpx
        clock = VirtualClock(start: plan.startClock ?? first.time)
        lastSample = nil
        isFinished = false
        runState = .running
        return true
    }

    func pause() { if runState == .running { runState = .paused } }
    func resume() { if runState == .paused { runState = .running } }

    func stop() {
        runState = .idle
        mover = nil
        replay = nil
        lastSample = nil
        isFinished = false
    }

    /// 実時間で realSeconds だけ進め、その間に出た位置を返す
    func step(realSeconds: TimeInterval) -> [RideSample] {
        guard runState == .running else { return [] }
        clock.advance(realSeconds: realSeconds, timeScale: plan.timeScale)
        switch kind {
        case .route:
            guard var mover else { return [] }
            mover.advance(realSeconds: realSeconds, speedKmh: plan.speedKmh, timeScale: plan.timeScale)
            self.mover = mover
            isFinished = mover.isFinished
            let noise = VirtualMover.noise(meters: plan.noiseMeters, using: &generator)
            guard let sample = mover.sample(at: clock.now, noise: noise, accuracy: max(5, plan.noiseMeters), speedKmh: plan.speedKmh) else {
                return []
            }
            lastSample = sample
            return [sample]
        case .gpx:
            guard var replay else { return [] }
            let samples = replay.advance(realSeconds: realSeconds, timeScale: plan.timeScale, clockStart: clock.start)
            self.replay = replay
            isFinished = replay.isFinished
            if let last = samples.last { lastSample = last }
            return samples
        }
    }

    /// 地図をタップした位置。選んでいる点があれば移し、なければ末尾に足す。
    func tapMap(_ point: GeoPoint) {
        guard placesPoints, !isActive else { return }
        if let selectedPoint, plan.points.indices.contains(selectedPoint) {
            plan.points[selectedPoint] = point
            self.selectedPoint = nil
        } else {
            plan.points.append(point)
        }
    }

    func removeSelectedPoint() {
        guard let selectedPoint else { return }
        plan.removePoint(at: selectedPoint)
        self.selectedPoint = nil
    }

    func clearPoints() {
        plan.points = []
        plan.stops = []
        plan.gaps = []
        selectedPoint = nil
    }

    /// 選んでいる点での停車時間(停車しないなら nil)
    func dwell(at index: Int) -> TimeInterval? {
        plan.stops.first { $0.pointIndex == index }?.dwell
    }

    func setDwell(_ dwell: TimeInterval?, at index: Int) {
        plan.stops.removeAll { $0.pointIndex == index }
        if let dwell { plan.stops.append(VirtualPlan.Stop(pointIndex: index, dwell: dwell)) }
        plan.normalize()
    }

    func loadGPX(_ data: Data) {
        if let track = GPXCodec.parse(data), track.samples.count >= 2 {
            gpxTrack = track
            gpxMessage = "\(track.samples.count)点を読み込みました(\(Int(GPXReplay(samples: track.samples).duration / 60))分間)"
        } else {
            gpxTrack = nil
            gpxMessage = "GPXとして読めませんでした(2点以上の trkpt が必要です)"
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plan) { defaults.set(data, forKey: Self.planKey) }
    }
}

/// 仮想の移動を、位置の提供元として動かす(1秒ごと)
@MainActor
final class VirtualMovementSource: MovementLocationSource {
    var onSample: ((RideSample) -> Void)?
    let isVirtual = true
    private let session: MovementDebugSession
    private var task: Task<Void, Never>?

    init(session: MovementDebugSession) {
        self.session = session
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let now = Date()
                guard let self else { return }
                for sample in self.session.step(realSeconds: now.timeIntervalSince(last)) { self.onSample?(sample) }
                last = now
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// 移動タブの位置の記録と、乗車中の判定をまとめる。
/// 位置は移動タブを表示している間だけ取得し、直近10分をメモリに持つ。記録は端末の中だけに保存し、外部には送らない。
@MainActor
@Observable
final class MovementStore {
    private(set) var judgement = RideJudgement(state: .idle)
    /// 直近10分の位置
    private(set) var recent: [RideSample] = []
    private(set) var today: MovementDay
    private(set) var gpsAvailability: SensorAvailability = .unknown
    private(set) var isReducedAccuracy = false
    let debug: MovementDebugSession

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let trains: TrainStore
    @ObservationIgnored private let live: TrainLiveStore
    @ObservationIgnored private let gps = GPSMovementSource()
    @ObservationIgnored private let virtualSource: VirtualMovementSource
    @ObservationIgnored private var detector = RideDetector()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var lineCache: (key: String, lines: [RideLine]) = ("", [])
    @ObservationIgnored private var openRide: UUID?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var dirty = false

    /// 直近の位置を持つ時間
    static let recentWindow: TimeInterval = 10 * 60

    init(directory: URL, settings: AppSettings, trains: TrainStore, live: TrainLiveStore) {
        self.directory = directory
        self.settings = settings
        self.trains = trains
        self.live = live
        let debug = MovementDebugSession()
        self.debug = debug
        virtualSource = VirtualMovementSource(session: debug)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = MovementLogPolicy.dayKey(Date())
        today = Self.load(directory.appendingPathComponent(key + ".json")) ?? MovementDay(day: key)
        gps.onSample = { [weak self] sample in self?.receive(sample, isVirtual: false) }
        gps.onAvailability = { [weak self] availability, reduced in
            self?.gpsAvailability = availability
            self?.isReducedAccuracy = reduced
        }
        virtualSource.onSample = { [weak self] sample in self?.receive(sample, isVirtual: true) }
        if !settings.rideDetectionEnabled { judgement = RideJudgement(state: .off) }
    }

    /// デバッグの仮想の移動を使っているか
    var isVirtual: Bool { debug.isActive }

    /// 列車の位置の計算に使う時刻。仮想の移動の間は、倍率で進む仮想の時刻。
    func currentTime(real: Date = Date()) -> Date {
        debug.isActive ? debug.clock.now : real
    }

    /// 移動タブの表示・非表示
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            applyRetention()
            startSource()
            loopTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        } else {
            gps.stop()
            virtualSource.stop()
            loopTask?.cancel()
            loopTask = nil
            save(force: true)
        }
    }

    private func startSource() {
        guard isVisible else { return }
        if debug.isActive {
            gps.stop()
            virtualSource.start()
        } else {
            virtualSource.stop()
            gps.start()
        }
    }

    // MARK: - デバッグ

    func startVirtualRoute() -> Bool {
        guard debug.startRoute(now: Date()) else { return false }
        restartDetection()
        startSource()
        return true
    }

    func startReplay() -> Bool {
        guard debug.startReplay(now: Date()) else { return false }
        restartDetection()
        startSource()
        return true
    }

    func stopVirtual() {
        debug.stop()
        restartDetection()
        startSource()
    }

    private func restartDetection() {
        detector.reset()
        recent = []
        openRide = nil
        judgement = RideJudgement(state: settings.rideDetectionEnabled ? .idle : .off)
    }

    // MARK: - 判定

    func setDetectionEnabled(_ enabled: Bool) {
        settings.rideDetectionEnabled = enabled
        restartDetection()
    }

    /// 手動で列車を選び直す(nil で自動に戻す)
    func selectTrain(_ trainID: String?) {
        detector.selectTrain(trainID)
        let now = currentTime()
        judgement = detector.tick(now: now, context: context(now: now))
    }

    var manualTrainID: String? { detector.manualSelection }

    /// 手動で選べる列車(判定した路線の、自分に近い順)
    func choices(now: Date) -> [RideTrainCandidate] {
        guard let railwayID = judgement.railwayID else { return [] }
        let along = judgement.along ?? 0
        return context(now: now).trains.filter { $0.railwayID == railwayID }.sorted { abs($0.along - along) < abs($1.along - along) }
    }

    /// 判定に使う路線(路線の形がある登録路線)
    func rideLines() -> [RideLine] {
        let shapes = trains.neededRailways.compactMap { trains.shapes[$0.railwayID] }
        let key = shapes.map { "\($0.railwayID):\($0.stops.count)" }.joined(separator: ",")
        if key != lineCache.key {
            let names = Dictionary(trains.lines.map { ($0.railwayID, $0.railwayName) } + trains.stations.map { ($0.railwayID, $0.railwayName) },
                                   uniquingKeysWith: { first, _ in first })
            lineCache = (key, shapes.compactMap { RideLine.make(shape: $0, name: names[$0.railwayID] ?? ODPTID.tail($0.railwayID)) })
        }
        return lineCache.lines
    }

    /// その時刻の路線と列車(時刻表から計算し、遅れで補正した位置)
    func context(now: Date) -> RideContext {
        let lines = rideLines()
        var candidates: [RideTrainCandidate] = []
        for ride in lines {
            guard let schedule = live.schedules[ride.railwayID] else { continue }
            let board = BoardLine(railwayID: ride.railwayID, name: ride.name, schedule: schedule, shape: trains.shapes[ride.railwayID],
                                  positions: live.positions(for: ride.railwayID, now: now))
            candidates += board.positions.compactMap { RideTrainCandidate.make(position: $0, line: board, ride: ride) }
        }
        return RideContext(lines: lines, trains: candidates)
    }

    private func receive(_ sample: RideSample, isVirtual: Bool) {
        // 仮想の移動を始めたあとに届いた実際のGPSの位置は使わない(取り違えないように)
        guard isVirtual == debug.isActive else { return }
        recent.append(sample)
        if let latest = recent.last?.time {
            recent.removeAll { latest.timeIntervalSince($0.time) > Self.recentWindow }
        }
        if !isVirtual { log(sample) }
        guard settings.rideDetectionEnabled else { return }
        judgement = detector.add(sample, context: context(now: sample.time))
        if !isVirtual { updateRides(now: sample.time) }
    }

    private func tick() {
        let now = currentTime()
        rollOverIfNeeded(now: Date())
        if settings.rideDetectionEnabled {
            judgement = detector.tick(now: now, context: context(now: now))
            if !debug.isActive { updateRides(now: now) }
        } else if judgement.state != .off {
            judgement = RideJudgement(state: .off)
        }
        save(force: false)
    }

    // MARK: - 記録

    private func log(_ sample: RideSample) {
        rollOverIfNeeded(now: sample.time)
        guard MovementLogPolicy.shouldAppend(sample, after: today.samples.last) else { return }
        today.samples.append(sample)
        dirty = true
    }

    /// 乗車と判定した区間を記録する
    private func updateRides(now: Date) {
        guard judgement.isRiding, let railwayID = judgement.railwayID else {
            openRide = nil
            return
        }
        let name = rideLines().first { $0.railwayID == railwayID }?.name ?? ODPTID.tail(railwayID)
        let label = judgement.trainID.flatMap { id in context(now: now).trains.first { $0.id == id }?.label }
        let confidence = judgement.confidence?.rawValue ?? 0
        if let openRide, let index = today.rides.firstIndex(where: { $0.id == openRide }), today.rides[index].railwayID == railwayID {
            today.rides[index].end = now
            if let label { today.rides[index].trainLabel = label }
            today.rides[index].confidence = max(today.rides[index].confidence, confidence)
        } else {
            let ride = MovementRide(railwayID: railwayID, railwayName: name, trainLabel: label,
                                    start: judgement.since ?? now, end: now, confidence: confidence)
            today.rides.append(ride)
            openRide = ride.id
        }
        dirty = true
    }

    private func rollOverIfNeeded(now: Date) {
        let key = MovementLogPolicy.dayKey(now)
        guard key != today.day else { return }
        save(force: true)
        today = MovementDay(day: key)
        openRide = nil
        applyRetention()
    }

    /// 保存期間を過ぎた記録を消す。「保存しない」なら、ファイルをすべて消す(今日の分はメモリにだけ残す)。
    func applyRetention() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let keys = files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        for key in MovementLogPolicy.expiredKeys(keys, today: Date(), retention: settings.movementRetention) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json"))
        }
        if settings.movementRetention != .none { dirty = true }
    }

    func clearToday() {
        today = MovementDay(day: MovementLogPolicy.dayKey(Date()))
        openRide = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(today.day + ".json"))
    }

    /// 保存した日(新しい順)
    func savedDays() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var keys = Set(files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        keys.insert(today.day)
        return keys.sorted(by: >)
    }

    func day(_ key: String) -> MovementDay? {
        key == today.day ? today : Self.load(directory.appendingPathComponent(key + ".json"))
    }

    /// GPXを一時ファイルに書き出す(共有シートに渡す)
    func exportGPX(day key: String) -> URL? {
        guard let day = day(key), !day.samples.isEmpty else { return nil }
        let text = GPXCodec.write(name: "移動の記録 \(key)", samples: day.samples, rides: day.rides)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("movement-\(key).gpx")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func save(force: Bool) {
        guard dirty, settings.movementRetention != .none else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastSave) >= 60 else { return }
        lastSave = now
        dirty = false
        if let data = try? JSONEncoder().encode(today) {
            try? data.write(to: directory.appendingPathComponent(today.day + ".json"), options: .atomic)
        }
    }

    private static func load(_ url: URL) -> MovementDay? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MovementDay.self, from: data)
    }
}

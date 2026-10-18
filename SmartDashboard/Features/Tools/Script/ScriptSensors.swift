import CoreLocation
import CoreMotion
import Foundation

/// スクリプトが app.sensors.start(名前) で使い始めるセンサー
enum ScriptSensorKind: String, CaseIterable {
    case steps
    case speed
    case heading
    case pressure
    case motion
}

/// スクリプトに渡すセンサーの値。動かしているセンサーの値だけが入る(止めたものは null)。
struct ScriptSensorSnapshot: Equatable {
    struct Steps: Equatable {
        var today: Int
        var distance: Double?
        /// 秒/m
        var pace: Double?
        /// 歩/秒
        var cadence: Double?
        var time: Date
    }

    struct Speed: Equatable {
        /// m/s。測れていなければ nil。
        var metersPerSecond: Double?
        /// 進んでいる方角(度、北=0)
        var course: Double?
        var accuracy: Double?
        var time: Date
    }

    struct Heading: Equatable {
        /// 端末の上が向いている方角(度、北=0。真北が分からなければ磁北)
        var degrees: Double
        var accuracy: Double?
        var time: Date
    }

    struct Pressure: Equatable {
        var hPa: Double
        /// 測り始めてからの高さの変化(m)
        var relativeAltitude: Double?
        var time: Date
    }

    struct Motion: Equatable {
        /// 重力を除いた加速度(G)
        var x: Double
        var y: Double
        var z: Double
        /// 傾き(度)
        var pitch: Double
        var roll: Double
        var yaw: Double
        var time: Date
    }

    var active: Set<String> = []
    var steps: Steps?
    var speed: Speed?
    var heading: Heading?
    var pressure: Pressure?
    var motion: Motion?
    /// この端末で使えるセンサー
    var available: Set<String> = []
    /// 使えなかった理由(許可がない、など)
    var problems: [String: String] = [:]

    var object: [String: Any] {
        var available: [String: Any] = [:]
        for kind in ScriptSensorKind.allCases { available[kind.rawValue] = self.available.contains(kind.rawValue) }
        var result: [String: Any] = [
            "active": active.sorted(),
            "available": available,
            "problems": problems,
            "steps": ScriptJSON.null,
            "speed": ScriptJSON.null,
            "heading": ScriptJSON.null,
            "pressure": ScriptJSON.null,
            "motion": ScriptJSON.null,
        ]
        if let steps {
            result["steps"] = ["today": steps.today, "distance": ScriptJSON.number(steps.distance, 0), "pace": ScriptJSON.number(steps.pace, 3),
                               "cadence": ScriptJSON.number(steps.cadence, 2), "time": ScriptJSON.time(steps.time)] as [String: Any]
        }
        if let speed {
            result["speed"] = ["metersPerSecond": ScriptJSON.number(speed.metersPerSecond, 2),
                               "kmh": ScriptJSON.number(speed.metersPerSecond.map { $0 * 3.6 }, 1),
                               "course": ScriptJSON.number(speed.course, 1), "accuracy": ScriptJSON.number(speed.accuracy, 2),
                               "time": ScriptJSON.time(speed.time)] as [String: Any]
        }
        if let heading {
            result["heading"] = ["degrees": ScriptJSON.number(heading.degrees, 1), "accuracy": ScriptJSON.number(heading.accuracy, 0),
                                 "time": ScriptJSON.time(heading.time)] as [String: Any]
        }
        if let pressure {
            result["pressure"] = ["hPa": ScriptJSON.number(pressure.hPa, 2), "relativeAltitude": ScriptJSON.number(pressure.relativeAltitude, 2),
                                  "time": ScriptJSON.time(pressure.time)] as [String: Any]
        }
        if let motion {
            result["motion"] = ["x": ScriptJSON.number(motion.x, 3), "y": ScriptJSON.number(motion.y, 3), "z": ScriptJSON.number(motion.z, 3),
                                "pitch": ScriptJSON.number(motion.pitch, 1), "roll": ScriptJSON.number(motion.roll, 1),
                                "yaw": ScriptJSON.number(motion.yaw, 1), "time": ScriptJSON.time(motion.time)] as [String: Any]
        }
        return result
    }

    /// 動かしているセンサーの記録(止めたセンサーの値を消す)
    mutating func setActive(_ kinds: Set<String>) {
        active = kinds
        if !kinds.contains(ScriptSensorKind.steps.rawValue) { steps = nil }
        if !kinds.contains(ScriptSensorKind.speed.rawValue) { speed = nil }
        if !kinds.contains(ScriptSensorKind.heading.rawValue) { heading = nil }
        if !kinds.contains(ScriptSensorKind.pressure.rawValue) { pressure = nil }
        if !kinds.contains(ScriptSensorKind.motion.rawValue) { motion = nil }
    }
}

/// スクリプトが頼んだセンサーだけを動かす。ツールの画面を閉じたら stopAll で必ず止める。バックグラウンドでは pause で止める。
/// 値はまとめて、0.1秒に1回まで渡す(onChange に JSON の文字列)。
@MainActor
final class ScriptSensorHub: NSObject, CLLocationManagerDelegate {
    static let pushInterval = 0.1

    private(set) var wanted: Set<ScriptSensorKind> = []
    private(set) var running: Set<ScriptSensorKind> = []
    private(set) var snapshot = ScriptSensorSnapshot()
    var onChange: ((String) -> Void)?

    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private let motionManager = CMMotionManager()
    private var locationManager: CLLocationManager?
    private var pushTimer: Timer?
    private var dirty = false
    private var paused = false

    override init() {
        super.init()
        var available = Set<String>()
        if CMPedometer.isStepCountingAvailable() { available.insert(ScriptSensorKind.steps.rawValue) }
        // 位置情報が使えるかは、測り始めたときの許可で分かる(使えなければ problems に理由を入れる)
        available.insert(ScriptSensorKind.speed.rawValue)
        if CLLocationManager.headingAvailable() { available.insert(ScriptSensorKind.heading.rawValue) }
        if CMAltimeter.isRelativeAltitudeAvailable() { available.insert(ScriptSensorKind.pressure.rawValue) }
        if motionManager.isDeviceMotionAvailable { available.insert(ScriptSensorKind.motion.rawValue) }
        snapshot.available = available
    }

    var json: String { ScriptJSON.string(snapshot.object) }

    func set(_ kind: ScriptSensorKind, on: Bool) {
        if on { wanted.insert(kind) } else { wanted.remove(kind) }
        guard !paused else { return }
        if on { begin(kind) } else { end(kind) }
        updateActive()
    }

    /// すべて止めて、頼まれた記録も消す(画面を閉じたとき)
    func stopAll() {
        for kind in running { end(kind) }
        wanted = []
        paused = false
        pushTimer?.invalidate()
        pushTimer = nil
        snapshot.setActive([])
        locationManager?.delegate = nil
        locationManager = nil
    }

    /// バックグラウンドに回ったとき。頼まれた記録は残し、戻ったら resume で動かし直す。
    func pause() {
        guard !paused else { return }
        paused = true
        for kind in running { end(kind) }
        updateActive()
    }

    func resume() {
        guard paused else { return }
        paused = false
        for kind in wanted { begin(kind) }
        updateActive()
    }

    private func updateActive() {
        snapshot.setActive(Set(running.map(\.rawValue)))
        markDirty()
        if running.isEmpty {
            pushTimer?.invalidate()
            pushTimer = nil
            flush()
        } else if pushTimer == nil {
            pushTimer = Timer.scheduledTimer(withTimeInterval: Self.pushInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    private func markDirty() { dirty = true }

    private func flush() {
        guard dirty else { return }
        dirty = false
        onChange?(json)
    }

    // MARK: - 開始と停止

    private func begin(_ kind: ScriptSensorKind) {
        guard !running.contains(kind) else { return }
        guard snapshot.available.contains(kind.rawValue) else {
            snapshot.problems[kind.rawValue] = "この端末では使えません"
            return
        }
        switch kind {
        case .steps:
            let start = JapaneseHolidays.calendar.startOfDay(for: Date())
            pedometer.startUpdates(from: start) { [weak self] data, error in
                let value = data.map { (steps: $0.numberOfSteps.intValue, distance: $0.distance?.doubleValue,
                                        pace: $0.currentPace?.doubleValue, cadence: $0.currentCadence?.doubleValue) }
                let failed = error != nil
                Task { @MainActor in
                    guard let self, self.running.contains(.steps) else { return }
                    if let value {
                        self.snapshot.steps = .init(today: value.steps, distance: value.distance, pace: value.pace, cadence: value.cadence, time: Date())
                    } else if failed {
                        self.snapshot.problems[ScriptSensorKind.steps.rawValue] = "歩数を読めません(モーションとフィットネスの許可を確認してください)"
                    }
                    self.markDirty()
                }
            }
        case .pressure:
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                let hPa = data.pressure.doubleValue * 10
                let altitude = data.relativeAltitude.doubleValue
                MainActor.assumeIsolated {
                    guard let self, self.running.contains(.pressure) else { return }
                    self.snapshot.pressure = .init(hPa: hPa, relativeAltitude: altitude, time: Date())
                    self.markDirty()
                }
            }
        case .motion:
            motionManager.deviceMotionUpdateInterval = 1.0 / 30
            motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let motion else { return }
                let a = motion.userAcceleration
                let attitude = motion.attitude
                let degrees = 180 / Double.pi
                MainActor.assumeIsolated {
                    guard let self, self.running.contains(.motion) else { return }
                    self.snapshot.motion = .init(x: a.x, y: a.y, z: a.z, pitch: attitude.pitch * degrees, roll: attitude.roll * degrees,
                                                 yaw: attitude.yaw * degrees, time: Date())
                    self.markDirty()
                }
            }
        case .speed:
            let manager = ensureLocationManager()
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: snapshot.problems[kind.rawValue] = "位置情報の許可がないため、速度を測れません"
            default: break
            }
            manager.startUpdatingLocation()
        case .heading:
            let manager = ensureLocationManager()
            manager.headingFilter = 1
            manager.startUpdatingHeading()
        }
        running.insert(kind)
    }

    private func end(_ kind: ScriptSensorKind) {
        guard running.contains(kind) else { return }
        running.remove(kind)
        switch kind {
        case .steps: pedometer.stopUpdates()
        case .pressure: altimeter.stopRelativeAltitudeUpdates()
        case .motion: motionManager.stopDeviceMotionUpdates()
        case .speed: locationManager?.stopUpdatingLocation()
        case .heading: locationManager?.stopUpdatingHeading()
        }
    }

    private func ensureLocationManager() -> CLLocationManager {
        if let locationManager { return locationManager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        locationManager = manager
        return manager
    }

    // MARK: - CLLocationManagerDelegate(メインスレッドで作ったので、メインスレッドで呼ばれる)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let speed = location.speedAccuracy >= 0 && location.speed >= 0 ? location.speed : nil
        let course = location.courseAccuracy >= 0 && location.course >= 0 ? location.course : nil
        let accuracy = location.speedAccuracy >= 0 ? location.speedAccuracy : nil
        let time = location.timestamp
        MainActor.assumeIsolated {
            guard running.contains(.speed) else { return }
            snapshot.speed = .init(metersPerSecond: speed, course: course, accuracy: accuracy, time: time)
            snapshot.problems[ScriptSensorKind.speed.rawValue] = nil
            markDirty()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        let accuracy = newHeading.headingAccuracy >= 0 ? newHeading.headingAccuracy : nil
        let time = newHeading.timestamp
        MainActor.assumeIsolated {
            guard running.contains(.heading) else { return }
            snapshot.heading = .init(degrees: degrees, accuracy: accuracy, time: time)
            markDirty()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if running.contains(.speed) {
                snapshot.problems[ScriptSensorKind.speed.rawValue] = "現在地を測れません"
                markDirty()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status == .denied || status == .restricted, running.contains(.speed) {
                snapshot.problems[ScriptSensorKind.speed.rawValue] = "位置情報の許可がないため、速度を測れません"
                markDirty()
            }
        }
    }
}

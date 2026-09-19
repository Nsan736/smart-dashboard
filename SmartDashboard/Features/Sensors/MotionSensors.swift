import CoreMotion
import Foundation
import Observation

/// 気圧・相対高度、加速度・傾き、歩数。表示中だけ動かす。
@MainActor
@Observable
final class MotionSensors {
    private(set) var altimeterAvailability: SensorAvailability = .unknown
    private(set) var pressureHPa: Double?
    private(set) var relativeAltitude: Double?

    private(set) var motionAvailability: SensorAvailability = .unknown
    /// 重力を含まないユーザー加速度の大きさ(G)
    private(set) var accelerationG: Double?
    /// 傾き(度)。端末を平らに置いたとき両方0。
    private(set) var pitchDegrees: Double?
    private(set) var rollDegrees: Double?

    private(set) var pedometerAvailability: SensorAvailability = .unknown
    private(set) var stepsToday: Int?
    private(set) var walkingDistanceToday: Double?
    /// 現在のペース(秒/m)と歩調(歩/秒)。歩いている間だけ値が入る。
    private(set) var currentPace: Double?
    private(set) var currentCadence: Double?
    private(set) var lastPedometerUpdate: Date?

    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private let pedometer = CMPedometer()

    func start() {
        startAltimeter()
        startMotion()
        startPedometer()
    }

    /// ホーム用。消費の小さい気圧と歩数だけを動かす。
    func startLight() {
        startAltimeter()
        startPedometer()
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        motion.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
    }

    private static var isDenied: Bool {
        let status = CMMotionActivityManager.authorizationStatus()
        return status == .denied || status == .restricted
    }

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            altimeterAvailability = .unsupported
            return
        }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data {
                    self.altimeterAvailability = .available
                    self.pressureHPa = data.pressure.doubleValue * 10
                    self.relativeAltitude = data.relativeAltitude.doubleValue
                } else if error != nil {
                    self.altimeterAvailability = Self.isDenied ? .denied : .unsupported
                }
            }
        }
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            motionAvailability = .unsupported
            return
        }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let data else {
                    if error != nil { self.motionAvailability = .unsupported }
                    return
                }
                self.motionAvailability = .available
                let a = data.userAcceleration
                self.accelerationG = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                let tilt = Self.tilt(gravityX: data.gravity.x, gravityY: data.gravity.y, gravityZ: data.gravity.z)
                self.pitchDegrees = tilt.pitch
                self.rollDegrees = tilt.roll
            }
        }
    }

    /// 重力ベクトルから、平置きを基準にした前後(pitch)と左右(roll)の傾きを求める
    nonisolated static func tilt(gravityX x: Double, gravityY y: Double, gravityZ z: Double) -> (pitch: Double, roll: Double) {
        let pitch = atan2(y, (x * x + z * z).squareRoot()) * 180 / .pi
        let roll = atan2(x, (y * y + z * z).squareRoot()) * 180 / .pi
        return (-pitch, roll)
    }

    /// 歩数は継続的に受け取る。CMPedometer の更新は歩いたときに数秒おきにまとめて届き、
    /// 止まっている間は届かないので、最初の値だけは問い合わせて表示する。
    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else {
            pedometerAvailability = .unsupported
            return
        }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        pedometer.stopUpdates()
        pedometer.queryPedometerData(from: startOfDay, to: Date()) { [weak self] data, error in
            let snapshot = data.map { PedometerSnapshot($0) }
            let failed = error != nil
            Task { @MainActor in self?.applyPedometer(snapshot, failed: failed, isLiveUpdate: false) }
        }
        pedometer.startUpdates(from: startOfDay) { [weak self] data, error in
            let snapshot = data.map { PedometerSnapshot($0) }
            let failed = error != nil
            Task { @MainActor in self?.applyPedometer(snapshot, failed: failed, isLiveUpdate: true) }
        }
    }

    /// コールバックは任意のスレッドで呼ばれるので、状態の更新は必ず MainActor で行う
    private func applyPedometer(_ snapshot: PedometerSnapshot?, failed: Bool, isLiveUpdate: Bool) {
        guard let snapshot else {
            if failed { pedometerAvailability = Self.isDenied ? .denied : .unsupported }
            return
        }
        pedometerAvailability = .available
        // 問い合わせの結果が、あとから届いた新しい更新を上書きしないようにする
        if !isLiveUpdate, let current = stepsToday, current > snapshot.steps { return }
        stepsToday = snapshot.steps
        walkingDistanceToday = snapshot.distance
        if isLiveUpdate {
            currentPace = snapshot.pace
            currentCadence = snapshot.cadence
            lastPedometerUpdate = Date()
        }
    }
}

/// CMPedometerData から必要な値だけを取り出したもの(スレッドをまたいで渡せるようにする)
struct PedometerSnapshot: Sendable, Equatable {
    var steps: Int
    var distance: Double?
    /// 現在のペース(秒/m)
    var pace: Double?
    /// 現在の歩調(歩/秒)
    var cadence: Double?

    init(steps: Int, distance: Double?, pace: Double?, cadence: Double?) {
        self.steps = steps
        self.distance = distance
        self.pace = pace
        self.cadence = cadence
    }

    init(_ data: CMPedometerData) {
        self.init(steps: data.numberOfSteps.intValue, distance: data.distance?.doubleValue,
                  pace: data.currentPace?.doubleValue, cadence: data.currentCadence?.doubleValue)
    }

    /// 「8分20秒/km」
    static func paceText(secondsPerMeter: Double?) -> String? {
        guard let secondsPerMeter, secondsPerMeter > 0, secondsPerMeter.isFinite else { return nil }
        let perKm = Int((secondsPerMeter * 1000).rounded())
        guard perKm < 3600 else { return nil }
        return "\(perKm / 60)分\(String(format: "%02d", perKm % 60))秒/km"
    }

    /// 「112歩/分」
    static func cadenceText(stepsPerSecond: Double?) -> String? {
        guard let stepsPerSecond, stepsPerSecond > 0, stepsPerSecond.isFinite else { return nil }
        return "\(Int((stepsPerSecond * 60).rounded()))歩/分"
    }
}

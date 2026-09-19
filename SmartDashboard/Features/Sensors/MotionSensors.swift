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

    private func startPedometer() {
        guard CMPedometer.isStepCountingAvailable() else {
            pedometerAvailability = .unsupported
            return
        }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        pedometer.startUpdates(from: startOfDay) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    self.pedometerAvailability = .available
                    self.stepsToday = data.numberOfSteps.intValue
                    self.walkingDistanceToday = data.distance?.doubleValue
                } else if error != nil {
                    self.pedometerAvailability = Self.isDenied ? .denied : .unsupported
                }
            }
        }
    }
}

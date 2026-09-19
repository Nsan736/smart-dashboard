import CoreLocation
import Foundation
import Observation

enum SensorAvailability: Equatable {
    case unknown
    case available
    case denied
    case unsupported

    var unavailableText: String? {
        switch self {
        case .unknown, .available: return nil
        case .denied: return "利用不可(権限なし)"
        case .unsupported: return "利用不可(この環境では使えません)"
        }
    }
}

/// 速度の記録(最高・平均・距離)。純粋な計算だけを持つ。
struct TripRecorder: Equatable {
    private(set) var isRecording = false
    private(set) var distance: CLLocationDistance = 0
    private(set) var maxSpeed: CLLocationSpeed = 0
    private(set) var movingTime: TimeInterval = 0
    private var last: (coordinate: CLLocationCoordinate2D, time: Date)?

    static func == (lhs: TripRecorder, rhs: TripRecorder) -> Bool {
        lhs.isRecording == rhs.isRecording && lhs.distance == rhs.distance
            && lhs.maxSpeed == rhs.maxSpeed && lhs.movingTime == rhs.movingTime
    }

    /// 平均速度(m/s)。記録した時間に対する平均。
    var averageSpeed: CLLocationSpeed { movingTime > 0 ? distance / movingTime : 0 }

    mutating func start() { isRecording = true; last = nil }
    mutating func stop() { isRecording = false; last = nil }
    mutating func reset() { self = TripRecorder(isRecording: isRecording) }

    private init(isRecording: Bool) { self.isRecording = isRecording }
    init() {}

    /// 精度の悪い測位や、時間の飛んだ測位は距離に入れない
    mutating func add(coordinate: CLLocationCoordinate2D, speed: CLLocationSpeed, horizontalAccuracy: CLLocationAccuracy, time: Date) {
        guard isRecording, horizontalAccuracy >= 0, horizontalAccuracy <= 50 else { return }
        if speed >= 0 { maxSpeed = max(maxSpeed, speed) }
        if let last {
            let dt = time.timeIntervalSince(last.time)
            if dt > 0, dt <= 30 {
                let a = CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
                let b = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                distance += b.distance(from: a)
                movingTime += dt
            }
        }
        last = (coordinate, time)
    }
}

/// 速度、GPS高度、方位。表示中だけ動かす。
@MainActor
@Observable
final class LocationSensors: NSObject, CLLocationManagerDelegate {
    private(set) var availability: SensorAvailability = .unknown
    private(set) var speed: CLLocationSpeed?
    private(set) var altitude: CLLocationDistance?
    private(set) var horizontalAccuracy: CLLocationAccuracy?
    private(set) var heading: CLLocationDirection?
    private(set) var headingAvailable = CLLocationManager.headingAvailable()
    private(set) var trip = TripRecorder()

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .otherNavigation
        manager.headingFilter = 2
    }

    func start() {
        wantsUpdates = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            availability = .denied
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        speed = nil
        if trip.isRecording { trip.stop() }
    }

    func startTrip() { trip.start() }
    func stopTrip() { trip.stop() }
    func resetTrip() { trip.reset() }

    private func beginUpdates() {
        availability = .available
        manager.startUpdatingLocation()
        if headingAvailable { manager.startUpdatingHeading() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard wantsUpdates else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: beginUpdates()
            case .notDetermined: break
            default: availability = .denied
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                speed = location.speed >= 0 ? location.speed : nil
                altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
                horizontalAccuracy = location.horizontalAccuracy
                trip.add(coordinate: location.coordinate, speed: location.speed,
                         horizontalAccuracy: location.horizontalAccuracy, time: location.timestamp)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in
            heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if (error as? CLError)?.code == .denied { availability = .denied }
        }
    }

    static func compassLabel(_ degrees: Double) -> String {
        let names = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]
        let index = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return names[index]
    }
}

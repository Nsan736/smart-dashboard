import CoreLocation
import Foundation
import Observation
import UIKit

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

/// 画面を消さない指定を、理由ごとにまとめて管理する(タイマーとセンサー画面が互いに打ち消さないようにする)
@MainActor
enum ScreenAwake {
    private static var reasons: Set<String> = []

    static func set(_ reason: String, _ isOn: Bool) {
        if isOn { reasons.insert(reason) } else { reasons.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}

/// 速度、GPS高度、方位をリアルタイムに取得する。
/// 高精度の測位を続けるので、画面が表示されている間だけ動かし、離れたら必ず止める。
/// 天気用の1回だけの取得(LocationProvider)とは別のインスタンスにしている。
@MainActor
@Observable
final class LocationSensors: NSObject, CLLocationManagerDelegate {
    private(set) var availability: SensorAvailability = .unknown
    /// 位置の精度が「おおよそ」に制限されている(速度は測れない)
    private(set) var isReducedAccuracy = false
    private(set) var estimator = SpeedEstimator()
    private(set) var altitude: CLLocationDistance?
    private(set) var horizontalAccuracy: CLLocationAccuracy?
    /// 最後に測位した時刻(精度の良し悪しにかかわらず)
    private(set) var lastUpdate: Date?
    private(set) var heading: CLLocationDirection?
    private(set) var headingAvailable = CLLocationManager.headingAvailable()

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var wantsUpdates = false
    @ObservationIgnored private var includesHeading = true

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 2
    }

    /// 画面に出す速度と、その求め方(GPS → 位置の差分 → 歩行ペース → 停止中 の順)
    func reading(now: Date) -> SpeedReading {
        estimator.reading(now: now)
    }

    /// 歩数計の更新を渡す。屋内や地下で、GPSの代わりに歩行ペースから速度を出すために使う。
    func addPedometer(_ snapshot: PedometerSnapshot, at date: Date) {
        estimator.addPedometer(steps: snapshot.steps, distance: snapshot.distance, secondsPerMeter: snapshot.pace, at: date)
    }

    func start(includesHeading: Bool = true) {
        self.includesHeading = includesHeading
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
    }

    /// 最高速度・平均速度・移動距離を0に戻す
    func resetStatistics() {
        estimator.resetStatistics()
    }

    private func beginUpdates() {
        availability = .available
        isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        manager.startUpdatingLocation()
        if includesHeading, headingAvailable { manager.startUpdatingHeading() }
    }

    // MARK: - CLLocationManagerDelegate
    // CLLocationManager は、作成したスレッド(ここではメイン)のRunLoopでデリゲートを呼ぶ。
    // そのため assumeIsolated で同期的に状態を更新でき、測位の順序も保たれる。

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            guard wantsUpdates else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: beginUpdates()
            case .notDetermined: break
            default: availability = .denied
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CLLocation は Sendable ではないので、必要な値だけを取り出してから渡す
        var samples: [SpeedSample] = []
        var altitudes: [Double?] = []
        for location in locations {
            samples.append(SpeedSample(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                       speed: location.speed, speedAccuracy: location.speedAccuracy,
                                       horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp))
            altitudes.append(location.verticalAccuracy >= 0 ? location.altitude : nil)
        }
        let fixes = samples
        let heights = altitudes
        MainActor.assumeIsolated {
            for (index, sample) in fixes.enumerated() {
                estimator.add(sample)
                horizontalAccuracy = sample.horizontalAccuracy
                lastUpdate = sample.timestamp
                if let value = heights[index] { altitude = value }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        MainActor.assumeIsolated { heading = value }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let isDenied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated {
            if isDenied { availability = .denied }
        }
    }

    static func compassLabel(_ degrees: Double) -> String {
        let names = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]
        let index = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        return names[index]
    }
}

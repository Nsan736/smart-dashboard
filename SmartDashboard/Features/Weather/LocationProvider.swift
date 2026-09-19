import CoreLocation
import Foundation

enum LocationError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied: return "位置情報が利用不可です。登録した地点を使ってください。"
        case .unavailable: return "現在地を取得できませんでした。"
        }
    }
}

/// 現在地を100m程度の精度で1回だけ取得する。取得したら測位は止まる(requestLocation)ので、電池を消費し続けない。
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            scheduleTimeout()
            await withCheckedContinuation { authContinuation = $0 }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: throw LocationError.denied
        }
        // 直前の測位が十分新しく、精度もよければ使い回す
        if let last = manager.location, abs(last.timestamp.timeIntervalSinceNow) < 300,
           last.horizontalAccuracy >= 0, last.horizontalAccuracy <= 200 {
            return last
        }
        guard locationContinuation == nil else { throw LocationError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            scheduleTimeout()
            manager.requestLocation()
        }
    }

    /// 権限の応答や測位結果が返ってこない環境でも待ち続けないようにする
    private func scheduleTimeout() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.authContinuation?.resume()
            self?.authContinuation = nil
            self?.locationContinuation?.resume(throwing: LocationError.unavailable)
            self?.locationContinuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            authContinuation?.resume()
            authContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else { return }
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(throwing: LocationError.unavailable)
            locationContinuation = nil
        }
    }
}

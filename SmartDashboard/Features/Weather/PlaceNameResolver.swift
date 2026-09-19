import CoreLocation
import Foundation

/// 逆ジオコーディングの結果(座標ごとのキャッシュ)
struct GeocodedPlace: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var name: String
}

/// 現在地の地名を求める。500m以上移動したときだけCLGeocoderに問い合わせる。
@MainActor
final class PlaceNameResolver {
    static let reuseDistance: CLLocationDistance = 500
    static let maxEntries = 30

    private let defaults: UserDefaults
    private let geocoder = CLGeocoder()
    private var entries: [GeocodedPlace]
    /// CLGeocoderに問い合わせた回数の記録用(通信量はiOS側で発生し、アプリからは計測できない)
    private let onRequest: @MainActor () -> Void

    init(defaults: UserDefaults = .standard, onRequest: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults
        self.onRequest = onRequest
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([GeocodedPlace].self, from: $0) } ?? []
    }

    /// キャッシュにあれば通信しない。取得できなければnil。
    func name(latitude: Double, longitude: Double) async -> String? {
        if let hit = Self.nearest(in: entries, latitude: latitude, longitude: longitude, within: Self.reuseDistance) {
            return hit.name
        }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        onRequest()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ja_JP")).first,
              let name = Self.formatName(administrativeArea: placemark.administrativeArea, locality: placemark.locality,
                                         subLocality: placemark.subLocality, fallback: placemark.name) else {
            return nil
        }
        entries.append(GeocodedPlace(latitude: latitude, longitude: longitude, name: name))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
        return name
    }

    func clear() {
        entries = []
        defaults.removeObject(forKey: Self.key)
    }

    nonisolated static func nearest(in entries: [GeocodedPlace], latitude: Double, longitude: Double,
                                    within limit: CLLocationDistance) -> GeocodedPlace? {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        return entries
            .map { ($0, here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.1 < limit }
            .min { $0.1 < $1.1 }?.0
    }

    /// 例: 「東京都新宿区西新宿」
    nonisolated static func formatName(administrativeArea: String?, locality: String?, subLocality: String?, fallback: String?) -> String? {
        var parts: [String] = []
        for part in [administrativeArea, locality, subLocality] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) }
        }
        if parts.isEmpty { return fallback?.isEmpty == false ? fallback : nil }
        return parts.joined()
    }

    private static let key = "weather.geocodedPlaces"
}

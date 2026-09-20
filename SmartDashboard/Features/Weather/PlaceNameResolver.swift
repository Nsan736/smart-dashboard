import CoreLocation
import Foundation

/// 逆ジオコーディングの結果(座標ごとのキャッシュ)
struct GeocodedPlace: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var name: String
    /// 都道府県名と市区町村名(警報の地域を決めるのに使う)。古い記録にはない。
    var prefecture: String?
    var municipality: String?
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
        await place(latitude: latitude, longitude: longitude)?.name
    }

    /// 地名に加えて、都道府県名と市区町村名も返す。500m以内で取得済みならキャッシュを使う。
    func place(latitude: Double, longitude: Double) async -> GeocodedPlace? {
        if let hit = Self.nearest(in: entries, latitude: latitude, longitude: longitude, within: Self.reuseDistance),
           hit.prefecture != nil {
            return hit
        }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        onRequest()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "ja_JP")).first,
              let name = Self.formatName(administrativeArea: placemark.administrativeArea, locality: placemark.locality,
                                         subLocality: placemark.subLocality, fallback: placemark.name) else {
            return nil
        }
        // 都道府県名のない古い記録は置き換える
        entries.removeAll { $0.prefecture == nil && CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: location) < Self.reuseDistance }
        let place = GeocodedPlace(latitude: latitude, longitude: longitude, name: name,
                                  prefecture: placemark.administrativeArea ?? "", municipality: placemark.locality)
        entries.append(place)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
        return place
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

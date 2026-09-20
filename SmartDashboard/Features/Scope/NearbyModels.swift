import Foundation
import SwiftUI

/// 周辺の施設のカテゴリ。検索は MapKit(MKLocalSearch)で行い、APIキーは使わない。
enum NearbyCategory: String, CaseIterable, Identifiable, Codable {
    case convenience
    case station
    case restroom
    case cafe
    case restaurant
    case atm
    case pharmacy
    case parking
    case park

    var id: String { rawValue }

    var label: String {
        switch self {
        case .convenience: return "コンビニ"
        case .station: return "駅"
        case .restroom: return "トイレ"
        case .cafe: return "カフェ"
        case .restaurant: return "飲食店"
        case .atm: return "ATM"
        case .pharmacy: return "薬局"
        case .parking: return "駐車場"
        case .park: return "公園"
        }
    }

    /// MapKit の検索に渡す語(コンビニのように、施設の種類の指定がないものも探せるようにする)
    var query: String {
        switch self {
        case .convenience: return "コンビニ"
        case .station: return "駅"
        case .restroom: return "トイレ"
        case .cafe: return "カフェ"
        case .restaurant: return "レストラン"
        case .atm: return "ATM"
        case .pharmacy: return "薬局"
        case .parking: return "駐車場"
        case .park: return "公園"
        }
    }

    var symbol: String {
        switch self {
        case .convenience: return "basket"
        case .station: return "tram"
        case .restroom: return "toilet"
        case .cafe: return "cup.and.saucer"
        case .restaurant: return "fork.knife"
        case .atm: return "yensign.circle"
        case .pharmacy: return "cross.case"
        case .parking: return "parkingsign"
        case .park: return "leaf"
        }
    }

    /// カメラ表示の印と、一覧の色(カテゴリごとに変える)
    var color: Color {
        switch self {
        case .convenience: return .orange
        case .station: return Color(red: 0.26, green: 0.29, blue: 0.80)
        case .restroom: return .cyan
        case .cafe: return .brown
        case .restaurant: return .red
        case .atm: return .green
        case .pharmacy: return .pink
        case .parking: return .blue
        case .park: return .mint
        }
    }

    /// 保存してあった並びを、今あるカテゴリに合わせる(知らないものと重複は捨て、足りないものは末尾に足す)
    static func normalizedOrder(_ stored: [String]?) -> [NearbyCategory] {
        var seen = Set<NearbyCategory>()
        var result = (stored ?? []).compactMap(NearbyCategory.init(rawValue:)).filter { seen.insert($0).inserted }
        for category in allCases where !seen.contains(category) { result.append(category) }
        return result
    }
}

/// 探す範囲(m)。初期値は500m、最大2km。
enum NearbyRadius {
    static let choices = [300, 500, 1000, 1500, 2000]
    static let initial = 500

    static func clamped(_ value: Int) -> Int {
        choices.contains(value) ? value : initial
    }
}

/// 周辺の施設(1件)
struct NearbyPlace: Equatable, Identifiable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var category: NearbyCategory
    var address: String?
    var phone: String?
    var url: URL?
    /// 検索した位置からの距離(m)と方位
    var distance: Double
    var bearing: Double

    /// 検索結果を、範囲の中だけに絞り、同じ場所の重複を除いて、近い順に並べる
    static func arranged(_ places: [NearbyPlace], radius: Double) -> [NearbyPlace] {
        var seen = Set<String>()
        return places
            .filter { $0.distance <= radius }
            .sorted { a, b in
                if a.distance != b.distance { return a.distance < b.distance }
                return a.name < b.name
            }
            .filter { place in
                // 同じ名前で、ほぼ同じ位置(約10m以内)のものは1つにする
                let key = "\(place.name)|\(Int((place.latitude * 10_000).rounded()))|\(Int((place.longitude * 10_000).rounded()))"
                return seen.insert(key).inserted
            }
    }
}

/// 検索結果の使い回し。同じカテゴリ・同じ範囲で、数分以内、あまり動いていなければ、探し直さない。
enum NearbyCachePolicy {
    static let lifetime: TimeInterval = 5 * 60
    /// これ以上動いたら探し直す(m)
    static let moveThreshold = 100.0

    static func canReuse(cachedAt: Date, cachedLatitude: Double, cachedLongitude: Double, cachedRadius: Int,
                         now: Date, latitude: Double, longitude: Double, radius: Int) -> Bool {
        guard cachedRadius == radius else { return false }
        let age = now.timeIntervalSince(cachedAt)
        guard age >= 0, age <= lifetime else { return false }
        return WaypointMath.distance(fromLatitude: cachedLatitude, longitude: cachedLongitude, toLatitude: latitude, longitude: longitude) <= moveThreshold
    }
}

import Foundation
import SwiftUI

/// スコープの画面の上部で切り替える3つの表示
enum ScopeSection: String, CaseIterable, Identifiable {
    case places
    case nearby
    case route

    var id: String { rawValue }

    var label: String {
        switch self {
        case .places: return "地点"
        case .nearby: return "周辺"
        case .route: return "経路"
        }
    }
}

/// カメラ表示とコンパス表示に出す印(登録した地点、周辺の施設、次の曲がり角、目的地で共通)
struct ScopeMark: Equatable, Identifiable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var color: Color

    init(id: String, name: String, latitude: Double, longitude: Double, color: Color) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.color = color
    }

    init(_ waypoint: Waypoint) {
        self.init(id: waypoint.id.uuidString, name: waypoint.name, latitude: waypoint.latitude, longitude: waypoint.longitude,
                  color: WaypointPalette.color(waypoint.colorIndex))
    }
}

/// 現在地からの方位と距離を計算した印
struct ScopeTarget: Equatable, Identifiable {
    var mark: ScopeMark
    var bearing: Double
    var distance: Double
    var id: String { mark.id }

    /// 遠い順(描くときに、近い印が手前になるように)
    static func make(_ marks: [ScopeMark], latitude: Double, longitude: Double) -> [ScopeTarget] {
        marks.map { mark in
            ScopeTarget(mark: mark,
                        bearing: WaypointMath.bearing(fromLatitude: latitude, longitude: longitude, toLatitude: mark.latitude, longitude: mark.longitude),
                        distance: WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: mark.latitude, longitude: mark.longitude))
        }
        .sorted { $0.distance > $1.distance }
    }
}

/// カメラ表示とコンパス表示に何を出すか
enum ScopeSightSource: Equatable {
    /// 登録した地点(nil なら全部、指定があればその1つ)
    case places(selectedID: UUID?)
    /// 周辺の施設(選んでいるカテゴリの結果)
    case nearby
    /// 経路の案内(次の曲がり角と目的地)
    case route
}

/// 経路の目的地(地点、または周辺の施設)
struct ScopeDestination: Equatable, Codable {
    var name: String
    var latitude: Double
    var longitude: Double
}

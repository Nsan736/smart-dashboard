import MapKit
import UIKit

/// 地図に描く線(路線など)
struct MapLine {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    /// 線の色(運行状況など)
    let color: UIColor
    /// 縁取りの色(路線本来の色など)。nilなら縁取りなし。
    let casingColor: UIColor?
    /// 太くして点滅させ、目立たせる
    let isEmphasized: Bool
    /// 選ばれていない路線。薄く細く描く。
    var isDimmed = false

    /// 描き直しが必要かどうかの判定に使う(端の点も見る。経路の案内では、点の数が同じまま端だけが動く)
    var signature: String {
        let first = coordinates.first.map { "\($0.latitude),\($0.longitude)" } ?? "-"
        let last = coordinates.last.map { "\($0.latitude),\($0.longitude)" } ?? "-"
        return "\(id)|\(coordinates.count)|\(first)|\(last)|\(color.description)|\(casingColor?.description ?? "-")|\(isEmphasized)|\(isDimmed)"
    }
}

/// ピンの見た目
enum MapMarkerStyle: String {
    /// 駅(電車のアイコン)
    case station
    /// 登録した地点など(ピンのアイコン)
    case place
    /// 震源(赤い×印)
    case epicenter
    /// 現在地など(青い点)
    case dot
    /// 経路の次の曲がり角(黄色)
    case turn
}

/// 地図を現在地に追従させるか
enum MapTracking: Equatable {
    case none
    /// 現在地を中心に保つ(北が上)
    case follow
    /// 現在地を中心に保ち、進行方向を上にして回転する
    case followHeading
}

/// 地図に立てるピン(駅など)
struct MapMarker {
    let id: String
    let title: String
    let coordinate: CLLocationCoordinate2D
    var style: MapMarkerStyle = .station

    var signature: String {
        "\(id)|\(title)|\(coordinate.latitude)|\(coordinate.longitude)|\(style.rawValue)"
    }
}

final class RouteOverlay: MKPolyline {
    var lineID = ""
    var isCasing = false
    var strokeColor: UIColor = .systemGray
    var strokeWidth: CGFloat = 4
    var blinks = false
    /// 通常の不透明度(薄く表示する路線は小さい)
    var baseAlpha: CGFloat = 1
}

final class StationAnnotation: MKPointAnnotation {
    var markerID = ""
    var style: MapMarkerStyle = .station
}

extension UIColor {
    /// "#RRGGBB" 形式
    convenience init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

enum MapGeometry {
    /// 点pから線分abまでの距離
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// 折れ線までの最短距離
    static func distance(from p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return points.first.map { hypot(p.x - $0.x, p.y - $0.y) } ?? .infinity }
        var best = CGFloat.infinity
        for index in 1..<points.count {
            best = min(best, distance(from: p, toSegment: points[index - 1], points[index]))
        }
        return best
    }
}

import CoreGraphics
import Foundation
import SwiftUI

/// 登録した地点
struct Waypoint: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// WaypointPalette の番号
    var colorIndex = 0
    var memo = ""
    /// ホームのカードに出す地点(1つだけ)
    var isPinned = false
}

enum WaypointPalette {
    static let names = ["青", "赤", "緑", "オレンジ", "紫", "ピンク", "水色", "黄"]
    static let colors: [Color] = [
        Color(red: 0.26, green: 0.29, blue: 0.80), .red, .green, .orange, .purple, .pink, .cyan, .yellow,
    ]

    static func color(_ index: Int) -> Color {
        colors[min(max(index, 0), colors.count - 1)]
    }
}

/// 最後に分かった現在地(一覧とホームの距離の表示用。測位はしない)
struct WaypointOrigin: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var time: Date
}

/// 方位と距離の計算
enum WaypointMath {
    static let earthRadius = 6_371_000.0

    /// 2点間の距離(m)
    static func distance(fromLatitude lat1: Double, longitude lon1: Double, toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad
        let dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// 現在地から地点への方位角(真北基準、時計回り、0〜360度)
    static func bearing(fromLatitude lat1: Double, longitude lon1: Double, toLatitude lat2: Double, longitude lon2: Double) -> Double {
        let rad = Double.pi / 180
        let dLon = (lon2 - lon1) * rad
        let y = sin(dLon) * cos(lat2 * rad)
        let x = cos(lat1 * rad) * sin(lat2 * rad) - sin(lat1 * rad) * cos(lat2 * rad) * cos(dLon)
        return normalized(atan2(y, x) / rad)
    }

    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// −180〜180度の差(to − from)。正なら右。
    static func difference(from: Double, to: Double) -> Double {
        let value = normalized(to - from)
        return value > 180 ? value - 360 : value
    }

    /// 8方位の名前
    static func compassPoint(_ degrees: Double) -> String {
        let points = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]
        return points[Int((normalized(degrees) + 22.5) / 45) % 8]
    }

    /// 「850m」「2.3km」「120km」
    static func distanceText(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded()))m" }
        if meters < 100_000 { return String(format: "%.1fkm", meters / 1000) }
        return "\(Int((meters / 1000).rounded()))km"
    }

    /// 「北東 2.3km」
    static func summary(bearing: Double, distance: Double) -> String {
        "\(compassPoint(bearing)) \(distanceText(distance))"
    }
}

/// カメラ越しの印の大きさ。調整するときは、ここだけを変える。
enum WaypointMarkStyle {
    /// 外側のリングの直径(距離に関係なく一定)
    static let ringDiameter: CGFloat = 44
    static let ringLineWidth: CGFloat = 3
    /// この距離以下で、内側の円がリングをほぼ満たす
    static let nearDistance = 10.0
    static let nearFraction = 0.95
    /// この距離以上で、内側の円が最小になる(それより遠くても、これ以上は小さくしない)
    static let farDistance = 15_000.0
    static let farFraction = 0.10

    /// 内側の円の大きさ(リングの内径に対する割合)。距離の対数で決める(距離が1桁変わるごとに一定の量だけ変わる)。
    static func innerFraction(distance: Double) -> Double {
        if distance <= nearDistance { return nearFraction }
        if distance >= farDistance { return farFraction }
        let t = (log10(distance) - log10(nearDistance)) / (log10(farDistance) - log10(nearDistance))
        return nearFraction + (farFraction - nearFraction) * t
    }

    static func innerDiameter(distance: Double) -> CGFloat {
        (ringDiameter - ringLineWidth * 2) * CGFloat(innerFraction(distance: distance))
    }
}

/// 3次元のベクトル。基準の座標系は、x=真北、y=西、z=上(CMAttitudeReferenceFrame.xTrueNorthZVertical)。
struct Vector3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    static func dot(_ a: Vector3, _ b: Vector3) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    var length: Double { (x * x + y * y + z * z).squareRoot() }

    var unit: Vector3 {
        let l = length
        return l > 0 ? Vector3(x: x / l, y: y / l, z: z / l) : self
    }

    func mixed(with other: Vector3, weight: Double) -> Vector3 {
        Vector3(x: x + (other.x - x) * weight, y: y + (other.y - y) * weight, z: z + (other.z - z) * weight)
    }
}

/// 端末の向き(縦向きに持ったとき)。基準の座標系で表した、画面の右・画面の上・背面カメラの向き。
struct CameraAttitude: Equatable {
    var right: Vector3
    var up: Vector3
    var forward: Vector3

    /// CMRotationMatrix(基準の座標系のベクトルを端末の座標系に移す行列)から作る。
    /// 行列の各行が、端末のX軸(画面の右)・Y軸(画面の上)・Z軸(画面の手前)を基準の座標系で表したものになる。
    /// 背面カメラは −Z の向き。
    init(m11: Double, m12: Double, m13: Double, m21: Double, m22: Double, m23: Double, m31: Double, m32: Double, m33: Double) {
        right = Vector3(x: m11, y: m12, z: m13)
        up = Vector3(x: m21, y: m22, z: m23)
        forward = Vector3(x: -m31, y: -m32, z: -m33)
    }

    init(right: Vector3, up: Vector3, forward: Vector3) {
        self.right = right
        self.up = up
        self.forward = forward
    }

    /// センサーの値を軽く平滑化する(ベクトルのまま混ぜるので、0度/360度の境目の問題が起きない)
    func smoothed(toward new: CameraAttitude, weight: Double) -> CameraAttitude {
        CameraAttitude(right: right.mixed(with: new.right, weight: weight).unit,
                       up: up.mixed(with: new.up, weight: weight).unit,
                       forward: forward.mixed(with: new.forward, weight: weight).unit)
    }

    /// カメラが向いている方位(真北基準)。東は −y。
    var azimuth: Double {
        WaypointMath.normalized(atan2(-forward.y, forward.x) * 180 / .pi)
    }

    /// カメラの仰角(度)。水平で0、真上で90。
    var elevation: Double {
        asin(max(-1, min(1, forward.z))) * 180 / .pi
    }
}

/// カメラの写る範囲と、画面上の位置への変換
enum WaypointProjection {
    /// 画面に写る範囲(画角の半分の正接)。
    /// - fieldOfView: AVCaptureDevice の activeFormat.videoFieldOfView(映像の長辺の画角、度)
    /// - videoAspect: 映像の長辺 ÷ 短辺(16:9 なら 1.78)
    /// 縦向きの画面に、映像を画面いっぱい(aspectFill)に表示する前提。映像の長辺が画面の縦になる。
    static func tangents(fieldOfView: Double, videoAspect: Double, viewSize: CGSize) -> (horizontal: Double, vertical: Double) {
        let tanLong = tan(fieldOfView / 2 * .pi / 180)
        let tanShort = tanLong / max(videoAspect, 0.01)
        let viewAspect = Double(viewSize.height / max(viewSize.width, 1))
        if viewAspect >= videoAspect {
            // 画面のほうが縦長: 縦は映像の全体が写り、横は切り取られる
            return (tanLong / viewAspect, tanLong)
        }
        // 画面のほうが横に広い: 横は映像の全体が写り、縦は切り取られる
        return (tanShort, tanShort * viewAspect)
    }

    /// 地点の方向を、画面上の位置に変換する。仰角は0度(地平線上)に置く。
    /// カメラの後ろ側にあるときと、画面の外にあるときは nil。
    static func point(bearing: Double, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), viewSize: CGSize) -> CGPoint? {
        let rad = bearing * .pi / 180
        // 基準の座標系(x=北、y=西、z=上)での地点の方向
        let target = Vector3(x: cos(rad), y: -sin(rad), z: 0)
        let depth = Vector3.dot(target, attitude.forward)
        guard depth > 0.01 else { return nil }
        let nx = Vector3.dot(target, attitude.right) / depth / max(tangents.horizontal, 0.0001)
        let ny = Vector3.dot(target, attitude.up) / depth / max(tangents.vertical, 0.0001)
        guard abs(nx) <= 1, abs(ny) <= 1 else { return nil }
        return CGPoint(x: viewSize.width / 2 * (1 + nx), y: viewSize.height / 2 * (1 - ny))
    }
}

/// カメラ越しの表示と、コンパス表示に出す地点(現在地からの方位と距離を計算したもの)
struct WaypointTarget: Equatable, Identifiable {
    var waypoint: Waypoint
    var bearing: Double
    var distance: Double
    var id: UUID { waypoint.id }

    /// 遠い順(描くときに、近い地点が手前になるように)
    static func make(_ waypoints: [Waypoint], latitude: Double, longitude: Double) -> [WaypointTarget] {
        waypoints.map { waypoint in
            WaypointTarget(waypoint: waypoint,
                           bearing: WaypointMath.bearing(fromLatitude: latitude, longitude: longitude,
                                                         toLatitude: waypoint.latitude, longitude: waypoint.longitude),
                           distance: WaypointMath.distance(fromLatitude: latitude, longitude: longitude,
                                                           toLatitude: waypoint.latitude, longitude: waypoint.longitude))
        }
        .sorted { $0.distance > $1.distance }
    }
}

/// 「35.68, 139.76」のように貼り付けた座標の解析
enum WaypointCoordinateParser {
    /// 緯度、経度の順の2つの数。区切りはカンマ(全角も)、空白、タブ。かっこや「°」は無視する。
    /// 範囲の外(緯度は±90、経度は±180)や、数が2つでないときは nil。
    static func parse(_ text: String) -> (latitude: Double, longitude: Double)? {
        var cleaned = ""
        for character in text {
            switch character {
            case "0"..."9", ".", "-", "+": cleaned.append(character)
            case "０"..."９":
                if let value = character.wholeNumberValue { cleaned.append(String(value)) }
            case "．": cleaned.append(".")
            case "−", "－": cleaned.append("-")
            default: cleaned.append(" ")
            }
        }
        let numbers = cleaned.split(separator: " ").map { Double($0) }
        guard numbers.count == 2, let latitude = numbers[0], let longitude = numbers[1],
              abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        return (latitude, longitude)
    }
}

import Foundation

/// 方角の手動補正(設定の「方角の補正」)。iPhone の磁気センサーがずれたとき(iPhone のコンパスアプリでもずれるとき)の、短期的な対策。
/// 補正した方角 = 端末が出した方角 + 補正の値(度、時計回りが正、−180〜180)。
/// 端末の方角を使う所(スコープのカメラ表示・コンパス表示、センサー画面の方位、スクリプト型の方位、地図の現在地の矢印)は、すべて `current` を足す。
enum HeadingCorrection {
    static let range = -180.0...180.0
    static let defaultsKey = "scope.headingOffset"

    /// 今の補正の値。AppSettings が読み込んだときと変えたときに入れる(画面の外の部品からも読めるように)
    nonisolated(unsafe) static var current = 0.0

    /// −180〜180 に丸める(小数第1位まで)
    static func normalized(_ value: Double) -> Double {
        let wrapped = remainder(value, 360)
        let rounded = (wrapped * 10).rounded() / 10
        return min(max(rounded == -180 ? 180 : rounded, range.lowerBound), range.upperBound)
    }

    /// 補正した方角(0〜360)
    static func apply(_ heading: Double, offset: Double = current) -> Double {
        WaypointMath.normalized(heading + offset)
    }

    /// 画面の中央に目印を合わせたときの、新しい補正の値。
    /// currentAzimuth は今の補正を足した方角、targetBearing はその目印の本当の方角
    static func aligned(offset: Double, currentAzimuth: Double, targetBearing: Double) -> Double {
        normalized(offset + WaypointMath.difference(from: currentAzimuth, to: targetBearing))
    }

    /// 「補正 +12°」(0なら nil)
    static func text(_ offset: Double) -> String? {
        guard abs(offset) >= 0.05 else { return nil }
        let rounded = (offset * 10).rounded() / 10
        let body = rounded == rounded.rounded() ? String(format: "%+.0f", rounded) : String(format: "%+.1f", rounded)
        return "補正 \(body)°"
    }

    /// 目印にできるもの(地点・山・オブジェクト・電車など。名前と本当の方角)
    struct Landmark: Equatable {
        var name: String
        var bearing: Double
    }

    /// 合わせる目印として選べる、画面の中央からの角度の上限(度)
    static let alignLimit = 25.0

    /// 画面の中央(方角 azimuth)に一番近い目印(左右の角度が alignLimit 以内)
    static func nearest(_ landmarks: [Landmark], azimuth: Double) -> Landmark? {
        landmarks
            .map { ($0, abs(WaypointMath.difference(from: azimuth, to: $0.bearing))) }
            .filter { $0.1 <= alignLimit }
            .min { $0.1 < $1.1 }?.0
    }
}

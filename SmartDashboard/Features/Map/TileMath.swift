import Foundation

/// XYZタイルの座標
struct TileCoord: Hashable, Codable {
    let z: Int
    let x: Int
    let y: Int

    var parent: TileCoord? {
        z > 0 ? TileCoord(z: z - 1, x: x / 2, y: y / 2) : nil
    }
}

/// 緯度経度の範囲
struct GeoBounds: Equatable {
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double

    /// 日本全国の広域(ズーム5〜8)の保存範囲
    static let japan = GeoBounds(minLatitude: 24, maxLatitude: 46, minLongitude: 122, maxLongitude: 146)

    init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    /// 中心と半径(km)を囲む範囲
    init(latitude: Double, longitude: Double, radiusKm: Double) {
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * max(0.1, cos(latitude * .pi / 180)))
        self.init(minLatitude: latitude - dLat, maxLatitude: latitude + dLat,
                  minLongitude: longitude - dLon, maxLongitude: longitude + dLon)
    }
}

/// 地図を保存する登録エリア
struct TileArea: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusKm: Double

    var bounds: GeoBounds { GeoBounds(latitude: latitude, longitude: longitude, radiusKm: radiusKm) }
}

enum TileMath {
    static let nationwideZooms = 5...8
    static let areaMinZoom = 9
    /// 地理院の淡色地図が提供されるズーム
    static let sourceZooms = 5...18

    static func tile(latitude: Double, longitude: Double, z: Int) -> TileCoord {
        let n = Double(1 << z)
        let lat = min(max(latitude, -85.0511), 85.0511) * .pi / 180
        let x = Int(((longitude + 180) / 360 * n).rounded(.down))
        let y = Int(((1 - asinh(tan(lat)) / .pi) / 2 * n).rounded(.down))
        let limit = (1 << z) - 1
        return TileCoord(z: z, x: min(max(x, 0), limit), y: min(max(y, 0), limit))
    }

    static func count(in bounds: GeoBounds, z: Int) -> Int {
        let a = tile(latitude: bounds.maxLatitude, longitude: bounds.minLongitude, z: z)
        let b = tile(latitude: bounds.minLatitude, longitude: bounds.maxLongitude, z: z)
        return max(0, b.x - a.x + 1) * max(0, b.y - a.y + 1)
    }

    static func tiles(in bounds: GeoBounds, z: Int) -> [TileCoord] {
        let a = tile(latitude: bounds.maxLatitude, longitude: bounds.minLongitude, z: z)
        let b = tile(latitude: bounds.minLatitude, longitude: bounds.maxLongitude, z: z)
        guard b.x >= a.x, b.y >= a.y else { return [] }
        var result: [TileCoord] = []
        result.reserveCapacity((b.x - a.x + 1) * (b.y - a.y + 1))
        for x in a.x...b.x {
            for y in a.y...b.y { result.append(TileCoord(z: z, x: x, y: y)) }
        }
        return result
    }

    static func nationwideTiles() -> [TileCoord] {
        nationwideZooms.flatMap { tiles(in: .japan, z: $0) }
    }

    /// 登録エリアのタイル。広い縮尺から順に並べる。
    static func areaTiles(_ area: TileArea, maxZoom: Int) -> [TileCoord] {
        guard maxZoom >= areaMinZoom else { return [] }
        return (areaMinZoom...maxZoom).flatMap { tiles(in: area.bounds, z: $0) }
    }

    /// 1枚あたりの容量の目安(バイト)。東京周辺で実測した平均で、郊外や海上はこれより小さい。
    static func averageBytes(z: Int) -> Int {
        switch z {
        case ...5: return 35_000
        case 6: return 19_000
        case 7: return 21_000
        case 8: return 10_000
        case 9: return 109_000
        case 10: return 86_000
        case 11: return 62_000
        case 12: return 55_000
        case 13: return 44_000
        case 14: return 43_000
        case 15: return 23_000
        default: return 18_000
        }
    }

    struct Estimate: Equatable {
        var tileCount: Int
        var bytes: Int64
    }

    static func estimate(bounds: GeoBounds, zooms: ClosedRange<Int>) -> Estimate {
        var result = Estimate(tileCount: 0, bytes: 0)
        for z in zooms {
            let n = count(in: bounds, z: z)
            result.tileCount += n
            result.bytes += Int64(n) * Int64(averageBytes(z: z))
        }
        return result
    }

    static func estimate(area: TileArea, maxZoom: Int) -> Estimate {
        guard maxZoom >= areaMinZoom else { return Estimate(tileCount: 0, bytes: 0) }
        return estimate(bounds: area.bounds, zooms: areaMinZoom...maxZoom)
    }

    /// 地図の表示幅(経度の幅)と画面幅(ポイント)からズームを求める
    static func zoomLevel(longitudeDelta: Double, widthPoints: Double) -> Int {
        guard longitudeDelta > 0, widthPoints > 0 else { return 5 }
        let z = log2(360 * widthPoints / 256 / longitudeDelta)
        return Int(z.rounded())
    }
}

/// どちらの地図を表示するか
enum MapMode: Equatable {
    case apple
    case offline

    var label: String {
        switch self {
        case .apple: return "Apple Maps"
        case .offline: return "保存済み地図"
        }
    }

    /// Wi-Fiなど(従量制でも省データでもない)ならApple Maps。それ以外は保存済みの地理院タイルだけで表示する。
    static func decide(network: NetworkStatus, allowAppleOnCellular: Bool) -> MapMode {
        guard network.isOnline, !network.isConstrained else { return .offline }
        if network.isExpensive { return allowAppleOnCellular ? .apple : .offline }
        return .apple
    }

    /// 地理院タイルを保存してよい回線か(トグルの影響は受けない)
    static func canDownloadTiles(network: NetworkStatus) -> Bool {
        network.isOnline && !network.isExpensive && !network.isConstrained
    }
}

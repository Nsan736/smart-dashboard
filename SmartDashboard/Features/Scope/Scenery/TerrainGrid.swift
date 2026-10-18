import CoreGraphics
import Foundation
import ImageIO

/// 地図タイルの番号(ズーム、x、y)
struct TileKey: Hashable, Comparable {
    var z: Int
    var x: Int
    var y: Int

    static func < (a: TileKey, b: TileKey) -> Bool { (a.z, a.x, a.y) < (b.z, b.x, b.y) }

    /// 緯度経度が入るタイルと、その中の位置(0〜1)
    static func locate(latitude: Double, longitude: Double, zoom: Int) -> (key: TileKey, fx: Double, fy: Double) {
        let (x, y) = worldPoint(latitude: latitude, longitude: longitude, zoom: zoom)
        let tx = Int(floor(x)), ty = Int(floor(y))
        return (TileKey(z: zoom, x: tx, y: ty), x - Double(tx), y - Double(ty))
    }

    /// Web メルカトルの、タイル単位の座標
    static func worldPoint(latitude: Double, longitude: Double, zoom: Int) -> (x: Double, y: Double) {
        let n = pow(2.0, Double(zoom))
        let lat = min(max(latitude, -85.0511), 85.0511) * .pi / 180
        let x = (longitude + 180) / 360 * n
        let y = (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n
        return (x, y)
    }

    /// タイル単位の座標から緯度経度
    static func coordinate(x: Double, y: Double, zoom: Int) -> (latitude: Double, longitude: Double) {
        let n = pow(2.0, Double(zoom))
        let longitude = x / n * 360 - 180
        let latitude = atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi
        return (latitude, longitude)
    }

    /// 中心から半径(m)の四角に入るタイル
    static func around(latitude: Double, longitude: Double, radius: Double, zoom: Int) -> [TileKey] {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * max(cos(latitude * .pi / 180), 0.01))
        let a = worldPoint(latitude: latitude + dLat, longitude: longitude - dLon, zoom: zoom)
        let b = worldPoint(latitude: latitude - dLat, longitude: longitude + dLon, zoom: zoom)
        var result: [TileKey] = []
        for x in Int(floor(a.x))...Int(floor(b.x)) {
            for y in Int(floor(a.y))...Int(floor(b.y)) { result.append(TileKey(z: zoom, x: x, y: y)) }
        }
        return result
    }
}

/// 地形の標高の格子。近くは細かいズーム、遠くは粗いズームの標高タイルを使う。
/// 海の上は標高タイルが「データなし」なので、海(0m)として扱う。タイルがない所は分からない(missing)。
struct TerrainGrid {
    enum Sample: Equatable {
        case elevation(Double)
        case sea
        case missing

        /// 海は0m
        var height: Double? {
            switch self {
            case .elevation(let value): return value
            case .sea: return 0
            case .missing: return nil
            }
        }
    }

    /// 距離ごとに使うズーム(近い順)。5kmまで ズーム12(約30m)、30kmまで ズーム10(約125m)、それより遠くは ズーム9(約250m)
    static let rings: [(distance: Double, zoom: Int)] = [(5_000, 12), (30_000, 10), (.infinity, 9)]
    static let zooms = [12, 10, 9]
    static let tileSize = 256

    /// タイルごとの標高(m)。256×256、行ごと。海(データなし)は NaN。
    var tiles: [TileKey: [Float]]

    init(tiles: [TileKey: [Float]] = [:]) {
        self.tiles = tiles
    }

    static func zoom(forDistance distance: Double) -> Int {
        rings.first { distance <= $0.distance }?.zoom ?? 9
    }

    /// その距離で使うズーム(なければ粗いほうへ)で標高を引く
    func sample(latitude: Double, longitude: Double, distance: Double) -> Sample {
        let preferred = Self.zoom(forDistance: distance)
        for zoom in Self.zooms where zoom <= preferred {
            let sample = sample(latitude: latitude, longitude: longitude, zoom: zoom)
            if sample != .missing { return sample }
        }
        return .missing
    }

    func sample(latitude: Double, longitude: Double, zoom: Int) -> Sample {
        let (key, fx, fy) = TileKey.locate(latitude: latitude, longitude: longitude, zoom: zoom)
        guard let values = tiles[key] else { return .missing }
        let i = min(Self.tileSize - 1, max(0, Int(fx * Double(Self.tileSize))))
        let j = min(Self.tileSize - 1, max(0, Int(fy * Double(Self.tileSize))))
        let value = values[j * Self.tileSize + i]
        return value.isNaN ? .sea : .elevation(Double(value))
    }

    /// その場所に必要なタイル(半径 radius まで)
    static func neededTiles(latitude: Double, longitude: Double, radius: Double) -> [TileKey] {
        var result: [TileKey] = []
        var inner = 0.0
        for ring in rings {
            let outer = min(ring.distance, radius)
            if outer > inner || (inner == 0 && outer > 0) {
                result += TileKey.around(latitude: latitude, longitude: longitude, radius: outer, zoom: ring.zoom)
            }
            inner = outer
            if ring.distance >= radius { break }
        }
        return result
    }
}

/// 国土地理院の標高タイル(PNG)の読み取り。https://maps.gsi.go.jp/development/demtile.html
/// x = 2^16·R + 2^8·G + B。x < 2^23 なら x×0.01m、x = 2^23 はデータなし、それより大きければ (x − 2^24)×0.01m。
enum GSIElevationTile {
    static func elevation(r: UInt8, g: UInt8, b: UInt8) -> Float {
        let x = Int(r) << 16 | Int(g) << 8 | Int(b)
        if x == 1 << 23 { return .nan }
        return Float(x < 1 << 23 ? x : x - (1 << 24)) * 0.01
    }

    /// PNG を 256×256 の標高の配列にする。色の変換をしないように、画像のビットの並びをそのまま読む。
    static func decode(_ data: Data) -> [Float]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              image.width == TerrainGrid.tileSize, image.height == TerrainGrid.tileSize,
              image.bitsPerComponent == 8,
              let raw = image.dataProvider?.data, let bytes = CFDataGetBytePtr(raw) else { return nil }
        let length = CFDataGetLength(raw)
        let size = TerrainGrid.tileSize
        let bytesPerRow = image.bytesPerRow
        var result = [Float](repeating: .nan, count: size * size)
        if image.colorSpace?.model == .indexed, let table = image.colorSpace?.colorTable, !table.isEmpty {
            // 色の数が少ないタイルは、パレットの PNG になっていることがある(table は RGB の並び)
            guard image.bitsPerPixel == 8 else { return nil }
            for y in 0..<size {
                for x in 0..<size {
                    let offset = y * bytesPerRow + x
                    guard offset < length else { return nil }
                    let index = Int(bytes[offset]) * 3
                    guard index + 2 < table.count else { continue }
                    result[y * size + x] = elevation(r: table[index], g: table[index + 1], b: table[index + 2])
                }
            }
            return result
        }
        let pixelBytes = image.bitsPerPixel / 8
        guard pixelBytes == 3 || pixelBytes == 4 else { return nil }
        // アルファが先頭にある並び(ARGB)なら、色は1バイトずらす
        let alphaFirst: Bool = {
            switch image.alphaInfo {
            case .first, .premultipliedFirst, .noneSkipFirst: return true
            default: return false
            }
        }()
        let littleEndian = image.byteOrderInfo == .order32Little
        for y in 0..<size {
            for x in 0..<size {
                let offset = y * bytesPerRow + x * pixelBytes
                guard offset + pixelBytes <= length else { return nil }
                var r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
                if pixelBytes == 4 {
                    if littleEndian {
                        // BGRA / ABGR の並び
                        if alphaFirst { r = bytes[offset + 2]; g = bytes[offset + 1]; b = bytes[offset] } else {
                            r = bytes[offset + 3]; g = bytes[offset + 2]; b = bytes[offset + 1]
                        }
                    } else if alphaFirst {
                        r = bytes[offset + 1]; g = bytes[offset + 2]; b = bytes[offset + 3]
                    }
                }
                result[y * size + x] = elevation(r: r, g: g, b: b)
            }
        }
        return result
    }
}

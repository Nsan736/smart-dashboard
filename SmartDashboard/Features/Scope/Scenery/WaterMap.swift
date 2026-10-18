import Foundation

/// 景色に出す名前(湖・海・川・地名)
struct SceneryPlaceName: Equatable {
    enum Kind: String, Equatable {
        /// 湖・沼(注記の分類 321)
        case lake
        /// 海・湾・水道・灘(344、345)
        case sea
        /// 川(322)
        case river
        /// 地名(市町村など。記号の名前)
        case place
    }

    var name: String
    var kind: Kind
    var latitude: Double
    var longitude: Double
}

/// 水部(海・湖・大きな川の面)の格子。国土地理院ベクトルタイル(ズーム8)の waterarea を、1タイルあたり512×512のます目に塗る。
/// つながった水面を1つの区域にまとめ(タイルの境目で切れた面もつなぐ)、区域ごとに中にある注記の名前を持つ。
struct WaterMap: WaterSampling {
    static let zoom = 8
    static let cellsPerTile = 512
    /// 名前の注記を、水面から何ます離れていても拾うか(湖の名前は湖の外に置かれることがある)
    static let labelSearchCells = 5

    /// 格子のズーム(ふだんは8)
    var tileZoom = WaterMap.zoom
    /// 格子の左上のタイル
    var originTileX: Int
    var originTileY: Int
    var width: Int
    var height: Int
    /// 0 は水なし。それ以外は区域の番号+1
    var cells: [UInt32]
    /// 区域ごとの名前の注記
    var names: [Int: [SceneryPlaceName]]

    static let empty = WaterMap(originTileX: 0, originTileY: 0, width: 0, height: 0, cells: [], names: [:])

    func cell(latitude: Double, longitude: Double) -> (x: Int, y: Int)? {
        let p = TileKey.worldPoint(latitude: latitude, longitude: longitude, zoom: tileZoom)
        let x = Int(floor((p.x - Double(originTileX)) * Double(Self.cellsPerTile)))
        let y = Int(floor((p.y - Double(originTileY)) * Double(Self.cellsPerTile)))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return (x, y)
    }

    func component(latitude: Double, longitude: Double) -> Int? {
        guard let (x, y) = cell(latitude: latitude, longitude: longitude) else { return nil }
        let value = cells[y * width + x]
        return value == 0 ? nil : Int(value - 1)
    }

    /// その区域の、場所に一番近い名前(400kmまで)
    func name(component: Int, nearLatitude latitude: Double, longitude: Double) -> SceneryPlaceName? {
        guard let list = names[component], !list.isEmpty else { return nil }
        return list.min {
            WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: $0.latitude, longitude: $0.longitude)
                < WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: $1.latitude, longitude: $1.longitude)
        }
    }

    // MARK: - 作る

    /// ズーム8のタイル(waterarea と label の層)から作る。labels は、タイルの注記から作った名前(水の名前だけを区域に付ける)。
    static func build(tiles: [TileKey: VectorTile], labels: [SceneryPlaceName], zoom: Int = WaterMap.zoom) -> WaterMap {
        let keys = tiles.keys.filter { $0.z == zoom }
        guard let minX = keys.map(\.x).min(), let maxX = keys.map(\.x).max(),
              let minY = keys.map(\.y).min(), let maxY = keys.map(\.y).max() else { return .empty }
        let width = (maxX - minX + 1) * cellsPerTile
        let height = (maxY - minY + 1) * cellsPerTile
        var cells = [UInt32](repeating: 0, count: width * height)
        var nextID: UInt32 = 1
        for key in keys.sorted() {
            guard let layer = tiles[key]?.layers["waterarea"] else { continue }
            let scale = Double(cellsPerTile) / layer.extent
            let offsetX = Double((key.x - minX) * cellsPerTile)
            let offsetY = Double((key.y - minY) * cellsPerTile)
            for feature in layer.features where feature.type == .polygon {
                let rings = feature.parts.map { ring in ring.map { SIMD2(offsetX + $0.x * scale, offsetY + $0.y * scale) } }
                fill(rings: rings, id: nextID, cells: &cells, width: width, height: height)
                nextID += 1
            }
        }
        // 隣り合う水のます目は、同じ区域にまとめる
        var parent = Array(0..<Int(nextID))
        func find(_ a: Int) -> Int {
            var a = a
            while parent[a] != a {
                parent[a] = parent[parent[a]]
                a = parent[a]
            }
            return a
        }
        func join(_ id: Int, _ other: Int) {
            guard other != 0, other != id else { return }
            let a = find(id), b = find(other)
            if a != b { parent[max(a, b)] = min(a, b) }
        }
        for y in 0..<height {
            for x in 0..<width {
                let id = Int(cells[y * width + x])
                guard id != 0 else { continue }
                if x + 1 < width { join(id, Int(cells[y * width + x + 1])) }
                if y + 1 < height { join(id, Int(cells[(y + 1) * width + x])) }
            }
        }
        for i in cells.indices where cells[i] != 0 {
            cells[i] = UInt32(find(Int(cells[i])))
        }
        var map = WaterMap(tileZoom: zoom, originTileX: minX, originTileY: minY, width: width, height: height, cells: cells, names: [:])
        // 湖と海の名前を、近くの水面の区域に付ける(川の名前は、川の注記として別に出す)
        for label in labels where label.kind == .lake || label.kind == .sea {
            guard let (cx, cy) = map.cell(latitude: label.latitude, longitude: label.longitude) else { continue }
            var found: Int?
            search: for radius in 0...labelSearchCells {
                for dy in -radius...radius {
                    for dx in -radius...radius where max(abs(dx), abs(dy)) == radius {
                        let x = cx + dx, y = cy + dy
                        guard x >= 0, y >= 0, x < width, y < height else { continue }
                        let value = cells[y * width + x]
                        if value != 0 {
                            found = Int(value - 1)
                            break search
                        }
                    }
                }
            }
            if let found { map.names[found, default: []].append(label) }
        }
        return map
    }

    /// 偶奇の規則で、多角形(穴を含むリングの集まり)を塗る。ます目の中心が中にあれば塗る。
    static func fill(rings: [[SIMD2<Double>]], id: UInt32, cells: inout [UInt32], width: Int, height: Int) {
        var rows: [Int: [Double]] = [:]
        for ring in rings where ring.count >= 3 {
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                guard a.y != b.y else { continue }
                let (low, high) = a.y < b.y ? (a, b) : (b, a)
                // ます目の中心 y + 0.5 が [low.y, high.y) に入る行
                let first = max(0, Int(ceil(low.y - 0.5)))
                let last = min(height - 1, Int(ceil(high.y - 0.5)) - 1)
                guard first <= last else { continue }
                for row in first...last {
                    let cy = Double(row) + 0.5
                    let t = (cy - low.y) / (high.y - low.y)
                    rows[row, default: []].append(low.x + t * (high.x - low.x))
                }
            }
        }
        for (row, crossings) in rows {
            let sorted = crossings.sorted()
            var k = 0
            while k + 1 < sorted.count {
                let start = max(0, Int(ceil(sorted[k] - 0.5)))
                let end = min(width - 1, Int(ceil(sorted[k + 1] - 0.5)) - 1)
                if start <= end {
                    for x in start...end { cells[row * width + x] = id }
                }
                k += 2
            }
        }
    }
}

/// ベクトルタイルの注記・記号から、景色に出す名前を作る
enum SceneryLabelReader {
    /// 注記の分類(annoCtg)と、名前の種類
    static func kind(annoCtg: Int) -> SceneryPlaceName.Kind? {
        switch annoCtg {
        case 321: return .lake
        case 322: return .river
        case 344, 345: return .sea
        default: return nil
        }
    }

    /// 1文字ずつに分かれた注記(annoChar に名前全体が入っている)は、同じ名前で30km以内の文字をまとめ、位置はその平均にする。
    static func names(tiles: [TileKey: VectorTile]) -> [SceneryPlaceName] {
        struct Piece {
            var name: String
            var kind: SceneryPlaceName.Kind
            var latitude: Double
            var longitude: Double
        }
        var pieces: [Piece] = []
        for (key, tile) in tiles {
            if let layer = tile.layers["label"] {
                for feature in layer.features where feature.type == .point {
                    guard let category = feature.properties["annoCtg"]?.number, let kind = Self.kind(annoCtg: Int(category)),
                          let point = feature.parts.first?.first else { continue }
                    let name = feature.properties["annoChar"]?.string ?? feature.properties["knj"]?.string ?? ""
                    guard !name.isEmpty else { continue }
                    let (lat, lon) = coordinate(point, key: key, extent: layer.extent)
                    pieces.append(Piece(name: name, kind: kind, latitude: lat, longitude: lon))
                }
            }
            if let layer = tile.layers["symbol"] {
                for feature in layer.features where feature.type == .point {
                    guard let name = feature.properties["name"]?.string, !name.isEmpty,
                          let point = feature.parts.first?.first else { continue }
                    let (lat, lon) = coordinate(point, key: key, extent: layer.extent)
                    pieces.append(Piece(name: name, kind: .place, latitude: lat, longitude: lon))
                }
            }
        }
        var result: [SceneryPlaceName] = []
        var counts: [Int] = []
        for piece in pieces {
            if let index = result.indices.first(where: {
                result[$0].name == piece.name && result[$0].kind == piece.kind
                    && WaypointMath.distance(fromLatitude: result[$0].latitude, longitude: result[$0].longitude,
                                             toLatitude: piece.latitude, longitude: piece.longitude) < 30_000
            }) {
                let n = Double(counts[index])
                result[index].latitude = (result[index].latitude * n + piece.latitude) / (n + 1)
                result[index].longitude = (result[index].longitude * n + piece.longitude) / (n + 1)
                counts[index] += 1
            } else {
                result.append(SceneryPlaceName(name: piece.name, kind: piece.kind, latitude: piece.latitude, longitude: piece.longitude))
                counts.append(1)
            }
        }
        return result
    }

    static func coordinate(_ point: SIMD2<Double>, key: TileKey, extent: Double) -> (Double, Double) {
        let c = TileKey.coordinate(x: Double(key.x) + point.x / extent, y: Double(key.y) + point.y / extent, zoom: key.z)
        return (c.latitude, c.longitude)
    }
}

/// 方角の帯で示す水面(「東京湾 8km」)
struct WaterBand: Equatable {
    var name: String
    var kind: SceneryPlaceName.Kind
    /// 帯の始まりと終わりの方角(度、時計回り。終わりが360を超えることがある)
    var startBearing: Double
    var endBearing: Double
    /// 一番近い見える水面までの距離(m)
    var distance: Double
    /// 帯を描く仰角(度、見えた水面の仰角の中央値)
    var angle: Double

    var centerBearing: Double { ((startBearing + endBearing) / 2).truncatingRemainder(dividingBy: 360) }
    var width: Double { endBearing - startBearing }
}

enum WaterBands {
    /// これより狭い帯は出さない(度)
    static let minimumWidth = 1.0

    /// 方角ごとの水面から、同じ名前が続く方角をまとめて帯にする
    static func make(hits: [WaterHit?], step: Double, map: WaterMap) -> [WaterBand] {
        guard !hits.isEmpty else { return [] }
        struct Run {
            var name: String
            var kind: SceneryPlaceName.Kind
            var start: Int
            var end: Int
            var distance: Double
            var angles: [Double]
        }
        func label(_ hit: WaterHit) -> (String, SceneryPlaceName.Kind) {
            if let named = map.name(component: hit.component, nearLatitude: hit.latitude, longitude: hit.longitude) {
                return (named.name, named.kind)
            }
            return hit.isSea ? ("海", .sea) : ("湖・川", .lake)
        }
        var runs: [Run] = []
        var current: Run?
        for (index, hit) in hits.enumerated() {
            guard let hit else {
                if let run = current { runs.append(run) }
                current = nil
                continue
            }
            let (name, kind) = label(hit)
            if var run = current, run.name == name {
                run.end = index
                run.distance = min(run.distance, hit.distance)
                run.angles.append(hit.angle)
                current = run
            } else {
                if let run = current { runs.append(run) }
                current = Run(name: name, kind: kind, start: index, end: index, distance: hit.distance, angles: [hit.angle])
            }
        }
        if let run = current { runs.append(run) }
        // 0°をまたぐ帯(最後と最初が同じ名前)はつなぐ
        if runs.count >= 2, let first = runs.first, let last = runs.last, first.start == 0, last.end == hits.count - 1, first.name == last.name {
            var merged = last
            merged.end = hits.count + first.end
            merged.distance = min(first.distance, last.distance)
            merged.angles += first.angles
            runs.removeFirst()
            runs[runs.count - 1] = merged
        }
        return runs.compactMap { run in
            let start = Double(run.start) * step - step / 2
            let end = Double(run.end) * step + step / 2
            guard end - start >= minimumWidth else { return nil }
            let sorted = run.angles.sorted()
            return WaterBand(name: run.name, kind: run.kind, startBearing: (start + 360).truncatingRemainder(dividingBy: 360),
                             endBearing: (start + 360).truncatingRemainder(dividingBy: 360) + (end - start),
                             distance: run.distance, angle: sorted[sorted.count / 2])
        }
    }
}

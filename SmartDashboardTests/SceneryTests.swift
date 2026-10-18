import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SmartDashboard

/// 決まった地形(緯度経度から標高を返す)
private struct FakeTerrain: TerrainSampling {
    let height: (Double, Double) -> TerrainGrid.Sample

    func sample(latitude: Double, longitude: Double, distance: Double) -> TerrainGrid.Sample {
        height(latitude, longitude)
    }
}

/// 決まった水面
private struct FakeWater: WaterSampling {
    let component: (Double, Double) -> Int?

    func component(latitude: Double, longitude: Double) -> Int? {
        component(latitude, longitude)
    }
}

/// スコープの景色: 稜線、隠れた山、山の選び方と文字の重なり、水面の方角
final class SkylineTests: XCTestCase {
    private let lat = 35.0
    private let lon = 139.0

    private func distance(_ a: Double, _ b: Double) -> Double {
        WaypointMath.distance(fromLatitude: lat, longitude: lon, toLatitude: a, longitude: b)
    }

    /// 地球の丸みを補正した、平らな地面(海面)の見かけの地平線: 仰角 ≒ −2√(目の高さ ÷ 2R')、距離 ≒ √(2R'×目の高さ)
    private func flatHorizon(eye: Double) -> (angle: Double, distance: Double) {
        let effective = WaypointElevation.earthRadius / (1 - WaypointElevation.refraction)
        let distance = sqrt(2 * effective * eye)
        return (WaypointElevation.angle(targetAltitude: 0, observerAltitude: eye, distance: distance), distance)
    }

    func testFlatLandHorizon() {
        let terrain = FakeTerrain { _, _ in .elevation(0) }
        let (skyline, _) = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: 10, radius: 30_000, terrain: terrain)
        XCTAssertEqual(skyline.rayCount, 720)
        XCTAssertEqual(skyline.coverage, 1)
        let expected = flatHorizon(eye: 10)
        for bearing in [0.0, 90, 181.5, 359.5] {
            let horizon = skyline.ray(atBearing: bearing).horizon
            XCTAssertEqual(Double(horizon?.angle ?? 0), expected.angle, accuracy: 0.005, "\(bearing)")
            XCTAssertEqual(Double(horizon?.distance ?? 0), expected.distance, accuracy: expected.distance * 0.1)
        }
        XCTAssertLessThan(expected.angle, 0)
    }

    func testSeaIsTreatedAsSeaLevelAndShownAsWater() {
        let terrain = FakeTerrain { _, _ in .sea }
        let water = FakeWater { _, _ in 0 }
        let (skyline, hits) = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: 10, radius: 20_000, terrain: terrain, water: water)
        XCTAssertEqual(Double(skyline.horizonAngle(atBearing: 45) ?? 0), flatHorizon(eye: 10).angle, accuracy: 0.005)
        XCTAssertEqual(hits.count, skyline.rayCount)
        XCTAssertTrue(hits.allSatisfy { $0?.isSea == true })
        // 全方位が海: 0°をまたいでも1つの帯にまとまる。名前がなければ「海」
        let bands = WaterBands.make(hits: hits, step: skyline.step, map: .empty)
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands.first?.name, "海")
        XCTAssertEqual(bands.first?.width ?? 0, 360, accuracy: 0.6)
    }

    func testNearbyHillBlocksTheView() {
        // 北へ1kmの所に、半径300m・高さ100mの丘
        let hillLat = lat + 1000 / 111_320.0
        let terrain = FakeTerrain { a, b in
            WaypointMath.distance(fromLatitude: hillLat, longitude: self.lon, toLatitude: a, longitude: b) < 300 ? .elevation(100) : .elevation(0)
        }
        let (skyline, _) = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: 1.5, radius: 20_000, terrain: terrain)
        let north = skyline.horizonAngle(atBearing: 0) ?? -90
        XCTAssertGreaterThan(north, 5)
        XCTAssertLessThan(north, 10)
        XCTAssertEqual(Double(skyline.ray(atBearing: 0).horizon?.distance ?? 0), 700, accuracy: 60)
        XCTAssertEqual(skyline.horizonAngle(atBearing: 180) ?? 0, flatHorizon(eye: 1.5).angle, accuracy: 0.005)
        // 丘の向こう5kmの低い所は隠れ、高い所は見える。丘より手前は見える
        XCTAssertEqual(skyline.visibility(bearing: 0, distance: 5000, angle: 0), .hidden)
        XCTAssertEqual(skyline.visibility(bearing: 0, distance: 5000, angle: 12), .visible)
        XCTAssertEqual(skyline.visibility(bearing: 0, distance: 500, angle: 0), .visible)
        XCTAssertEqual(skyline.visibility(bearing: 180, distance: 5000, angle: 0), .visible)
    }

    func testFarMountainWithCurvatureAndHiddenPeakBehindIt() throws {
        // 東へ50kmに、高さ2000m(すそ野の半径10km)の円すいの山
        let peak = (latitude: lat, longitude: lon + 50_000 / (111_320 * cos(lat * .pi / 180)))
        let terrain = FakeTerrain { a, b in
            let d = WaypointMath.distance(fromLatitude: peak.latitude, longitude: peak.longitude, toLatitude: a, longitude: b)
            return .elevation(max(0, 2000 - d * 0.2))
        }
        let (skyline, _) = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: 1.5, radius: 100_000, terrain: terrain)
        let expected = WaypointElevation.angle(targetAltitude: 2000, observerAltitude: 1.5, distance: 50_000)
        XCTAssertEqual(expected, 2.1, accuracy: 0.05)
        let east = try XCTUnwrap(skyline.ray(atBearing: 90).horizon)
        XCTAssertEqual(Double(east.angle), expected, accuracy: 0.15)
        XCTAssertEqual(Double(east.distance), 50_000, accuracy: 1500)

        // 山の一覧: 山頂は見える。その奥(60km)の1500mの山は隠れる。範囲の外の山は選ばない
        let behind = (latitude: lat, longitude: lon + 60_000 / (111_320 * cos(lat * .pi / 180)))
        let catalog = [
            MountainCatalog.Entry(index: 0, name: "前山", peak: "", elevation: 2000, latitude: peak.latitude, longitude: peak.longitude, prefecture: ""),
            MountainCatalog.Entry(index: 1, name: "奥山", peak: "", elevation: 1500, latitude: behind.latitude, longitude: behind.longitude, prefecture: ""),
            MountainCatalog.Entry(index: 2, name: "遠山", peak: "", elevation: 3000, latitude: lat + 2, longitude: lon, prefecture: ""),
        ]
        let mountains = MountainSelection.select(catalog: catalog, latitude: lat, longitude: lon, eye: 1.5, radius: 100_000, skyline: skyline)
        XCTAssertEqual(mountains.map(\.entry.name), ["前山", "奥山"])
        XCTAssertEqual(mountains[0].visibility, .visible)
        XCTAssertEqual(mountains[1].visibility, .hidden)
        XCTAssertEqual(mountains[0].bearing, 90, accuracy: 0.5)

        // 稜線の線: 地平線の線ができる。濃さは遠いほど薄い
        let lines = RidgeExtractor.lines(from: skyline)
        XCTAssertTrue(lines.contains { $0.isHorizon && $0.points.count >= 3 })
        XCTAssertGreaterThan(RidgeLine.opacity(distance: 2000), RidgeLine.opacity(distance: 50_000))
    }

    func testMissingTerrainIsUnknown() {
        // 10kmより先はデータなし
        let terrain = FakeTerrain { a, b in
            WaypointMath.distance(fromLatitude: self.lat, longitude: self.lon, toLatitude: a, longitude: b) > 10_000 ? .missing : .elevation(0)
        }
        let (skyline, _) = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: 300, radius: 50_000, terrain: terrain)
        XCTAssertEqual(skyline.coverage, 0)
        XCTAssertEqual(skyline.visibility(bearing: 10, distance: 30_000, angle: -5), .unknown)
    }

    func testWaterBandDirection() throws {
        // 東(60°〜120°)の2kmより先に水面。地面は平ら
        let terrain = FakeTerrain { _, _ in .elevation(0) }
        let water = FakeWater { a, b in
            let d = WaypointMath.distance(fromLatitude: self.lat, longitude: self.lon, toLatitude: a, longitude: b)
            let bearing = WaypointMath.bearing(fromLatitude: self.lat, longitude: self.lon, toLatitude: a, longitude: b)
            return d >= 2000 && bearing >= 60 && bearing <= 120 ? 3 : nil
        }
        let (skyline, hits) = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: 30, radius: 20_000, terrain: terrain, water: water)
        let bands = WaterBands.make(hits: hits, step: skyline.step, map: .empty)
        let band = try XCTUnwrap(bands.first)
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(band.startBearing, 60, accuracy: 1)
        XCTAssertEqual(band.endBearing, 120, accuracy: 1)
        XCTAssertEqual(band.distance, 2000, accuracy: 60)
        XCTAssertEqual(band.centerBearing, 90, accuracy: 1)
        XCTAssertEqual(band.name, "湖・川")
        // 水面は見えている(目の高さより下)
        XCTAssertLessThan(band.angle, 0)
    }
}

final class SceneryLayoutTests: XCTestCase {
    func testLabelsDoNotOverlap() {
        let items = (0..<4).map { SceneryLabelLayout.Item(id: $0, x: 100, width: 80) }
        let rows = SceneryLabelLayout.place(items)
        // 同じ所の4つ: 3段に置き、4つ目は名前を出さない
        XCTAssertEqual(rows, [0: 0, 1: 1, 2: 2])
        let apart = [SceneryLabelLayout.Item(id: 0, x: 50, width: 60), SceneryLabelLayout.Item(id: 1, x: 200, width: 60)]
        XCTAssertEqual(SceneryLabelLayout.place(apart), [0: 0, 1: 0])
        XCTAssertEqual(SceneryLabelLayout.estimatedWidth("富士山 3776m", fontSize: 10), 3 * 10 + 6 * 6, accuracy: 0.01)
    }

    func testMountainPriority() {
        // 高い山・近い山ほど先。見えない山は後ろ
        let near = MountainSelection.priority(elevation: 1000, distance: 10_000, visibility: .visible)
        let far = MountainSelection.priority(elevation: 1000, distance: 90_000, visibility: .visible)
        let high = MountainSelection.priority(elevation: 3776, distance: 90_000, visibility: .visible)
        let hidden = MountainSelection.priority(elevation: 3776, distance: 10_000, visibility: .hidden)
        XCTAssertGreaterThan(near, far)
        XCTAssertGreaterThan(high, far)
        XCTAssertLessThan(hidden, far)
    }

    func testLayersAndRadiusSettings() {
        XCTAssertEqual(SceneryLayer.decode(nil), [.mountains, .skyline, .water])
        XCTAssertEqual(SceneryLayer.decode(["places", "skyline", "unknown"]), [.skyline, .places])
        XCTAssertEqual(SceneryRadius.clamped(77), SceneryRadius.initial)
        XCTAssertEqual(SceneryRadius.clamped(30), 30)
        XCTAssertEqual(SceneryRadius.initial, 100)
    }
}

final class SceneryDataTests: XCTestCase {
    func testBundledMountains() throws {
        let catalog = MountainCatalog.bundled
        XCTAssertGreaterThanOrEqual(catalog.entries.count, 1000)
        let fuji = try XCTUnwrap(catalog.entries.first { $0.name == "富士山" })
        XCTAssertEqual(fuji.elevation, 3776)
        XCTAssertEqual(fuji.latitude, 35.36, accuracy: 0.01)
        XCTAssertEqual(fuji.longitude, 138.73, accuracy: 0.01)
        XCTAssertEqual(fuji.displayName, fuji.peak.isEmpty ? "富士山" : "\(fuji.peak)(富士山)")
        XCTAssertFalse(catalog.version.isEmpty)
    }

    func testElevationTileValues() throws {
        XCTAssertEqual(GSIElevationTile.elevation(r: 0, g: 0, b: 0), 0)
        XCTAssertEqual(GSIElevationTile.elevation(r: 0, g: 1, b: 0), 2.56, accuracy: 0.0001)
        XCTAssertTrue(GSIElevationTile.elevation(r: 128, g: 0, b: 0).isNaN)
        XCTAssertEqual(GSIElevationTile.elevation(r: 255, g: 255, b: 255), -0.01, accuracy: 0.0001)

        // 1234.56m の PNG を作って読む(色の変換をしないこと)
        let value = 123_456
        let size = TerrainGrid.tileSize
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4] = UInt8((value >> 16) & 0xFF)
            pixels[i * 4 + 1] = UInt8((value >> 8) & 0xFF)
            pixels[i * 4 + 2] = UInt8(value & 0xFF)
            pixels[i * 4 + 3] = 255
        }
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let values = try XCTUnwrap(GSIElevationTile.decode(data as Data))
        XCTAssertEqual(values.count, size * size)
        XCTAssertEqual(Double(values[0]), 1234.56, accuracy: 0.01)
        XCTAssertEqual(Double(values[size * size - 1]), 1234.56, accuracy: 0.01)
    }

    func testTerrainGridZoomsAndNeededTiles() {
        XCTAssertEqual(TerrainGrid.zoom(forDistance: 1000), 12)
        XCTAssertEqual(TerrainGrid.zoom(forDistance: 20_000), 10)
        XCTAssertEqual(TerrainGrid.zoom(forDistance: 80_000), 9)
        let near = TerrainGrid.neededTiles(latitude: 35.68, longitude: 139.77, radius: 30_000)
        XCTAssertTrue(near.contains { $0.z == 12 })
        XCTAssertTrue(near.contains { $0.z == 10 })
        XCTAssertFalse(near.contains { $0.z == 9 })
        let far = TerrainGrid.neededTiles(latitude: 35.68, longitude: 139.77, radius: 100_000)
        XCTAssertTrue(far.contains { $0.z == 9 })
        XCTAssertLessThanOrEqual(far.count, 40)
        // タイルの番号と緯度経度の行き来
        let (key, fx, fy) = TileKey.locate(latitude: 35.3606, longitude: 138.7274, zoom: 12)
        let back = TileKey.coordinate(x: Double(key.x) + fx, y: Double(key.y) + fy, zoom: 12)
        XCTAssertEqual(back.latitude, 35.3606, accuracy: 1e-6)
        XCTAssertEqual(back.longitude, 138.7274, accuracy: 1e-6)
        // 海の上(データなし)は海、タイルがなければ分からない
        var tile = [Float](repeating: 10, count: TerrainGrid.tileSize * TerrainGrid.tileSize)
        tile[0] = .nan
        let corner = TileKey.coordinate(x: Double(key.x) + 0.001, y: Double(key.y) + 0.001, zoom: 12)
        let grid = TerrainGrid(tiles: [key: tile])
        XCTAssertEqual(grid.sample(latitude: corner.latitude, longitude: corner.longitude, distance: 100), .sea)
        XCTAssertEqual(grid.sample(latitude: 35.3606, longitude: 138.7274, distance: 100), .elevation(10))
        XCTAssertEqual(grid.sample(latitude: 35.3606, longitude: 138.7274, distance: 50_000), .missing)
    }

    func testVectorTileWaterAndNames() throws {
        let url = try XCTUnwrap(Bundle(for: SceneryDataTests.self).url(forResource: "gsi_bvmap_water", withExtension: "pbf"))
        let tile = try VectorTile(data: Data(contentsOf: url))
        XCTAssertEqual(tile.layers["waterarea"]?.features.count, 6)
        XCTAssertEqual(tile.layers["waterarea"]?.extent, 4096)
        let key = TileKey(z: 10, x: 909, y: 404)
        let names = SceneryLabelReader.names(tiles: [key: tile])
        XCTAssertTrue(names.contains { $0.name == "東京湾" && $0.kind == .sea })
        XCTAssertTrue(names.contains { $0.name == "鶴見川" && $0.kind == .river })
        // 1文字ずつの「浦賀水道」は、1つの名前にまとまる
        XCTAssertEqual(names.filter { $0.name == "浦賀水道" }.count, 1)

        let map = WaterMap.build(tiles: [key: tile], labels: names, zoom: 10)
        let sea = try XCTUnwrap(map.component(latitude: 35.25, longitude: 139.80))
        XCTAssertNil(map.component(latitude: 35.25, longitude: 139.65))
        XCTAssertNil(map.component(latitude: 35.30, longitude: 139.90))
        XCTAssertEqual(map.component(latitude: 35.35, longitude: 139.80), sea)
        let named = try XCTUnwrap(map.name(component: sea, nearLatitude: 35.25, longitude: 139.80))
        XCTAssertEqual(named.kind, .sea)
        XCTAssertTrue(["東京湾", "浦賀水道"].contains(named.name))
    }

    func testFillPolygonWithHole() {
        // 10×10 の四角に、4×4 の穴
        let outer: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let hole: [SIMD2<Double>] = [SIMD2(3, 3), SIMD2(3, 7), SIMD2(7, 7), SIMD2(7, 3)]
        var cells = [UInt32](repeating: 0, count: 12 * 12)
        WaterMap.fill(rings: [outer, hole], id: 1, cells: &cells, width: 12, height: 12)
        XCTAssertEqual(cells.filter { $0 == 1 }.count, 100 - 16)
        XCTAssertEqual(cells[5 * 12 + 5], 0)
        XCTAssertEqual(cells[1 * 12 + 1], 1)
        XCTAssertEqual(cells[11 * 12 + 11], 0)
    }

    func testUsageCategoryForSceneryTiles() {
        XCTAssertEqual(UsageCategory.from(url: SceneryTileKind.dem.url(TileKey(z: 10, x: 1, y: 2))), .scope)
        XCTAssertEqual(UsageCategory.from(url: SceneryTileKind.vector.url(TileKey(z: 8, x: 1, y: 2))), .scope)
        XCTAssertEqual(UsageCategory.from(url: URL(string: "https://cyberjapandata.gsi.go.jp/xyz/pale/10/1/2.png")), .mapTiles)
    }

    func testSceneryTileStoreSavesAndCountsTiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SceneryTileStore(root: root)
        let tile = SceneryTileRef(kind: .dem, key: TileKey(z: 9, x: 454, y: 202))
        XCTAssertFalse(store.exists(tile))
        try store.save(Data([1, 2, 3]), for: tile)
        XCTAssertTrue(store.exists(tile))
        XCTAssertEqual(store.usage().bytes, 3)
        XCTAssertTrue(store.url(for: tile).path.hasSuffix("dem/9/454/202.png"))
        let needed = SceneryTileStore.needed(latitude: 35.68, longitude: 139.77, radius: 50_000, includesVector: true)
        XCTAssertTrue(needed.contains { $0.kind == .vector && $0.key.z == 8 })
        store.removeAll()
        XCTAssertFalse(store.exists(tile))
    }
}

import XCTest
@testable import SmartDashboard

final class TileMathTests: XCTestCase {
    func testTileForTokyo() {
        // 東京駅付近。地理院タイルの座標と一致することを実際のタイルで確認済み。
        XCTAssertEqual(TileMath.tile(latitude: 35.68, longitude: 139.77, z: 14), TileCoord(z: 14, x: 14553, y: 6451))
        XCTAssertEqual(TileMath.tile(latitude: 35.68, longitude: 139.77, z: 5), TileCoord(z: 5, x: 28, y: 12))
        XCTAssertEqual(TileCoord(z: 14, x: 14553, y: 6451).parent, TileCoord(z: 13, x: 7276, y: 3225))
    }

    func testCountsMatchEnumeration() {
        let area = TileArea(name: "t", latitude: 35.68, longitude: 139.77, radiusKm: 20)
        for z in 9...14 {
            XCTAssertEqual(TileMath.tiles(in: area.bounds, z: z).count, TileMath.count(in: area.bounds, z: z))
        }
        let estimate = TileMath.estimate(area: area, maxZoom: 14)
        XCTAssertEqual(estimate.tileCount, TileMath.areaTiles(area, maxZoom: 14).count)
        XCTAssertGreaterThan(estimate.tileCount, 400)
        XCTAssertLessThan(estimate.tileCount, 1000)
        XCTAssertGreaterThan(TileMath.estimate(area: area, maxZoom: 16).bytes, estimate.bytes)
        XCTAssertEqual(Set(TileMath.nationwideTiles().map(\.z)), [5, 6, 7, 8])
    }

    func testZoomLevel() {
        XCTAssertEqual(TileMath.zoomLevel(longitudeDelta: 360, widthPoints: 256), 0)
        XCTAssertEqual(TileMath.zoomLevel(longitudeDelta: 360.0 / 1024, widthPoints: 256), 10)
    }

    func testMapMode() {
        let wifi = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: false, isWiFi: true)
        let cellular = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: false, isWiFi: false)
        let lowData = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: true, isWiFi: true)
        let offline = NetworkStatus(isOnline: false, isExpensive: false, isConstrained: false, isWiFi: false)
        XCTAssertEqual(MapMode.decide(network: wifi, allowAppleOnCellular: false), .apple)
        XCTAssertEqual(MapMode.decide(network: cellular, allowAppleOnCellular: false), .offline)
        XCTAssertEqual(MapMode.decide(network: cellular, allowAppleOnCellular: true), .apple)
        XCTAssertEqual(MapMode.decide(network: lowData, allowAppleOnCellular: true), .offline)
        XCTAssertEqual(MapMode.decide(network: offline, allowAppleOnCellular: true), .offline)
        XCTAssertTrue(MapMode.canDownloadTiles(network: wifi))
        XCTAssertFalse(MapMode.canDownloadTiles(network: cellular))
        XCTAssertFalse(MapMode.canDownloadTiles(network: lowData))
        XCTAssertFalse(MapMode.canDownloadTiles(network: offline))
    }

    func testTileStore() throws {
        let store = TileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = TileCoord(z: 9, x: 1, y: 2)
        let b = TileCoord(z: 9, x: 1, y: 3)
        XCTAssertEqual(store.missing(from: [a, b]), [a, b])
        try store.save(Data([1, 2, 3]), for: a)
        XCTAssertEqual(store.missing(from: [a, b]), [b])
        XCTAssertTrue(store.url(for: a).path.hasSuffix("/9/1/2.png"))
        XCTAssertEqual(store.usage().bytes, 3)
        XCTAssertEqual(store.remove([a, b]), 1)
        XCTAssertEqual(store.usage().count, 0)
    }

    func testTileURL() {
        XCTAssertEqual(TileDownloader.tileURL(TileCoord(z: 14, x: 14553, y: 6451)).absoluteString,
                       "https://cyberjapandata.gsi.go.jp/xyz/pale/14/14553/6451.png")
    }
}

final class PlaceNameTests: XCTestCase {
    func testReuseWithin500m() {
        let entries = [GeocodedPlace(latitude: 35.6900, longitude: 139.6920, name: "東京都新宿区西新宿")]
        // 約330m北
        XCTAssertEqual(PlaceNameResolver.nearest(in: entries, latitude: 35.6930, longitude: 139.6920, within: 500)?.name, "東京都新宿区西新宿")
        // 約1.1km北
        XCTAssertNil(PlaceNameResolver.nearest(in: entries, latitude: 35.7000, longitude: 139.6920, within: 500))
    }

    func testFormatName() {
        XCTAssertEqual(PlaceNameResolver.formatName(administrativeArea: "東京都", locality: "新宿区", subLocality: "西新宿", fallback: nil), "東京都新宿区西新宿")
        XCTAssertEqual(PlaceNameResolver.formatName(administrativeArea: nil, locality: nil, subLocality: nil, fallback: "どこか"), "どこか")
        XCTAssertNil(PlaceNameResolver.formatName(administrativeArea: nil, locality: nil, subLocality: nil, fallback: nil))
    }
}

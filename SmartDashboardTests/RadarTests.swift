import XCTest
@testable import SmartDashboard

final class RadarTests: XCTestCase {
    private func load(_ name: String) throws -> [RadarTargetTime] {
        try JSONDecoder().decode([RadarTargetTime].self, from: Fixture.data(name))
    }

    func testTimelineFromRealResponses() throws {
        let observed = try load("jma_target_times_n1")
        let forecast = try load("jma_target_times_n2")
        let latest = try XCTUnwrap(RadarTimeline.latestObserved(observed))
        XCTAssertEqual(latest, RadarFrame(basetime: "20260919092500", validtime: "20260919092500", isForecast: false))

        // 予測の basetime は実況より古いことがある。実況より先の時刻だけを5分刻みで使う。
        let frames = RadarTimeline.forecasts(forecast, after: latest)
        XCTAssertEqual(frames.count, 11)
        XCTAssertEqual(frames.first?.validtime, "20260919093000")
        XCTAssertEqual(frames.last?.validtime, "20260919102000")
        XCTAssertTrue(frames.allSatisfy { $0.isForecast && $0.basetime == "20260919092000" })
    }

    func testTimeParsingIsUTC() throws {
        let date = try XCTUnwrap(RadarTimeline.parse("20260919092500"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        XCTAssertEqual(parts.hour, 18)
        XCTAssertEqual(parts.minute, 25)
        XCTAssertNil(RadarTimeline.parse("2026-09-19"))
    }

    func testUnexpectedFormatFailsToDecode() {
        let json = "{\"times\":[\"20260919092500\"]}"
        XCTAssertThrowsError(try JSONDecoder().decode([RadarTargetTime].self, from: Data(json.utf8)))
        XCTAssertNil(RadarTimeline.latestObserved([RadarTargetTime(basetime: "x", validtime: "y", elements: nil)]))
    }

    func testSourceZoomUsesEvenLevels() {
        XCTAssertEqual((3...13).map { RadarTiles.sourceZoom(for: $0) }, [4, 4, 4, 6, 6, 8, 8, 10, 10, 10, 10])
    }

    func testSourceTileAndCropRect() throws {
        // z=10 はそのまま取得する
        let direct = try XCTUnwrap(RadarTiles.source(for: TileCoord(z: 10, x: 909, y: 403)))
        XCTAssertEqual(direct.tile, TileCoord(z: 10, x: 909, y: 403))
        XCTAssertEqual(direct.unitRect, CGRect(x: 0, y: 0, width: 1, height: 1))

        // z=12 は z=10 のタイルの 1/4 四方を拡大する
        let scaled = try XCTUnwrap(RadarTiles.source(for: TileCoord(z: 12, x: 3638, y: 1613)))
        XCTAssertEqual(scaled.tile, TileCoord(z: 10, x: 909, y: 403))
        XCTAssertEqual(scaled.unitRect, CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25))

        // z=9 は z=8 を拡大する
        let odd = try XCTUnwrap(RadarTiles.source(for: TileCoord(z: 9, x: 455, y: 201)))
        XCTAssertEqual(odd.tile, TileCoord(z: 8, x: 227, y: 100))
        XCTAssertEqual(odd.unitRect, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testTileURL() {
        let frame = RadarFrame(basetime: "20260919092000", validtime: "20260919093000", isForecast: true)
        XCTAssertEqual(RadarTiles.url(frame: frame, tile: TileCoord(z: 8, x: 227, y: 100)).absoluteString,
                       "https://www.jma.go.jp/bosai/jmatile/data/nowc/20260919092000/none/20260919093000/surf/hrpns/8/227/100.png")
    }

    @MainActor
    func testFrameLabel() {
        let latest = RadarFrame(basetime: "20260919092500", validtime: "20260919092500", isForecast: false)
        let forecast = RadarFrame(basetime: "20260919092000", validtime: "20260919094000", isForecast: true)
        XCTAssertEqual(RadarStore.label(for: latest, latest: latest), "実況 18:25")
        XCTAssertEqual(RadarStore.label(for: forecast, latest: latest), "予測 18:40 (+15分)")
    }
}

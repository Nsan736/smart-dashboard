import XCTest
@testable import SmartDashboard

final class RainNowcastTests: XCTestCase {
    private func tileData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: RainNowcastTests.self).url(forResource: "jma_nowcast_tile", withExtension: "png"))
        return try Data(contentsOf: url)
    }

    /// 実際のタイル(z10, 911/409, 2026-09-19)で、Pillowで読んだ値と同じ段階になることを確かめる
    func testPixelLevelsFromRealTile() throws {
        let data = try tileData()
        XCTAssertEqual(RainPixelReader.level(in: data, x: 0, y: 0, radius: 0), 0)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 46, y: 0, radius: 0), 1)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 64, y: 0, radius: 0), 2)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 73, y: 0, radius: 0), 3)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 83, y: 0, radius: 0), 4)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 137, y: 0, radius: 0), 5)
    }

    func testNeighborhoodReducesEdgeErrors() throws {
        let data = try tileData()
        // (45, 0) は雨の境目のすぐ外側。1ピクセルずれると結果が変わるので、周囲も見て判定する。
        XCTAssertEqual(RainPixelReader.level(in: data, x: 45, y: 0, radius: 0), 0)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 45, y: 0), 1)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 0, y: 0), 0)
        // 範囲外の指定でも落ちない
        XCTAssertNotNil(RainPixelReader.level(in: data, x: 300, y: -4))
        XCTAssertNil(RainPixelReader.level(in: Data([1, 2, 3]), x: 0, y: 0))
    }

    func testRowsAreReadFromTop() throws {
        let data = try tileData()
        XCTAssertEqual(RainPixelReader.level(in: data, x: 0, y: 255, radius: 0), 1)
        XCTAssertEqual(RainPixelReader.level(in: data, x: 0, y: 0, radius: 0), 0)
    }

    func testColorTable() {
        XCTAssertEqual(RainLevel.level(r: 255, g: 255, b: 255, a: 0), 0)
        XCTAssertEqual(RainLevel.level(r: 242, g: 242, b: 255, a: 255), 1)
        XCTAssertEqual(RainLevel.level(r: 180, g: 0, b: 104, a: 255), 8)
        XCTAssertEqual(RainLevel.level(r: 250, g: 243, b: 4, a: 255), 5)
        // 表にない色は、仕様変更の可能性があるので読めない扱いにする
        XCTAssertNil(RainLevel.level(r: 0, g: 200, b: 0, a: 255))
        XCTAssertEqual(RainLevel.rangeText(4), "10〜20 mm/h")
        XCTAssertEqual(RainLevel.rangeText(8), "80 mm/h以上")
        XCTAssertEqual(RainLevel.representative(2), 3)
    }

    func testPixelPosition() {
        let position = TileMath.pixel(latitude: 35.68, longitude: 139.77, z: 10)
        XCTAssertEqual(position.tile, TileCoord(z: 10, x: 909, y: 403))
        XCTAssertEqual(position.x, 145)
        XCTAssertEqual(position.y, 59)
    }

    // MARK: - 要約

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func nowcast(_ levels: [Int], observedAgo: TimeInterval = 120) -> RainNowcast {
        let observed = now.addingTimeInterval(-observedAgo)
        let points = levels.enumerated().map { index, level in
            RainNowcast.Point(time: observed.addingTimeInterval(Double(index) * 300), isForecast: index > 0, level: level)
        }
        return RainNowcast(latitude: 35.68, longitude: 139.77, points: points)
    }

    private func slots(_ values: [Double]) -> [WeatherSnapshot.RainSlot] {
        values.enumerated().map { WeatherSnapshot.RainSlot(time: now.addingTimeInterval(Double($0.offset) * 900), precipitation: $0.element) }
    }

    func testDryNowRainLater() {
        // 実況は2分前。8コマ目(実況の40分後、今から38分後)から弱い雨
        let outlook = RainOutlook.make(nowcast: nowcast([0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 2]), modelSlots: slots([0, 0, 0, 0, 0.3, 0.3, 0, 0]), now: now)
        XCTAssertEqual(outlook?.headline, "今は降っていません。40分後から弱い雨の予想")
        XCTAssertEqual(outlook?.later, "1〜2時間後は雨の予報あり(予報モデル)")
        XCTAssertNil(outlook?.note)
    }

    func testRainingNowStopsSoon() {
        let outlook = RainOutlook.make(nowcast: nowcast([5, 5, 4, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]), modelSlots: slots([1, 0, 0, 0, 0, 0, 0, 0]), now: now)
        XCTAssertEqual(outlook?.headline, "今、強い雨。20分ほどでやむ予想")
        XCTAssertEqual(outlook?.later, "1〜2時間後は雨の予報なし(予報モデル)")
    }

    func testModelSaysRainButNowcastSaysDry() {
        // 予報モデルは雨でも、直近1時間はナウキャストを優先する
        let outlook = RainOutlook.make(nowcast: nowcast(Array(repeating: 0, count: 13)), modelSlots: slots([0.4, 0.4, 0.4, 0.4, 0, 0, 0, 0]), now: now)
        XCTAssertEqual(outlook?.headline, "今は降っていません。1時間は雨の予想なし")
        XCTAssertEqual(RainOutlook.make(nowcast: nowcast(Array(repeating: 3, count: 13)), modelSlots: [], now: now)?.headline, "今、雨。1時間は降り続く予想")
    }

    func testFallsBackToModelWhenNowcastIsMissingOrOld() {
        let model = slots([0, 0, 0, 0.2, 0.2, 0, 0, 0])
        let missing = RainOutlook.make(nowcast: nil, modelSlots: model, now: now)
        XCTAssertEqual(missing?.headline, "45分後から雨の予報")
        XCTAssertEqual(missing?.note, RainOutlook.fallbackNote)
        let old = RainOutlook.make(nowcast: nowcast([0, 0, 0], observedAgo: 40 * 60), modelSlots: model, now: now)
        XCTAssertEqual(old?.note, RainOutlook.fallbackNote)
        XCTAssertNil(RainOutlook.make(nowcast: nil, modelSlots: [], now: now))
    }

    func testCacheIsReusedOnlyNearby() {
        let value = nowcast([0])
        XCTAssertTrue(RainNowcastStore.covers(value, latitude: 35.6810, longitude: 139.7700))
        XCTAssertFalse(RainNowcastStore.covers(value, latitude: 35.6900, longitude: 139.7700))
    }
}

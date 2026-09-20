import XCTest
@testable import SmartDashboard

/// 観測点名と位置の対応付けと、地図に描くデータの作成
final class IntensityStationTests: XCTestCase {
    private let table = IntensityStationTable(fetched: "2026-09-20", stations: [
        "天草市牛深町": .init(latitude: 32.19, longitude: 130.03, prefecture: 43),
        "天草市天草町": .init(latitude: 32.41, longitude: 130.0, prefecture: 43),
        "長島町鷹巣": .init(latitude: 32.2, longitude: 130.18, prefecture: 46),
        "南島原市口之津町": .init(latitude: 32.61, longitude: 130.19, prefecture: 42),
    ])

    func testDecodesBundledFormat() throws {
        let json = #"{"source":"気象庁","fetched":"2026-09-20","stations":[["えりも町えりも岬",41.94,143.24,1],["那覇市樋川",26.21,127.69,47]]}"#
        let decoded = try IntensityStationTable(data: Data(json.utf8))
        XCTAssertEqual(decoded.fetched, "2026-09-20")
        XCTAssertEqual(decoded.stations.count, 2)
        XCTAssertEqual(decoded.stations["那覇市樋川"], .init(latitude: 26.21, longitude: 127.69, prefecture: 47))
        XCTAssertThrowsError(try IntensityStationTable(data: Data("broken".utf8)))
    }

    func testBundledTableIsAvailable() {
        let bundled = IntensityStationTable.bundled
        // 気象庁の一覧は約4,400点。取得日を記録している
        XCTAssertGreaterThan(bundled.stations.count, 4000)
        XCTAssertFalse(bundled.fetched.isEmpty)
        // 日本の範囲に入っている
        XCTAssertTrue(bundled.stations.values.allSatisfy { (20...46).contains($0.latitude) && (122...154).contains($0.longitude) && (1...47).contains($0.prefecture) })
    }

    func testMatchingByNameAndDrawOrder() {
        let points = [
            QuakePoint(prefecture: "熊本県", name: "天草市牛深町", scale: 30),
            QuakePoint(prefecture: "長崎県", name: "南島原市口之津町", scale: 10),
            QuakePoint(prefecture: "熊本県", name: "天草市天草町", scale: 20),
            QuakePoint(prefecture: "鹿児島県", name: "長島町鷹巣", scale: 30),
            QuakePoint(prefecture: "熊本県", name: "一覧にない観測点", scale: 40),
            QuakePoint(prefecture: "熊本県", name: "熊本県天草・芦北", scale: 30),
        ]
        let result = QuakeMapDots.make(points: points, table: table)
        // 対応した観測点だけを地図に出す。震度の小さい順に並べ、あとに描く大きい震度が上に重なる
        XCTAssertEqual(result.dots.map(\.scale), [10, 20, 30, 30])
        XCTAssertEqual(result.dots.first, MapIntensityDot(latitude: 32.61, longitude: 130.19, scale: 10))
        XCTAssertEqual(result.dots.last, MapIntensityDot(latitude: 32.2, longitude: 130.18, scale: 30))
        // 対応しない観測点(新しい観測点や、震度速報の地域名)は、地図には出さず、一覧用に返す
        XCTAssertEqual(result.unmatched.map(\.name), ["一覧にない観測点", "熊本県天草・芦北"])
        // 凡例は、地図に出ている震度だけ(大きい順)
        XCTAssertEqual(QuakeMapDots.legendScales(result.dots), [30, 20, 10])
    }

    func testDuplicatesUseLargerScaleAndEmptyInput() {
        let points = [QuakePoint(prefecture: "熊本県", name: "天草市牛深町", scale: 20),
                      QuakePoint(prefecture: "熊本県", name: "天草市牛深町", scale: 40),
                      QuakePoint(prefecture: "熊本県", name: "天草市天草町", scale: 0)]
        let result = QuakeMapDots.make(points: points, table: table)
        XCTAssertEqual(result.dots, [MapIntensityDot(latitude: 32.19, longitude: 130.03, scale: 40)])
        XCTAssertTrue(result.unmatched.isEmpty)
        XCTAssertEqual(QuakeMapDots.make(points: [], table: table), QuakeMapDots.Result(dots: [], unmatched: []))
        // 表が読めなかった場合は、点が出ないだけ
        let empty = IntensityStationTable(fetched: "", stations: [:])
        XCTAssertTrue(QuakeMapDots.make(points: points, table: empty).dots.isEmpty)
    }

    func testFixturePointsMatchBundledTable() throws {
        // 実際の応答の観測点(熊本県の6地点)が、同梱した表と名前で対応する
        let quakes = QuakeList.make(try P2PQuakeItem.decode(Fixture.data("p2pquake_history")))
        let result = QuakeMapDots.make(points: quakes[1].points ?? [], table: .bundled)
        XCTAssertEqual(result.dots.count + result.unmatched.count, 6)
        XCTAssertGreaterThanOrEqual(result.dots.count, 5)
        XCTAssertEqual(result.dots.map(\.scale), result.dots.map(\.scale).sorted())
    }

    func testColorsAreSharedBetweenListAndMap() {
        // 一覧のラベルと、地図の点は、同じ色の値から作る
        XCTAssertEqual(SeismicScaleStyle.rgb(30)?.blue, 1.0)
        XCTAssertEqual(SeismicScaleStyle.rgb(70)?.red, 0.71)
        XCTAssertNotNil(SeismicScaleStyle.rgb(46))
        XCTAssertNil(SeismicScaleStyle.rgb(0))
    }
}

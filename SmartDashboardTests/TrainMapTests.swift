import CoreGraphics
import UIKit
import XCTest
@testable import SmartDashboard

final class TrainMapTests: XCTestCase {
    private func railway() throws -> ODPTRailway {
        try XCTUnwrap(ODPTClient.decode([ODPTRailway].self, from: Fixture.data("odpt_railway")).first)
    }

    private func stations() throws -> [ODPTStation] {
        try ODPTClient.decode([ODPTStation].self, from: Fixture.data("odpt_station"))
    }

    func testStationCoordinatesAreDecoded() throws {
        let list = try stations()
        XCTAssertEqual(list.count, 3)
        let magome = try XCTUnwrap(list.first { $0.sameAs == "odpt.Station:Toei.Asakusa.Magome" })
        XCTAssertEqual(magome.latitude, 35.596773)
        XCTAssertEqual(magome.longitude, 139.711884)
        XCTAssertEqual(magome.name, "馬込")
        XCTAssertEqual(try railway().color, "#FF535F")
    }

    /// 線は odpt:Railway の駅の順に結ぶ(odpt:Station の並び順には依存しない)
    func testShapeFollowsStationOrder() throws {
        let shape = RailwayShape.build(railway: try railway(), stations: try stations())
        XCTAssertEqual(shape.stops.map(\.name), ["西馬込", "馬込", "中延"])
        XCTAssertEqual(shape.stops.first?.latitude, 35.58705)
        XCTAssertEqual(shape.colorHex, "#FF535F")
        XCTAssertTrue(shape.missingStationIDs.isEmpty)
        XCTAssertTrue(shape.isDrawable)

        // 端末に保存して読み直せる
        let again = try JSONDecoder().decode(RailwayShape.self, from: JSONEncoder().encode(shape))
        XCTAssertEqual(again, shape)
    }

    func testStationsWithoutCoordinatesAreReported() throws {
        let json = """
        [{"owl:sameAs":"odpt.Station:Toei.Asakusa.NishiMagome","odpt:stationTitle":{"ja":"西馬込"},"geo:lat":35.58705,"geo:long":139.706086},
         {"owl:sameAs":"odpt.Station:Toei.Asakusa.Magome","odpt:stationTitle":{"ja":"馬込"}}]
        """
        let list = try ODPTClient.decode([ODPTStation].self, from: Data(json.utf8))
        let shape = RailwayShape.build(railway: try railway(), stations: list)
        XCTAssertEqual(shape.stops.count, 1)
        XCTAssertEqual(shape.missingStationIDs, ["odpt.Station:Toei.Asakusa.Magome", "odpt.Station:Toei.Asakusa.Nakanobu"])
        XCTAssertFalse(shape.isDrawable)
    }

    func testMarkersAreUniquePerStation() throws {
        let shape = RailwayShape.build(railway: try railway(), stations: try stations())
        func registered(_ direction: String) -> RegisteredStation {
            RegisteredStation(operatorID: "odpt.Operator:Toei", railwayID: shape.railwayID, railwayName: "浅草線",
                              stationID: "odpt.Station:Toei.Asakusa.Magome", stationName: "馬込",
                              directionID: direction, directionName: direction)
        }
        let markers = TrainMapBuilder.markers(stations: [registered("N"), registered("S")], shapes: [shape.railwayID: shape])
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.coordinate.latitude, 35.596773)
        XCTAssertTrue(TrainMapBuilder.markers(stations: [registered("N")], shapes: [:]).isEmpty)
    }

    func testSummaryAndSorting() {
        let lines = ["A", "B", "C", "D"].map { RegisteredLine(operatorID: "op", railwayID: $0, railwayName: $0) }
        func item(_ id: String, _ status: TrainStatus) -> TrainInfoItem {
            TrainInfoItem(railwayID: id, railwayName: id, status: status, statusText: nil, text: nil)
        }
        XCTAssertEqual(TrainSummary.text(lines: [], items: []), "路線が登録されていません")
        XCTAssertEqual(TrainSummary.text(lines: lines, items: []), "運行情報は未取得です")
        let allNormal = lines.map { item($0.railwayID, .normal) }
        XCTAssertEqual(TrainSummary.text(lines: lines, items: allNormal), "登録路線はすべて平常運転")
        XCTAssertEqual(TrainSummary.text(lines: lines, items: Array(allNormal.prefix(2))), "取得できた2路線はすべて平常運転")

        let mixed = [item("A", .normal), item("B", .delay), item("C", .suspended), item("D", .delay)]
        XCTAssertEqual(TrainSummary.text(lines: lines, items: mixed), "1路線で見合わせ・運休、2路線で遅延")
        // 状況が悪い路線が先頭。同じ状況なら登録順。
        XCTAssertEqual(TrainSummary.sorted(lines, items: mixed).map(\.railwayID), ["C", "B", "D", "A"])
        XCTAssertEqual(TrainSummary.sorted(lines, items: [item("D", .normal)]).map(\.railwayID), ["D", "A", "B", "C"])
    }

    func testStatusColorsAndHex() throws {
        XCTAssertEqual(TrainMapBuilder.uiColor(.normal), .systemGreen)
        XCTAssertEqual(TrainMapBuilder.uiColor(.delay), .systemYellow)
        XCTAssertEqual(TrainMapBuilder.uiColor(.suspended), .systemRed)
        XCTAssertEqual(TrainMapBuilder.uiColor(nil), .systemGray)

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(try XCTUnwrap(UIColor(hex: "#FF535F")).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 1, accuracy: 0.001)
        XCTAssertEqual(green, 83.0 / 255, accuracy: 0.001)
        XCTAssertEqual(blue, 95.0 / 255, accuracy: 0.001)
        XCTAssertNil(UIColor(hex: "red"))
        XCTAssertNil(UIColor(hex: nil))
    }

    func testTapDistanceToPolyline() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        XCTAssertEqual(MapGeometry.distance(from: CGPoint(x: 50, y: 10), toPolyline: line), 10, accuracy: 0.001)
        XCTAssertEqual(MapGeometry.distance(from: CGPoint(x: 130, y: 50), toPolyline: line), 30, accuracy: 0.001)
        XCTAssertEqual(MapGeometry.distance(from: CGPoint(x: -30, y: -40), toPolyline: line), 50, accuracy: 0.001)
        XCTAssertEqual(MapGeometry.distance(from: CGPoint(x: 3, y: 4), toPolyline: [CGPoint(x: 0, y: 0)]), 5, accuracy: 0.001)
    }
}

import XCTest
@testable import SmartDashboard

/// 駅と路線の検索(正規化、駅ナンバリングと ID での一致、同じ名前の駅のまとめ方、並び順)
final class StationSearchTests: XCTestCase {
    private let oedo = "odpt.Railway:Toei.Oedo"
    private let toeiShinjuku = "odpt.Railway:Toei.Shinjuku"
    private let asakusa = "odpt.Railway:Toei.Asakusa"
    private let marunouchi = "odpt.Railway:TokyoMetro.Marunouchi"

    private func station(_ id: String, _ name: String, en: String?, reading: String? = nil, code: String?,
                         railway: String, railwayName: String, operatorID: String, operatorName: String) -> SearchStation {
        SearchStation(id: id, name: name, nameEn: en, reading: reading, code: code, railwayID: railway, railwayName: railwayName,
                      operatorID: operatorID, operatorName: operatorName, colorHex: nil, point: GeoPoint(35.69, 139.70))
    }

    private func index() -> StationSearchIndex {
        let toei = "odpt.Operator:Toei"
        let metro = "odpt.Operator:TokyoMetro"
        let stations = [
            station("odpt.Station:TokyoMetro.Marunouchi.Shinjuku", "新宿", en: "Shinjuku", reading: "しんじゅく", code: "M08",
                    railway: marunouchi, railwayName: "丸ノ内線", operatorID: metro, operatorName: "東京メトロ"),
            station("odpt.Station:Toei.Oedo.Shinjuku", "新宿", en: "Shinjuku", code: "E-27",
                    railway: oedo, railwayName: "大江戸線", operatorID: toei, operatorName: "都営"),
            station("odpt.Station:Toei.Shinjuku.Shinjuku", "新宿", en: "Shinjuku", code: "S-01",
                    railway: toeiShinjuku, railwayName: "新宿線", operatorID: toei, operatorName: "都営"),
            station("odpt.Station:TokyoMetro.Marunouchi.ShinjukuSanchome", "新宿三丁目", en: "Shinjuku-sanchome", reading: "しんじゅくさんちょうめ",
                    code: "M09", railway: marunouchi, railwayName: "丸ノ内線", operatorID: metro, operatorName: "東京メトロ"),
            station("odpt.Station:Toei.Oedo.ShinjukuNishiguchi", "新宿西口", en: "Shinjuku-nishiguchi", code: "E-01",
                    railway: oedo, railwayName: "大江戸線", operatorID: toei, operatorName: "都営"),
            station("odpt.Station:TokyoMetro.Marunouchi.NishiShinjuku", "西新宿", en: "Nishi-shinjuku", reading: "にししんじゅく", code: "M07",
                    railway: marunouchi, railwayName: "丸ノ内線", operatorID: metro, operatorName: "東京メトロ"),
            station("odpt.Station:Toei.Asakusa.NishiMagome", "西馬込", en: "Nishi-magome", code: "A-01",
                    railway: asakusa, railwayName: "浅草線", operatorID: toei, operatorName: "都営"),
        ]
        let railways = [
            SearchRailway(id: marunouchi, name: "丸ノ内線", nameEn: "Marunouchi Line", operatorID: metro, operatorName: "東京メトロ", colorHex: "#F62E36"),
            SearchRailway(id: "odpt.Railway:TokyoMetro.MarunouchiBranch", name: "丸ノ内線支線", nameEn: "Marunouchi Branch Line",
                          operatorID: metro, operatorName: "東京メトロ", colorHex: nil),
            SearchRailway(id: oedo, name: "大江戸線", nameEn: "Oedo Line", operatorID: toei, operatorName: "都営", colorHex: "#CE045B"),
        ]
        return StationSearchIndex(stations: stations, railways: railways)
    }

    private func names(_ query: String, registered: Set<String> = []) -> [String] {
        index().search(query, registered: registered).groups.map(\.name)
    }

    func testGroupsStationsWithTheSameName() throws {
        let d = index()
        XCTAssertEqual(d.groups.count, 5)
        XCTAssertEqual(d.stationCount, 7)
        let shinjuku = try XCTUnwrap(d.group(named: "新宿"))
        XCTAssertEqual(shinjuku.stations.count, 3)
        // 登録済みの路線の駅が、グループの中でも先
        let ordered = try XCTUnwrap(d.group(named: "新宿", registered: [toeiShinjuku]))
        XCTAssertEqual(ordered.stations.first?.railwayID, toeiShinjuku)
        XCTAssertEqual(d.search("新宿", registered: [toeiShinjuku]).groups.first?.stations.first?.railwayID, toeiShinjuku)
        XCTAssertEqual(d.station("odpt.Station:Toei.Oedo.Shinjuku")?.railwayName, "大江戸線")
    }

    func testOrderExactPrefixContainsAndRegisteredFirst() {
        // 完全一致 → 前方一致 → 部分一致。同じなら名前の順(新宿三丁目 < 新宿西口)
        XCTAssertEqual(names("新宿"), ["新宿", "新宿三丁目", "新宿西口", "西新宿"])
        // 同じ一致の強さなら、登録済みの路線の駅を先に
        XCTAssertEqual(names("新宿", registered: [oedo]), ["新宿", "新宿西口", "新宿三丁目", "西新宿"])
        // 登録済みでも、一致の強さの順が先
        XCTAssertEqual(names("新宿", registered: [asakusa]).first, "新宿")
        XCTAssertEqual(names("西"), ["西新宿", "西馬込", "新宿西口"])
        XCTAssertTrue(names("").isEmpty)
        XCTAssertTrue(names("   ").isEmpty)
        XCTAssertTrue(names("存在しない駅").isEmpty)
    }

    func testNormalization() {
        // カタカナ・ひらがな(東京メトロの読み仮名で、同じ名前の都営の駅もまとめて出る)
        XCTAssertEqual(names("シンジュク").first, "新宿")
        XCTAssertEqual(names("しんじゅく").first, "新宿")
        // 全角・半角・大文字小文字
        XCTAssertEqual(names("ｓｈｉｎｊｕｋｕ").first, "新宿")
        XCTAssertEqual(names("SHINJUKU").first, "新宿")
        // 英語名の記号(ハイフン)の有無
        XCTAssertEqual(names("nishimagome"), ["西馬込"])
        XCTAssertEqual(names("Nishi-Magome"), ["西馬込"])
        XCTAssertEqual(names("shinjuku-nishi"), ["新宿西口"])
    }

    func testStationCodes() {
        XCTAssertEqual(names("M08"), ["新宿"])
        XCTAssertEqual(names("m08"), ["新宿"])
        XCTAssertEqual(names("Ｍ０８"), ["新宿"])
        // 「E-27」のような記号入りの番号も、記号なしで探せる
        XCTAssertEqual(names("E27"), ["新宿"])
        XCTAssertEqual(names("e-27"), ["新宿"])
        XCTAssertEqual(names("A01"), ["西馬込"])
        // 前方一致(M0 → M07, M08, M09)
        XCTAssertEqual(Set(names("M0")), ["新宿", "新宿三丁目", "西新宿"])
    }

    func testODPTIDs() {
        XCTAssertEqual(names("TokyoMetro.Marunouchi.Shinjuku").first, "新宿")
        XCTAssertEqual(names("odpt.Station:Toei.Oedo.ShinjukuNishiguchi"), ["新宿西口"])
        // 一部分でも
        XCTAssertEqual(names("Marunouchi.Shinjuku"), ["新宿", "新宿三丁目"])
        XCTAssertEqual(names("oedo.shin"), ["新宿", "新宿西口"])
    }

    func testRailways() {
        let d = index()
        XCTAssertEqual(d.search("丸ノ内").railways.map(\.name), ["丸ノ内線", "丸ノ内線支線"])
        XCTAssertEqual(d.search("まるのうち").railways.count, 0)
        XCTAssertEqual(d.search("marunouchi").railways.map(\.name), ["丸ノ内線", "丸ノ内線支線"])
        XCTAssertEqual(d.search("丸ノ内線支線").railways.map(\.name), ["丸ノ内線支線"])
        XCTAssertEqual(d.search("TokyoMetro.MarunouchiBranch").railways.map(\.name), ["丸ノ内線支線"])
        // 同じ一致の強さなら登録済みの路線を先に
        XCTAssertEqual(d.search("line", registered: [oedo]).railways.first?.name, "大江戸線")
    }

    func testMakeFromODPTStations() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data("odpt_discovery")) as? [String: Any])
        let stations = try ODPTClient.decode([ODPTStation].self, from: JSONSerialization.data(withJSONObject: object["stations"] as? [Any] ?? []))
        let railways = try ODPTClient.decode([ODPTRailway].self, from: JSONSerialization.data(withJSONObject: object["railways"] as? [Any] ?? []))
        let metro = try XCTUnwrap(stations.first { $0.sameAs == "odpt.Station:TokyoMetro.Marunouchi.Shinjuku" })
        XCTAssertEqual(metro.stationCode, "M08")
        XCTAssertEqual(metro.stationTitle?.jaHrkt, "しんじゅく")
        XCTAssertEqual(metro.operatorID, "odpt.Operator:TokyoMetro")
        let byOperator = Dictionary(grouping: stations) { $0.operatorID ?? "" }
        let d = StationSearchIndex.make(stations: byOperator, railways: railways,
                                        operatorNames: ["odpt.Operator:TokyoMetro": "東京メトロ", "odpt.Operator:Toei": "都営(東京都交通局)"])
        XCTAssertEqual(d.stationCount, 4)
        let found = try XCTUnwrap(d.search("しんじゅく").groups.first?.stations.first)
        XCTAssertEqual(found.code, "M08")
        XCTAssertEqual(found.railwayName, "丸ノ内線")
        XCTAssertEqual(found.operatorName, "東京メトロ")
        XCTAssertEqual(found.colorHex, "#F62E36")
        XCTAssertNotNil(found.point)
        XCTAssertEqual(d.search("A-01").groups.map(\.name), ["西馬込"])
        XCTAssertEqual(d.search("TX03").groups.first?.stations.first?.operatorName, "MIR")
        // 路線は、駅の一覧のある事業者の分だけ
        XCTAssertEqual(Set(d.railways.map(\.operatorID)), Set(byOperator.keys))
    }

    func testPreferredStationForTheMap() throws {
        let group = try XCTUnwrap(index().group(named: "新宿"))
        XCTAssertEqual(MovementControlBar.preferred(in: group, drawn: [oedo])?.railwayID, oedo)
        XCTAssertNotNil(MovementControlBar.preferred(in: group, drawn: []))
    }

    func testCompactForm() {
        XCTAssertEqual(StationSearchIndex.compact("i-13"), "i13")
        XCTAssertEqual(StationSearchIndex.compact("nishi-magome"), "nishimagome")
        XCTAssertEqual(StationSearchIndex.compact("新宿"), "新宿")
        XCTAssertEqual(StationSearchIndex.shortID("odpt.Station:Toei.Oedo.Shinjuku"), "Toei.Oedo.Shinjuku")
    }
}

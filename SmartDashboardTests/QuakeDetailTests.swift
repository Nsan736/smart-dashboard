import XCTest
@testable import SmartDashboard

/// 地震の詳細: 報の統合、震度の階層化、震源までの距離と方角、津波の値の変換
final class QuakeDetailTests: XCTestCase {
    private func item(type: String, issued: String, name: String, magnitude: Double, depth: Double, maxScale: Int,
                      tsunami: String = "None", correct: String = "None", points: String = "[]") throws -> P2PQuakeItem {
        let json = """
        {"earthquake":{"time":"2026/09/20 10:00:00","maxScale":\(maxScale),"domesticTsunami":"\(tsunami)","foreignTsunami":"Unknown",
          "hypocenter":{"name":"\(name)","magnitude":\(magnitude),"depth":\(depth),"latitude":\(name.isEmpty ? -200 : 35.0),"longitude":\(name.isEmpty ? -200 : 140.0)}},
         "issue":{"type":"\(type)","time":"\(issued)","correct":"\(correct)"},"points":\(points)}
        """
        return try JSONDecoder().decode(P2PQuakeItem.self, from: Data(json.utf8))
    }

    func testFixtureUsesMostDetailedReport() throws {
        let quakes = QuakeList.make(try P2PQuakeItem.decode(Fixture.data("p2pquake_history")))
        let amakusa = quakes[1]
        // 天草灘の地震: 各地の震度に関する情報(一番詳しい報)の内容を使う
        XCTAssertEqual(amakusa.reportType, "DetailScale")
        XCTAssertEqual(amakusa.reportedAt, QuakeList.parseTime("2026/09/19 21:10:56"))
        XCTAssertEqual(amakusa.depth, 10)
        XCTAssertEqual(amakusa.latitude, 32.3)
        XCTAssertEqual(amakusa.longitude, 129.7)
        XCTAssertEqual(amakusa.domesticTsunami, "None")
        // 観測点は詳しい報のものだけ(震度速報の地域名は混ぜない)。都道府県ごとの最大震度は、全部の報から作る
        XCTAssertEqual(amakusa.points?.count, 6)
        XCTAssertTrue(amakusa.points?.allSatisfy { $0.prefecture == "熊本県" } ?? false)
        XCTAssertEqual(amakusa.prefectureScales["鹿児島県"], 30)
        // 報の間で震源やマグニチュードは変わっていない
        XCTAssertEqual(amakusa.wasRevised, false)
        XCTAssertEqual(QuakeList.depthText(amakusa.depth), "深さ10km")
        XCTAssertEqual(QuakeList.depthText(0), "ごく浅い")
        XCTAssertEqual(QuakeList.depthText(nil), "深さ不明")
    }

    func testCombinePrefersDetailedAndNewestAndFlagsRevision() throws {
        let time = try XCTUnwrap(QuakeList.parseTime("2026/09/20 10:00:00"))
        let prompt = try item(type: "ScalePrompt", issued: "2026/09/20 10:02:00", name: "", magnitude: -1, depth: -1, maxScale: 40, tsunami: "Checking",
                              points: #"[{"pref":"千葉県","addr":"千葉県北東部","isArea":true,"scale":40}]"#)
        let destination = try item(type: "Destination", issued: "2026/09/20 10:04:00", name: "千葉県東方沖", magnitude: 5.2, depth: 30, maxScale: -1)
        let detail = try item(type: "DetailScale", issued: "2026/09/20 10:08:00", name: "千葉県東方沖", magnitude: 5.4, depth: 30, maxScale: 40,
                              points: #"[{"pref":"千葉県","addr":"銚子市川口町","isArea":false,"scale":40},{"pref":"茨城県","addr":"神栖市溝口","isArea":false,"scale":30}]"#)
        // 震度速報だけのとき: 震源は未発表、津波は調査中
        let early = QuakeList.combine([prompt], time: time)
        XCTAssertNil(early.place)
        XCTAssertNil(early.latitude)
        XCTAssertEqual(early.maxScale, 40)
        XCTAssertEqual(early.domesticTsunami, "Checking")
        XCTAssertEqual(early.wasRevised, false)
        // 3つの報がそろったとき: 一番詳しい報(M5.4)の内容。途中でマグニチュードが変わったので「更新あり」
        let full = QuakeList.combine([prompt, destination, detail], time: time)
        XCTAssertEqual(full.magnitude, 5.4)
        XCTAssertEqual(full.domesticTsunami, "None")
        XCTAssertEqual(full.points?.map(\.name), ["銚子市川口町", "神栖市溝口"])
        XCTAssertEqual(full.wasRevised, true)
        XCTAssertEqual(full.reportedAt, QuakeList.parseTime("2026/09/20 10:08:00"))
        // 同じ種類の報が複数あれば、新しいほう。訂正の報も「更新あり」
        let corrected = try item(type: "DetailScale", issued: "2026/09/20 10:30:00", name: "千葉県東方沖", magnitude: 5.4, depth: 40, maxScale: 40, correct: "ScaleAndDestination")
        XCTAssertEqual(QuakeList.combine([detail, corrected], time: time).depth, 40)
        XCTAssertEqual(QuakeList.combine([corrected], time: time).wasRevised, true)
        // 前回の取得から内容が変わったときも「更新あり」。前回の観測点は、新しい報にない場合だけ引き継ぐ
        let before = QuakeList.combine([destination], time: time)
        let merged = QuakeList.merge(old: [before], new: [QuakeList.combine([detail], time: time)], now: time)
        XCTAssertEqual(merged.first?.wasRevised, true)
        XCTAssertEqual(merged.first?.magnitude, 5.4)
        let kept = QuakeList.merge(old: [full], new: [early], now: time)
        XCTAssertEqual(kept.first?.place, "千葉県東方沖")
        XCTAssertEqual(kept.first?.points?.count, 2)
    }

    func testOldCacheWithoutDetailFieldsStillDecodes() throws {
        let json = #"{"quakes":[{"time":1790000000,"place":"茨城県沖","magnitude":3.9,"maxScale":10,"prefectureScales":{"茨城県":10}}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(QuakeSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.quakes.first?.place, "茨城県沖")
        XCTAssertNil(snapshot.quakes.first?.points)
        XCTAssertNil(snapshot.quakes.first?.wasRevised)
    }

    func testIntensityTree() {
        let points = [
            QuakePoint(prefecture: "熊本県", name: "天草市牛深町", scale: 30),
            QuakePoint(prefecture: "熊本県", name: "天草市天草町", scale: 30),
            QuakePoint(prefecture: "鹿児島県", name: "長島町鷹巣", scale: 30),
            QuakePoint(prefecture: "長崎県", name: "南島原市口之津町", scale: 20),
            QuakePoint(prefecture: "熊本県", name: "天草市新和町", scale: 20),
            QuakePoint(prefecture: "熊本県", name: "天草市河浦町", scale: 20),
            QuakePoint(prefecture: "福岡県", name: "大牟田市昭和町", scale: 10),
        ]
        let groups = QuakeIntensityGroup.make(points, homePrefecture: "長崎県")
        // 震度の大きい順
        XCTAssertEqual(groups.map(\.scale), [30, 20, 10])
        XCTAssertEqual(groups[0].pointCount, 3)
        // 同じ震度の中では、観測点の多い都道府県が先
        XCTAssertEqual(groups[0].prefectures.map(\.name), ["熊本県", "鹿児島県"])
        XCTAssertEqual(groups[0].prefectures[0].points, ["天草市天草町", "天草市牛深町"])
        // 現在地の都道府県は、観測点が少なくても先頭に出し、強調する
        XCTAssertEqual(groups[1].prefectures.map(\.name), ["長崎県", "熊本県"])
        XCTAssertTrue(groups[1].prefectures[0].isHome)
        XCTAssertFalse(groups[1].prefectures[1].isHome)
        XCTAssertTrue(QuakeIntensityGroup.make([], homePrefecture: nil).isEmpty)
    }

    func testDistanceAndDirectionToEpicenter() {
        var quake = Quake(time: Date(), place: "天草灘", magnitude: 4.4, maxScale: 30, prefectureScales: [:])
        quake.latitude = 32.3
        quake.longitude = 129.7
        // 東京駅から天草灘: 方位角は約251度(8方位では西)、約1001km
        XCTAssertEqual(QuakeRelation.text(quake: quake, latitude: 35.681236, longitude: 139.767125), "震源は西 1001km")
        // 震源か現在地が分からなければ出さない
        XCTAssertNil(QuakeRelation.text(quake: quake, latitude: nil, longitude: 139))
        quake.latitude = nil
        XCTAssertNil(QuakeRelation.text(quake: quake, latitude: 35, longitude: 139))
        XCTAssertEqual(QuakeRelation.distanceText(400), "1km未満")
        XCTAssertEqual(QuakeRelation.distanceText(120_400), "120km")
    }

    func testTsunamiTexts() {
        XCTAssertEqual(QuakeTsunami.domestic("None").text, "この地震による津波の心配はありません")
        XCTAssertEqual(QuakeTsunami.domestic("None").tone, .none)
        XCTAssertEqual(QuakeTsunami.domestic("Checking").tone, .caution)
        XCTAssertEqual(QuakeTsunami.domestic("NonEffective").tone, .caution)
        XCTAssertEqual(QuakeTsunami.domestic("Watch").tone, .warning)
        XCTAssertEqual(QuakeTsunami.domestic("Warning").tone, .warning)
        XCTAssertEqual(QuakeTsunami.domestic("Unknown").tone, .unknown)
        XCTAssertEqual(QuakeTsunami.domestic(nil).tone, .unknown)
        // 海外の津波は、情報があるときだけ表示する
        XCTAssertNil(QuakeTsunami.foreign("None"))
        XCTAssertNil(QuakeTsunami.foreign("Unknown"))
        XCTAssertNil(QuakeTsunami.foreign(nil))
        XCTAssertEqual(QuakeTsunami.foreign("WarningPacific")?.tone, .warning)
        XCTAssertEqual(QuakeTsunami.foreign("NonEffectiveNearby")?.tone, .caution)
        XCTAssertEqual(QuakeList.reportName("ScalePrompt"), "震度速報")
    }
}

import XCTest
@testable import SmartDashboard

/// 事業者の自動検出(検出の手順、使えるデータの判定、予備の定義との合わせ方)
final class OperatorDiscoveryTests: XCTestCase {
    private struct Responses {
        var operators: [ODPTOperator]
        var railways: [ODPTRailway]
        var information: [ODPTTrainInformation]
        var trains: [ODPTTrain]
        var stations: [ODPTStation]
        var stationTimetables: [ODPTStationTimetable]
        var trainTimetables: [ODPTTrainTimetable]
    }

    /// 1つのフィクスチャに、7種類の応答をまとめてある
    private func responses() throws -> Responses {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data("odpt_discovery")) as? [String: Any])
        func part<T: Decodable>(_ key: String, _ type: T.Type) throws -> [T] {
            let list = try XCTUnwrap(object[key] as? [Any], "\(key) がありません")
            return try ODPTClient.decode([T].self, from: JSONSerialization.data(withJSONObject: list))
        }
        return try Responses(
            operators: part("operators", ODPTOperator.self), railways: part("railways", ODPTRailway.self),
            information: part("information", ODPTTrainInformation.self), trains: part("trains", ODPTTrain.self),
            stations: part("stations", ODPTStation.self), stationTimetables: part("stationTimetables", ODPTStationTimetable.self),
            trainTimetables: part("trainTimetables", ODPTTrainTimetable.self))
    }

    /// 2026-09-28(月)の日本時間
    private func date(_ hour: Int, _ minute: Int) -> Date {
        JapaneseHolidays.calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: hour, minute: minute))!
    }

    private func evaluate(_ r: Responses, trains: [ODPTTrain]? = nil, at now: Date) -> OperatorDiscoveryResult {
        let candidates = OperatorDetection.candidates(r.operators)
        let railways = r.railways.filter { candidates.ids.contains($0.operatorID) }
        return OperatorDetection.evaluate(
            endpoint: .authenticated, operators: r.operators, excluded: candidates.excluded, railways: railways,
            information: r.information, trains: trains ?? r.trains, stations: r.stations, trainTimetables: r.trainTimetables,
            now: now, requestCount: 7, duration: 1.5)
    }

    func testDecodeFixture() throws {
        let r = try responses()
        XCTAssertEqual(r.operators.first { $0.sameAs == "odpt.Operator:MIR" }?.name, "首都圏新都市鉄道")
        let metro = try XCTUnwrap(r.stations.first { $0.sameAs == "odpt.Station:TokyoMetro.Marunouchi.Shinjuku" })
        XCTAssertEqual(metro.stationTimetables?.count, 4)
        XCTAssertEqual(metro.connectingStation, ["odpt.Station:Toei.Oedo.ShinjukuNishiguchi"])
        let train = try XCTUnwrap(r.trains.first)
        XCTAssertEqual(train.sameAs, "odpt.Train:Toei.Asakusa.1878K")
        XCTAssertEqual(train.operatorID, "odpt.Operator:Toei")
        // 列車ごとの時刻表を提供していない事業者(ゆりかもめ)の駅時刻表には、列車のIDがない
        let yurikamome = try XCTUnwrap(r.stationTimetables.first { $0.sameAs.contains("Yurikamome") })
        XCTAssertTrue(yurikamome.objects.allSatisfy { $0.train == nil })
        XCTAssertNotNil(r.stationTimetables.first { $0.sameAs.contains("MIR") }?.objects.first?.train)
        XCTAssertEqual(r.trainTimetables.first { $0.sameAs.contains("MIR") }?.operatorID, "odpt.Operator:MIR")
    }

    func testCandidatesExcludeChallengeOnlyOperators() throws {
        let candidates = OperatorDetection.candidates(try responses().operators)
        XCTAssertFalse(candidates.ids.contains("odpt.Operator:Tobu"))
        XCTAssertTrue(candidates.ids.contains("odpt.Operator:TokyoMetro"))
        XCTAssertEqual(candidates.excluded.map(\.id), ["odpt.Operator:Tobu"])
        XCTAssertEqual(candidates.excluded.first?.name, "東武鉄道")
        XCTAssertEqual(candidates.excluded.first?.reason, OperatorCatalog.challengeOnlyReason)
        // チャレンジ限定の事業者(2026-09-28に ckan.odpt.org で確認)
        for id in ["JR-East", "Keio", "Odakyu", "Keikyu", "Sotetsu", "Tobu", "Seibu", "Tokyu"] {
            XCTAssertNotNil(OperatorCatalog.challengeOnly["odpt.Operator:" + id], id)
        }
        XCTAssertNil(OperatorCatalog.challengeOnly["odpt.Operator:Toei"])
    }

    func testProbeRequests() throws {
        let r = try responses()
        // 路線ごとに最初の駅だけ(駅の順がない北総線は対象外)
        XCTAssertEqual(OperatorDetection.probeStationIDs(r.railways), [
            "odpt.Station:MIR.TsukubaExpress.Asakusa", "odpt.Station:Toei.Arakawa.Minowabashi",
            "odpt.Station:Toei.Asakusa.NishiMagome", "odpt.Station:TokyoMetro.Marunouchi.Shinjuku",
            "odpt.Station:Yurikamome.Yurikamome.Aomi",
        ])
        // 走っている列車がある事業者(都営)は、駅時刻表を取らない。ほかは事業者ごとに平日の1つ。
        XCTAssertEqual(OperatorDetection.probeStationTimetableIDs(stations: r.stations, operatorsWithTrains: ["odpt.Operator:Toei"]), [
            "odpt.StationTimetable:MIR.TsukubaExpress.Asakusa.Inbound.Weekday",
            "odpt.StationTimetable:TokyoMetro.Marunouchi.Shinjuku.TokyoMetro.Ogikubo.Weekday",
            "odpt.StationTimetable:Yurikamome.Yurikamome.Aomi.Inbound.Weekday",
        ])
        // 列車時刻表の確認: 走っている列車と、駅時刻表の真ん中あたりの列車(事業者ごとに2本まで)
        XCTAssertEqual(OperatorDetection.probeTrainIDs(trains: r.trains, stationTimetables: r.stationTimetables), [
            "odpt.Train:MIR.TsukubaExpress.4015", "odpt.Train:MIR.TsukubaExpress.5239",
            "odpt.Train:Toei.Arakawa.1234", "odpt.Train:Toei.Asakusa.1878K",
        ])
    }

    func testEvaluateInDaytime() throws {
        let result = evaluate(try responses(), at: date(18, 30))
        // 上書きの定義にある事業者が先(表示名とエンドポイントも上書き)
        XCTAssertEqual(result.operators.prefix(2).map(\.id), ["odpt.Operator:Toei", "odpt.Operator:TokyoMetro"])
        XCTAssertEqual(Set(result.operators.map(\.id)),
                       ["odpt.Operator:Toei", "odpt.Operator:TokyoMetro", "odpt.Operator:MIR", "odpt.Operator:Yurikamome"])
        let toei = try XCTUnwrap(result.operators.first)
        XCTAssertEqual(toei.name, "都営(東京都交通局)")
        XCTAssertEqual(toei.endpoint, .publicAPI)
        XCTAssertEqual(result.operators[1].endpoint, .authenticated)

        func caps(_ railway: String) throws -> ODPTCapabilities {
            try XCTUnwrap(result.operators.flatMap(\.railways).first { $0.id == railway }?.capabilities, railway)
        }
        let asakusa = try caps("odpt.Railway:Toei.Asakusa")
        XCTAssertEqual(asakusa, ODPTCapabilities(trainInformation: true, trainTimetable: true, stationTimetable: true,
                                                 stationLocation: true, delay: true))
        // 荒川線: 列車はあるが遅れの項目がない。運行情報はこのフィクスチャにない。
        let arakawa = try caps("odpt.Railway:Toei.Arakawa")
        XCTAssertEqual(arakawa.delay, false)
        XCTAssertFalse(arakawa.trainInformation)
        XCTAssertFalse(arakawa.stationLocation)
        // 東京メトロ: 運行情報・時刻表・駅はあるが、odpt:Train がない(ほかの事業者の列車は走っている時間なので「なし」)
        XCTAssertEqual(try caps("odpt.Railway:TokyoMetro.Marunouchi"),
                       ODPTCapabilities(trainInformation: true, trainTimetable: true, stationTimetable: true, stationLocation: true, delay: false))
        XCTAssertEqual(try caps("odpt.Railway:MIR.TsukubaExpress").labels, ["運行情報", "時刻表", "地図"])
        // ゆりかもめ: 駅時刻表と駅の位置だけ
        let yurikamome = try caps("odpt.Railway:Yurikamome.Yurikamome")
        XCTAssertEqual(yurikamome, ODPTCapabilities(trainInformation: false, trainTimetable: false, stationTimetable: true,
                                                    stationLocation: true, delay: false))
        XCTAssertTrue(yurikamome.isUsable)

        // 除外: チャレンジ限定(東武)と、使えるデータがない(北総)。路線のないバスは一覧に出さない。
        XCTAssertEqual(Set(result.excluded.map(\.id)), ["odpt.Operator:Tobu", "odpt.Operator:Hokuso"])
        XCTAssertEqual(result.excluded.first { $0.id == "odpt.Operator:Hokuso" }?.reason, "運行情報・時刻表・駅の位置が提供されていません")
        XCTAssertNil(result.operators.first { $0.id == "odpt.Operator:KeioBus" })
        // 路線の応答は、使う事業者の分だけ残す(登録の画面で取り直さない)
        XCTAssertEqual(result.railwayData.count, 5)
        XCTAssertNil(result.railwayData.first { $0.operatorID == "odpt.Operator:Hokuso" })
        XCTAssertEqual(result.railwayCount, 5)
        XCTAssertEqual(result.operators.first { $0.id == "odpt.Operator:TokyoMetro" }?.railways.first?.colorHex, "#F62E36")
        XCTAssertFalse(result.isExpired(now: date(18, 30).addingTimeInterval(29 * 86400)))
        XCTAssertTrue(result.isExpired(now: date(18, 30).addingTimeInterval(31 * 86400)))
    }

    func testDelayIsUnknownAtNight() throws {
        let r = try responses()
        // 深夜に走っている列車が1本もないときは、遅れが取れるかは未確認
        let night = evaluate(r, trains: [], at: date(2, 0))
        let all = night.operators.flatMap(\.railways)
        XCTAssertTrue(all.allSatisfy { $0.capabilities.delay == nil })
        // 昼でも、どの事業者の列車もないとき(取得の不具合など)は未確認
        let empty = evaluate(r, trains: [], at: date(12, 0))
        XCTAssertTrue(empty.operators.flatMap(\.railways).allSatisfy { $0.capabilities.delay == nil })
        // 深夜でも、走っている列車に遅れの項目があれば「あり」
        let late = evaluate(r, at: date(0, 30))
        XCTAssertEqual(late.operators.flatMap(\.railways).first { $0.id == "odpt.Railway:Toei.Asakusa" }?.capabilities.delay, true)
        XCTAssertNil(late.operators.flatMap(\.railways).first { $0.id == "odpt.Railway:TokyoMetro.Marunouchi" }?.capabilities.delay)
        // 遅れが分からない路線にだけ、遅れの取得を試す
        XCTAssertEqual(ODPTCapabilities(delay: nil).labels, [])
    }

    func testCapabilityLabelsAndUnion() {
        let a = ODPTCapabilities(trainInformation: true, trainTimetable: false, stationTimetable: false, stationLocation: true, delay: false)
        let b = ODPTCapabilities(trainInformation: false, trainTimetable: false, stationTimetable: true, stationLocation: false, delay: nil)
        XCTAssertEqual(a.labels, ["運行情報", "地図"])
        XCTAssertEqual(b.labels, ["時刻表"])
        XCTAssertEqual(ODPTCapabilities.union([a, b]).labels, ["運行情報", "時刻表", "地図"])
        XCTAssertEqual(ODPTCapabilities.union([a, b]).delay, false)
        XCTAssertEqual(ODPTCapabilities.union([b, ODPTCapabilities(delay: true)]).delay, true)
        XCTAssertNil(ODPTCapabilities.union([b]).delay)
        XCTAssertFalse(ODPTCapabilities(stationLocation: true).isUsable)
        XCTAssertEqual(ODPTCapabilities.assumed.labels, ["運行情報", "時刻表", "地図"])
    }

    func testMergeWithFallback() throws {
        // 検出の前: トークンがなければ都営だけ、あれば東京メトロの予備も
        XCTAssertEqual(OperatorDirectory.merge(result: nil, hasToken: false).map(\.id), ["odpt.Operator:Toei"])
        XCTAssertEqual(OperatorDirectory.merge(result: nil, hasToken: true).map(\.id), ["odpt.Operator:Toei", "odpt.Operator:TokyoMetro"])
        XCTAssertTrue(OperatorDirectory.merge(result: nil, hasToken: true).allSatisfy(\.isFallback))

        let result = evaluate(try responses(), at: date(18, 30))
        let merged = OperatorDirectory.merge(result: result, hasToken: true)
        XCTAssertEqual(merged.count, 4)
        XCTAssertTrue(merged.allSatisfy { !$0.isFallback })
        XCTAssertEqual(OperatorDirectory.capabilities(ofRailway: "odpt.Railway:Yurikamome.Yurikamome", in: merged)?.trainTimetable, false)
        XCTAssertNil(OperatorDirectory.capabilities(ofRailway: "odpt.Railway:Unknown.X", in: merged))

        // トークンが無効で、公開エンドポイントだけで検出したとき: 都営は検出の結果、東京メトロはトークンがあるので予備
        var publicOnly = result
        publicOnly.endpoint = .publicAPI
        publicOnly.operators = result.operators.filter { $0.id == "odpt.Operator:Toei" }
        let fallback = OperatorDirectory.merge(result: publicOnly, hasToken: true)
        XCTAssertEqual(fallback.map(\.id), ["odpt.Operator:Toei", "odpt.Operator:TokyoMetro"])
        XCTAssertEqual(fallback.map(\.isFallback), [false, true])
        XCTAssertEqual(OperatorDirectory.merge(result: publicOnly, hasToken: false).map(\.id), ["odpt.Operator:Toei"])

        // 一覧にない事業者(登録が残っているなど)も引ける。トークンが必要な事業者として扱う。
        let unknown = OperatorDirectory.resolve("odpt.Operator:TWR", in: merged)
        XCTAssertEqual(unknown.endpoint, .authenticated)
        XCTAssertEqual(unknown.name, "TWR")
        XCTAssertTrue(unknown.isFallback)
        XCTAssertEqual(OperatorDirectory.resolve("odpt.Operator:Toei", in: []).endpoint, .publicAPI)
    }

    func testOperatorWideInformation() throws {
        let line = RegisteredLine(operatorID: "odpt.Operator:X", railwayID: "odpt.Railway:X.A", railwayName: "A線")
        let wide = ODPTTrainInformation(sameAs: "odpt.TrainInformation:X", date: nil, railway: nil, operatorID: "odpt.Operator:X",
                                        timeOfOrigin: nil, status: nil, text: nil)
        let data = Data(#"[{"owl:sameAs":"odpt.TrainInformation:X","odpt:operator":"odpt.Operator:X","odpt:trainInformationStatus":{"ja":"遅延"},"odpt:trainInformationText":{"ja":"信号故障の影響で遅れています"}}]"#.utf8)
        let decoded = try ODPTClient.decode([ODPTTrainInformation].self, from: data)
        XCTAssertNil(wide.railway)
        let items = TrainStore.makeItems(lines: [line], response: decoded)
        XCTAssertEqual(items.first?.status, .delay)
        XCTAssertEqual(items.first?.text, "信号故障の影響で遅れています")
    }

    func testOperatorIDFromODPTIDs() {
        XCTAssertEqual(ODPTID.operatorID(of: "odpt.Station:TokyoMetro.Marunouchi.Shinjuku"), "odpt.Operator:TokyoMetro")
        XCTAssertEqual(ODPTID.operatorID(of: "odpt.Train:MIR.TsukubaExpress.3005"), "odpt.Operator:MIR")
        XCTAssertEqual(ODPTID.operatorID(of: "odpt.StationTimetable:Yurikamome.Yurikamome.Aomi.Inbound.Weekday"), "odpt.Operator:Yurikamome")
        XCTAssertEqual(ODPTID.operatorID(of: "odpt.Railway:JR-East.Yamanote"), "odpt.Operator:JR-East")
        XCTAssertNil(ODPTID.operatorID(of: "no-colon"))
    }
}

/// 事業者をまたぐ乗り換えと経路(odpt:connectingStation と、同じ名前で500m以内の規則)
final class CrossOperatorTransferTests: XCTestCase {
    private let shinjuku = GeoPoint(35.692452, 139.700548)

    private func station(_ id: String, _ name: String, _ railway: String, east: Double, north: Double = 0,
                         connecting: [String] = []) -> TransitStation {
        let point = GeoMath.offset(shinjuku, east: east, north: north)
        return TransitStation(id: id, name: name, railwayID: railway, latitude: point.latitude, longitude: point.longitude, connecting: connecting)
    }

    private let metro = "odpt.Railway:TokyoMetro.Marunouchi"
    private let oedo = "odpt.Railway:Toei.Oedo"
    private let tx = "odpt.Railway:MIR.TsukubaExpress"
    private let yurikamome = "odpt.Railway:Yurikamome.Yurikamome"

    private func directory() throws -> TransitDirectory {
        // 東京メトロの駅の応答(フィクスチャ)には、都営の新宿西口への乗り換えが書かれている(都営側には書かれていない)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data("odpt_discovery")) as? [String: Any])
        let stations = try ODPTClient.decode([ODPTStation].self, from: JSONSerialization.data(withJSONObject: object["stations"] as? [Any] ?? []))
        let metroShinjuku = try XCTUnwrap(stations.first { $0.sameAs == "odpt.Station:TokyoMetro.Marunouchi.Shinjuku" }.flatMap { TransitStation($0) })
        let list = [
            metroShinjuku,
            station("odpt.Station:TokyoMetro.Marunouchi.Nishishinjuku", "西新宿", metro, east: -800),
            station("odpt.Station:Toei.Oedo.ShinjukuNishiguchi", "新宿西口", oedo, east: -40, north: 240),
            station("odpt.Station:Toei.Oedo.Tochomae", "都庁前", oedo, east: -900, north: 300),
            // 乗り換えが書かれていない、事業者の違う同じ名前の駅(400m と 700m)
            station("odpt.Station:MIR.TsukubaExpress.Kita", "北", tx, east: 0, north: 3000),
            station("odpt.Station:Toei.Oedo.Kita", "北", oedo, east: 400, north: 3000),
            station("odpt.Station:MIR.TsukubaExpress.Minami", "南", tx, east: 0, north: -3000),
            station("odpt.Station:Toei.Oedo.Minami", "南", oedo, east: 700, north: -3000),
            // 列車ごとの時刻表がない路線の駅(経路には使わない)
            station("odpt.Station:Yurikamome.Yurikamome.Kita", "北", yurikamome, east: 100, north: 3000),
        ]
        return TransitDirectory(stations: list, railwayNames: [metro: "丸ノ内線", oedo: "大江戸線", tx: "つくばエクスプレス"])
    }

    func testConnectingStationAcrossOperators() throws {
        let d = try directory()
        // 片方(東京メトロ)にだけ書かれていても、両方向に使う
        XCTAssertEqual(d.transferTargets(from: "odpt.Station:TokyoMetro.Marunouchi.Shinjuku"), ["odpt.Station:Toei.Oedo.ShinjukuNishiguchi"])
        XCTAssertEqual(d.transferTargets(from: "odpt.Station:Toei.Oedo.ShinjukuNishiguchi"), ["odpt.Station:TokyoMetro.Marunouchi.Shinjuku"])
        // 243m 離れているので、150m を超えた分の歩く時間を足す
        let seconds = d.transferSeconds(from: "odpt.Station:TokyoMetro.Marunouchi.Shinjuku", to: "odpt.Station:Toei.Oedo.ShinjukuNishiguchi",
                                        transferMinutes: 5, walk: WalkSettings())
        XCTAssertEqual(seconds, 300 + (243.3 - 150) * 1.3 / (4.8 / 3.6), accuracy: 3)
    }

    func testSameNameWithin500mAcrossOperators() throws {
        let d = try directory()
        XCTAssertEqual(Set(d.transferTargets(from: "odpt.Station:MIR.TsukubaExpress.Kita")),
                       ["odpt.Station:Toei.Oedo.Kita", "odpt.Station:Yurikamome.Yurikamome.Kita"])
        XCTAssertTrue(d.transferTargets(from: "odpt.Station:MIR.TsukubaExpress.Minami").isEmpty)
        XCTAssertEqual(d.group(containing: "odpt.Station:Toei.Oedo.Kita")?.railwayIDs.count, 3)
    }

    func testRailwayGraphSkipsRailwaysWithoutTimetables() throws {
        let d = try directory()
        XCTAssertEqual(d.railwayGraph()[tx], [oedo, yurikamome])
        let allowed: Set<String> = [metro, oedo, tx]
        XCTAssertEqual(d.railwayGraph(allowed: allowed)[tx], [oedo])
        XCTAssertNil(d.railwayGraph(allowed: allowed)[yurikamome])
        XCTAssertEqual(d.railwaysOnShortestPaths(from: [metro], to: [tx], allowed: allowed), [metro, oedo, tx])
        XCTAssertTrue(d.railwaysOnShortestPaths(from: [yurikamome], to: [metro], allowed: allowed).isEmpty)
    }

    func testJourneyAcrossOperators() throws {
        let d = try directory()
        let calendar = JapaneseHolidays.calendar
        func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: hour, minute: minute, second: second))!
        }
        func train(_ number: String, _ stops: [(Int, Int?, Int?)]) -> LineSchedule.Train {
            LineSchedule.Train(number: number, calendar: "odpt.Calendar:Weekday", direction: "odpt.RailDirection:Up", trainType: "各停",
                               destination: "終点", stops: stops.map { LineSchedule.Stop(station: $0.0, arrival: $0.1, departure: $0.2) })
        }
        // 丸ノ内線: 西新宿 → 新宿(5分)、8:00から10分ごと。大江戸線: 新宿西口 → 都庁前(4分)、8:02から5分ごと。
        let marunouchi = LineSchedule(railwayID: metro, downloadedAt: Date(),
                                      stationIDs: ["odpt.Station:TokyoMetro.Marunouchi.Nishishinjuku", "odpt.Station:TokyoMetro.Marunouchi.Shinjuku"],
                                      trains: stride(from: 480, through: 540, by: 10).map { train("M\($0)", [(0, nil, $0), (1, $0 + 5, nil)]) })
        let oedoLine = LineSchedule(railwayID: oedo, downloadedAt: Date(),
                                    stationIDs: ["odpt.Station:Toei.Oedo.ShinjukuNishiguchi", "odpt.Station:Toei.Oedo.Tochomae"],
                                    trains: stride(from: 482, through: 560, by: 5).map { train("O\($0)", [(0, nil, $0), (1, $0 + 4, nil)]) })
        let start = at(7, 59)
        let trips = JourneyPlanner.trips(schedules: [marunouchi, oedoLine], from: start, horizon: 6 * 3600, resolver: DayTypeResolver())
        let walk = WalkSettings()
        let options = JourneyPlanner.search(
            trips: trips,
            query: JourneyQuery(origins: ["odpt.Station:TokyoMetro.Marunouchi.Nishishinjuku"], destinations: ["odpt.Station:Toei.Oedo.Tochomae"],
                                departure: start),
            sameStationTransfer: 300,
            transfers: { id in d.transferTargets(from: id).map { (stationID: $0, seconds: d.transferSeconds(from: id, to: $0, transferMinutes: 5, walk: walk)) } },
            stationName: { d.name(of: $0) }, railwayName: { d.railwayName(of: $0) })
        let journey = try XCTUnwrap(options.first?.journey)
        XCTAssertEqual(journey.transfers, 1)
        XCTAssertEqual(journey.legs.map(\.railwayID), [metro, oedo])
        XCTAssertEqual(journey.legs.map(\.railwayName), ["丸ノ内線", "大江戸線"])
        // 8:05 に新宿に着き、乗り換え(5分+歩く約91秒)で 8:11:31 以降 → 8:12 の大江戸線 → 8:16 に都庁前
        XCTAssertEqual(journey.legs[1].board.departure, at(8, 12))
        XCTAssertEqual(journey.arrival, at(8, 16))
        XCTAssertEqual(journey.waits.first?.stationName, "新宿")
        XCTAssertEqual(journey.waits.first?.nextStationName, "新宿西口")
    }
}

/// 線路の形の向き(N02 の駅だけで作った線は、ODPT の駅の順と逆向きのことがある)
final class TrackOrientationTests: XCTestCase {
    func testTrackIsOrientedToStationOrder() {
        let origin = GeoPoint(35.68, 139.76)
        let track = (0...10).map { GeoMath.offset(origin, east: Double($0) * 100, north: 0) }
        let stations: [(id: String, name: String, point: GeoPoint)] = [
            ("c", "C", GeoMath.offset(origin, east: 1000, north: 5)),
            ("b", "B", GeoMath.offset(origin, east: 500, north: 5)),
            ("a", "A", GeoMath.offset(origin, east: 0, north: 5)),
        ]
        XCTAssertEqual(RideLine.oriented(track, first: stations[0].point, last: stations[2].point), Array(track.reversed()))
        XCTAssertEqual(RideLine.oriented(track, first: stations[2].point, last: stations[0].point), track)
        let line = RideLine(railwayID: "r", name: "R", stations: stations, track: track)
        assertAlmostEqual(line.stations.map(\.along), [0, 500, 1000], accuracy: 1)
        XCTAssertTrue(line.stations.allSatisfy { $0.offset < 6 })
    }
}

private func assertAlmostEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}

/// ODPT の問い合わせの組み立て(カンマ区切りの上限、空の絞り込み、失敗したときの内容)
final class ODPTQueryTests: XCTestCase {
    /// 決まった応答を返し、問い合わせたURLを記録する
    private final class StubHTTP: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URL] = []
        let status: Int
        let body: String

        init(status: Int = 200, body: String = "[]") {
            self.status = status
            self.body = body
        }

        var urls: [URL] { lock.withLock { recorded } }

        func get(_ url: URL) async throws -> Data {
            let (data, status) = try await response(url)
            guard status == 200 else { throw HTTPError.badStatus(status) }
            return data
        }

        func response(_ url: URL) async throws -> (data: Data, status: Int) {
            lock.withLock { recorded.append(url) }
            return (Data(body.utf8), status)
        }
    }

    private func values(_ url: URL, _ key: String) -> [String] {
        let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }
        return item?.value?.split(separator: ",").map(String.init) ?? []
    }

    func testChunks() {
        let ids = (1...23).map { "id\($0)" }
        let chunks = ODPTQuery.chunks(ids)
        XCTAssertEqual(chunks.map(\.count), [10, 10, 3])
        XCTAssertEqual(chunks.flatMap { $0 }, ids)
        // 空の値と重複は送らない
        XCTAssertEqual(ODPTQuery.chunks(["a", "", "a", "b"]), [["a", "b"]])
        XCTAssertTrue(ODPTQuery.chunks([]).isEmpty)
        XCTAssertTrue(ODPTQuery.chunks([""]).isEmpty)
    }

    func testRequestsAreSplitByTenAndEmptyFiltersAreNotSent() async throws {
        let http = StubHTTP()
        let client = ODPTClient(http: http, tokenProvider: { "secret-token-for-test" })
        let ids = (1...23).map { "odpt.Station:X.Y.S\($0)" }
        _ = try await client.stations(ids: ids, endpoint: .authenticated)
        XCTAssertEqual(http.urls.count, 3)
        XCTAssertTrue(http.urls.allSatisfy { values($0, "owl:sameAs").count <= ODPTQuery.maxORValues })
        XCTAssertEqual(Set(http.urls.flatMap { values($0, "owl:sameAs") }), Set(ids))

        _ = try await client.trainInformation(operatorIDs: [], endpoint: .authenticated)
        _ = try await client.trains(operatorIDs: [""], endpoint: .authenticated)
        XCTAssertEqual(http.urls.count, 3)

        // 路線の一覧は、絞り込まずに1回で取る
        _ = try await client.railways(endpoint: .authenticated)
        let railway = try XCTUnwrap(http.urls.last)
        XCTAssertTrue(railway.path.hasSuffix("odpt:Railway"))
        XCTAssertEqual(URLComponents(url: railway, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["acl:consumerKey"])
    }

    func testTrainInformationFromSeveralRequestsIsMerged() async throws {
        let http = StubHTTP(body: #"[{"owl:sameAs":"odpt.TrainInformation:X.A","odpt:operator":"odpt.Operator:X","odpt:railway":"odpt.Railway:X.A"}]"#)
        let client = ODPTClient(http: http, tokenProvider: { nil })
        let op = TrainOperator(id: "odpt.Operator:Toei", name: "都営", endpoint: .publicAPI)
        let data = try await client.trainInformationData(op: op, railwayIDs: (1...12).map { "odpt.Railway:X.R\($0)" })
        XCTAssertEqual(http.urls.count, 2)
        XCTAssertEqual(try ODPTClient.decode([ODPTTrainInformation].self, from: data).count, 2)
    }

    func testFailureKeepsURLWithoutTokenAndBody() async throws {
        let http = StubHTTP(status: 400, body: "too many OR condition in odpt:operator")
        let client = ODPTClient(http: http, tokenProvider: { "secret-token-for-test" })
        do {
            _ = try await client.trainInformation(operatorIDs: ["odpt.Operator:A", "odpt.Operator:B"], endpoint: .authenticated)
            XCTFail("失敗するはず")
        } catch let error as ODPTError {
            guard case let .requestFailed(name, status, body, url) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "運行情報")
            XCTAssertEqual(status, 400)
            XCTAssertEqual(body, "too many OR condition in odpt:operator")
            XCTAssertEqual(url, "https://api.odpt.org/api/v4/odpt:TrainInformation?odpt:operator=odpt.Operator:A,odpt.Operator:B")
            XCTAssertFalse(url.contains("secret"))
            XCTAssertEqual(error.requestURL, url)
            XCTAssertTrue(error.localizedDescription.contains("HTTP 400"))
            XCTAssertTrue(error.localizedDescription.contains("too many OR condition"))
        }
        // 無効なトークン(403 Invalid acl:consumerKey.)は、トークンのエラーとして扱う
        let forbidden = ODPTClient(http: StubHTTP(status: 403, body: "Invalid acl:consumerKey."), tokenProvider: { "x" })
        do {
            _ = try await forbidden.operators(endpoint: .authenticated)
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error as? ODPTError, .unauthorized)
        }
    }

    @MainActor
    func testStoppedFailureMessage() {
        let failure = OperatorDiscoveryStore.Failure.stopped(stage: "路線の一覧", detail: "路線の一覧を取得できませんでした(HTTP 400)", url: "https://example")
        XCTAssertTrue(failure.message.hasPrefix("路線の一覧が取れなかったため、検出を中止しました"))
        XCTAssertEqual(failure.url, "https://example")
        XCTAssertNil(OperatorDiscoveryStore.Failure.invalidToken.url)
    }
}

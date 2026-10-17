import CoreGraphics
import XCTest
@testable import SmartDashboard

/// 線路の高さ(地面の標高と区間の種類)と、路線ごとの両数の表
final class TrackHeightTests: XCTestCase {
    private let origin = GeoPoint(35.68, 139.76)

    private func point(east: Double, north: Double) -> GeoPoint {
        GeoMath.offset(origin, east: east, north: north)
    }

    // MARK: - 線路に沿った高さ

    func testProfileSampleInterpolatesAndFallsBack() {
        let profile = TrackProfile(step: 25, ground: [10, 20, nil, nil, 40, nil],
                                   runs: [.init(start: 0, section: .ground), .init(start: 2, section: .elevated), .init(start: 5, section: .underground)])
        // 前後の点から補間
        XCTAssertEqual(profile.sample(atAlong: 12.5).ground!, 15, accuracy: 0.001)
        XCTAssertEqual(profile.sample(atAlong: 0).section, .ground)
        // データのない点は、近くの点の値(手前を先に探す)
        XCTAssertEqual(profile.sample(atAlong: 50).ground, 20)
        XCTAssertEqual(profile.sample(atAlong: 50).section, .elevated)
        // 範囲の外は端の点
        XCTAssertEqual(profile.sample(atAlong: -100).ground, 10)
        XCTAssertEqual(profile.sample(atAlong: 10_000).ground, 40)
        XCTAssertEqual(profile.sample(atAlong: 10_000).section, .underground)
        // データがまったくない
        XCTAssertNil(TrackProfile(step: 25, ground: [nil, nil], runs: []).sample(atAlong: 10).ground)
        XCTAssertEqual(TrackProfile(step: 25, ground: [], runs: []).sample(atAlong: 10).section, .unknown)
    }

    func testHeightModelPerSection() {
        let ground = TrackHeightModel.height(ground: 20, section: .ground, elevated: 8, underground: 15)
        XCTAssertEqual(ground, TrackHeightModel.Height(altitude: 20, section: .ground, isEstimate: false))
        XCTAssertEqual(TrackHeightModel.height(ground: 20, section: .elevated, elevated: 8, underground: 15).altitude, 28)
        XCTAssertEqual(TrackHeightModel.height(ground: 20, section: .underground, elevated: 8, underground: 15).altitude, 5)
        // 区間の種類が分からなければ地面の高さで、目安
        let unknown = TrackHeightModel.height(ground: 20, section: .unknown, elevated: 8, underground: 15)
        XCTAssertEqual(unknown.altitude, 20)
        XCTAssertTrue(unknown.isEstimate)
        // 地面の標高がなければ高さは出さない(地面の高さに置く)
        let missing = TrackHeightModel.height(ground: nil, section: .elevated, elevated: 8, underground: 15)
        XCTAssertNil(missing.altitude)
        XCTAssertTrue(missing.isEstimate)
        XCTAssertEqual(missing.section, .elevated)
    }

    /// 線路の形が駅の順と逆向きに入っていても、高さは同じ場所の値を引く
    func testRideLineHeightWithReversedTrack() throws {
        let stations = [(id: "a", name: "A", point: point(east: 0, north: 0)), (id: "b", name: "B", point: point(east: 1000, north: 0))]
        // 線路の形は B → A の向き。高さのデータもこの向き(B側の0〜19番は高架、20番から地下。地面は B側から1mずつ高い)
        let track = stride(from: 1000.0, through: 0, by: -100).map { point(east: $0, north: 0) }
        let profile = TrackProfile(step: 25, ground: (0...40).map { Double($0) },
                                   runs: [.init(start: 0, section: .elevated), .init(start: 20, section: .underground)])
        let line = RideLine(railwayID: "r", name: "線", stations: stations, track: track, profile: profile)
        XCTAssertTrue(line.isReversed)
        let atA = line.trackHeight(atAlong: 0, elevated: 8, underground: 15)
        XCTAssertEqual(atA.section, .underground)
        XCTAssertEqual(atA.altitude!, 40 - 15, accuracy: 0.5)
        let atB = line.trackHeight(atAlong: line.path.length, elevated: 8, underground: 15)
        XCTAssertEqual(atB.section, .elevated)
        XCTAssertEqual(atB.altitude!, 0 + 8, accuracy: 0.5)
        // 高さのデータがない路線
        let plain = RideLine(railwayID: "r", name: "線", stations: stations)
        XCTAssertEqual(plain.trackHeight(atAlong: 100, elevated: 8, underground: 15),
                       TrackHeightModel.Height(altitude: nil, section: .unknown, isEstimate: true))
    }

    func testProfileDecoding() throws {
        let json = """
        {"source": "s", "fetched": "2026-09-28", "heightSource": "h", "heightFetched": "2026-10-18",
         "railways": {"r1": {"points": [[35.0, 139.0], [35.001, 139.001]],
                             "profile": {"step": 25, "ground": [123, null, -5], "kinds": [[0, "g"], [1, "e"], [2, "x"]]}},
                      "r2": {"points": [[35.0, 139.0], [35.001, 139.001]]}}}
        """
        let catalog = try RailwayTrackCatalog(data: Data(json.utf8))
        XCTAssertEqual(catalog.heightSource, "h")
        XCTAssertEqual(catalog.heightFetched, "2026-10-18")
        let profile = try XCTUnwrap(catalog.profile(for: "r1"))
        XCTAssertEqual(profile.step, 25)
        XCTAssertEqual(profile.ground, [12.3, nil, -0.5])
        // 知らない種類は「不明」
        XCTAssertEqual(profile.runs.map(\.section), [.ground, .elevated, .unknown])
        XCTAssertNil(catalog.profile(for: "r2"))
    }

    func testBundledProfiles() throws {
        let catalog = RailwayTrackCatalog.bundled
        XCTAssertFalse(catalog.heightSource.isEmpty)
        XCTAssertFalse(catalog.heightFetched.isEmpty)
        // 同梱したすべての路線に高さのデータがある
        for id in catalog.tracks.keys {
            let profile = try XCTUnwrap(catalog.profile(for: id), id)
            let length = GeoPath(try XCTUnwrap(catalog.track(for: id))).length
            XCTAssertEqual(Double(profile.ground.count - 1) * profile.step, length, accuracy: max(profile.step * 2, length * 0.005), id)
        }
        // 大江戸線はほとんど地下、日暮里・舎人ライナーはすべて高架
        let oedo = try XCTUnwrap(catalog.profile(for: "odpt.Railway:Toei.Oedo"))
        XCTAssertEqual(oedo.sample(atAlong: 10_000).section, .underground)
        let toneri = try XCTUnwrap(catalog.profile(for: "odpt.Railway:Toei.NipporiToneri"))
        XCTAssertEqual(toneri.sample(atAlong: 5_000).section, .elevated)
        // 東京の地面の標高は、だいたい −5〜200m
        for ground in oedo.ground.compactMap({ $0 }) {
            XCTAssertTrue((-5...200).contains(ground), "\(ground)")
        }
    }

    // MARK: - カメラ表示の高さ

    func testRendererHeights() {
        let heights = ScopeTrainRenderer.Heights(observerAltitude: 30, handHeight: 1.5, elevated: 8, underground: 15)
        // 線路の高さ − 目の高さ
        XCTAssertEqual(heights.base(TrackHeightModel.Height(altitude: 38, section: .elevated, isEstimate: false)), 8)
        XCTAssertEqual(heights.base(TrackHeightModel.Height(altitude: 10, section: .underground, isEstimate: false)), -20)
        // 線路の高さが分からなければ地面(手の高さだけ下)
        XCTAssertEqual(heights.base(TrackHeightModel.Height(altitude: nil, section: .unknown, isEstimate: true)), -1.5)
        // 自分の高さが分からなくても地面
        let noObserver = ScopeTrainRenderer.Heights(observerAltitude: nil, handHeight: 1.5, elevated: 8, underground: 15)
        XCTAssertEqual(noObserver.base(TrackHeightModel.Height(altitude: 38, section: .elevated, isEstimate: false)), -1.5)
    }

    func testUndergroundDrawsAsOutline() {
        XCTAssertTrue(ScopeTrainRenderer.drawsAsOutline(TrackHeightModel.Height(altitude: 5, section: .underground, isEstimate: false)))
        // 地面の標高が分からなくても、地下と分かっていれば輪郭線
        XCTAssertTrue(ScopeTrainRenderer.drawsAsOutline(TrackHeightModel.Height(altitude: nil, section: .underground, isEstimate: true)))
        XCTAssertFalse(ScopeTrainRenderer.drawsAsOutline(TrackHeightModel.Height(altitude: 28, section: .elevated, isEstimate: false)))
        XCTAssertFalse(ScopeTrainRenderer.drawsAsOutline(TrackHeightModel.Height(altitude: 20, section: .ground, isEstimate: false)))
        XCTAssertFalse(ScopeTrainRenderer.drawsAsOutline(TrackHeightModel.Height(altitude: 20, section: .unknown, isEstimate: true)))
    }

    /// 位置のデバッグの間は、近くの線路の地面の標高を自分の高さにする
    func testTrackGroundAltitudeForVirtualPosition() {
        let stations = [(id: "a", name: "A", point: point(east: 0, north: 0)), (id: "b", name: "B", point: point(east: 1000, north: 0))]
        let track = stride(from: 0.0, through: 1000, by: 100).map { point(east: $0, north: 0) }
        let profile = TrackProfile(step: 25, ground: Array(repeating: 12, count: 41), runs: [.init(start: 0, section: .underground)])
        let line = RideLine(railwayID: "r", name: "線", stations: stations, track: track, profile: profile)
        XCTAssertEqual(ScopeTrainFeed.trackGroundAltitude(near: point(east: 500, north: 100), rides: [line], handHeight: 1.5)!, 13.5, accuracy: 0.01)
        // 300mより離れていれば分からない
        XCTAssertNil(ScopeTrainFeed.trackGroundAltitude(near: point(east: 500, north: 400), rides: [line], handHeight: 1.5))
    }

    // MARK: - 両数

    private func schedule(_ trains: [LineSchedule.Train]) -> LineSchedule {
        LineSchedule(railwayID: "odpt.Railway:TokyoMetro.Chiyoda", downloadedAt: Date(timeIntervalSince1970: 0),
                     stationIDs: ["odpt.Station:TokyoMetro.Chiyoda.KitaAyase", "odpt.Station:TokyoMetro.Chiyoda.Ayase",
                                  "odpt.Station:TokyoMetro.Chiyoda.Kitasenju"],
                     trains: trains)
    }

    private func train(_ number: String, stations: [Int], type: String = "各停", destination: String = "綾瀬", cars: Int? = nil) -> LineSchedule.Train {
        LineSchedule.Train(number: number, calendar: "odpt.Calendar:Weekday", direction: "d", trainType: type, destination: destination,
                           stops: stations.enumerated().map { LineSchedule.Stop(station: $0.element, arrival: 300 + $0.offset * 3, departure: nil) },
                           cars: cars)
    }

    func testCarRules() {
        let table = schedule([])
        let shuttle = train("1", stations: [0, 1])
        let through = train("2", stations: [0, 1, 2], destination: "北千住")
        let rule = TrainCarCatalog.Rule(cars: 3, stopsWithin: ["odpt.Station:TokyoMetro.Chiyoda.KitaAyase", "odpt.Station:TokyoMetro.Chiyoda.Ayase"])
        XCTAssertTrue(rule.matches(shuttle, stationIDs: table.stationIDs))
        XCTAssertFalse(rule.matches(through, stationIDs: table.stationIDs))
        // 列車番号の末尾、種別、行先(書いた条件をすべて満たすもの)
        let suffix = TrainCarCatalog.Rule(cars: 8, numberSuffixes: ["K", "G"])
        XCTAssertTrue(suffix.matches(train("1234K", stations: [0, 1]), stationIDs: table.stationIDs))
        XCTAssertFalse(suffix.matches(train("1234T", stations: [0, 1]), stationIDs: table.stationIDs))
        let typed = TrainCarCatalog.Rule(cars: 10, trainTypes: ["急行"], destinations: ["北千住"])
        XCTAssertTrue(typed.matches(train("3", stations: [0, 2], type: "急行", destination: "北千住"), stationIDs: table.stationIDs))
        XCTAssertFalse(typed.matches(train("3", stations: [0, 2], type: "急行", destination: "綾瀬"), stationIDs: table.stationIDs))
        XCTAssertFalse(typed.matches(train("3", stations: [0, 2], type: "各停", destination: "北千住"), stationIDs: table.stationIDs))
    }

    func testResolverPriority() {
        let shuttle = train("1", stations: [0, 1])
        let through = train("2", stations: [0, 1, 2])
        let table = schedule([shuttle, through])
        let entry = TrainCarCatalog.Entry(cars: 10, mixed: false, rules: [
            TrainCarCatalog.Rule(cars: 3, stopsWithin: ["odpt.Station:TokyoMetro.Chiyoda.KitaAyase", "odpt.Station:TokyoMetro.Chiyoda.Ayase"])
        ], note: "", sources: [])
        let context = TrainCarResolver.Context(entry: entry, override: nil, kindDefault: 6)
        // 規則 → 表の代表の両数
        XCTAssertEqual(TrainCarResolver.cars(for: shuttle, schedule: table, context: context), .init(cars: 3, isEstimate: false))
        XCTAssertEqual(TrainCarResolver.cars(for: through, schedule: table, context: context), .init(cars: 10, isEstimate: false))
        // 時刻表に列車が見つからなければ代表の両数
        XCTAssertEqual(TrainCarResolver.cars(for: nil, schedule: table, context: context), .init(cars: 10, isEstimate: false))
        // データの両数が最優先
        XCTAssertEqual(TrainCarResolver.cars(for: train("3", stations: [0, 1], cars: 4), schedule: table, context: context),
                       .init(cars: 4, isEstimate: false))
        // 設定の上書きは、規則より優先
        let overridden = TrainCarResolver.Context(entry: entry, override: 8, kindDefault: 6)
        XCTAssertEqual(TrainCarResolver.cars(for: shuttle, schedule: table, context: overridden), .init(cars: 8, isEstimate: false))
        // 混在する路線、公式で未確認の路線は目安
        var mixed = entry
        mixed.mixed = true
        XCTAssertEqual(TrainCarResolver.cars(for: through, schedule: table, context: .init(entry: mixed, override: nil, kindDefault: 6)),
                       .init(cars: 10, isEstimate: true))
        var unverified = entry
        unverified.verified = false
        XCTAssertTrue(TrainCarResolver.cars(for: through, schedule: table, context: .init(entry: unverified, override: nil, kindDefault: 6)).isEstimate)
        // 表にない路線は、種類ごとの目安
        XCTAssertEqual(TrainCarResolver.cars(for: through, schedule: table, context: .init(entry: nil, override: nil, kindDefault: 6)),
                       .init(cars: 6, isEstimate: true))
    }

    func testCatalogDecoding() throws {
        let json = """
        {"fetched": "2026-10-18", "railways": {
          "a": {"name": "A線", "cars": 10, "rules": [{"cars": 3, "stopsWithin": ["s1", "s2"], "note": "折り返し"}],
                "note": "n", "sources": [{"url": "https://example.com/a", "checked": "2026-10-18"}]},
          "b": {"cars": 8, "mixed": true, "verified": false},
          "c": {"cars": 0}}}
        """
        let catalog = try TrainCarCatalog(data: Data(json.utf8))
        XCTAssertEqual(catalog.fetched, "2026-10-18")
        let a = try XCTUnwrap(catalog.entry(for: "a"))
        XCTAssertEqual(a.name, "A線")
        XCTAssertEqual(a.rules.first?.stopsWithin, ["s1", "s2"])
        XCTAssertEqual(a.rules.first?.note, "折り返し")
        XCTAssertFalse(a.mixed)
        XCTAssertTrue(a.verified)
        XCTAssertEqual(a.sources.first?.url, "https://example.com/a")
        let b = try XCTUnwrap(catalog.entry(for: "b"))
        XCTAssertTrue(b.mixed)
        XCTAssertFalse(b.verified)
        // 0両は読まない
        XCTAssertNil(catalog.entry(for: "c"))
    }

    func testBundledCarTable() throws {
        let catalog = TrainCarCatalog.bundled
        XCTAssertFalse(catalog.fetched.isEmpty)
        // 線路の形を同梱したすべての路線に、両数がある
        for id in RailwayTrackCatalog.bundled.tracks.keys {
            let entry = try XCTUnwrap(catalog.entry(for: id), id)
            XCTAssertFalse(entry.sources.isEmpty, id)
            XCTAssertFalse(entry.name.isEmpty, id)
        }
        XCTAssertEqual(catalog.entry(for: "odpt.Railway:TokyoMetro.Ginza")?.cars, 6)
        XCTAssertEqual(catalog.entry(for: "odpt.Railway:TokyoMetro.Hibiya")?.cars, 7)
        XCTAssertEqual(catalog.entry(for: "odpt.Railway:Toei.Shinjuku")?.cars, 10)
        XCTAssertEqual(catalog.entry(for: "odpt.Railway:Toei.NipporiToneri")?.cars, 5)
        XCTAssertEqual(catalog.entry(for: "odpt.Railway:Toei.Mita")?.mixed, true)
        XCTAssertEqual(catalog.entry(for: "odpt.Railway:Toei.Arakawa")?.verified, false)
        // 千代田線の綾瀬〜北綾瀬は3両
        let chiyoda = try XCTUnwrap(catalog.entry(for: "odpt.Railway:TokyoMetro.Chiyoda"))
        let context = TrainCarResolver.Context(entry: chiyoda, override: nil, kindDefault: 10)
        XCTAssertEqual(TrainCarResolver.cars(for: train("1", stations: [0, 1]), schedule: schedule([]), context: context).cars, 3)
        XCTAssertEqual(TrainCarResolver.cars(for: train("2", stations: [0, 1, 2]), schedule: schedule([]), context: context).cars, 10)
    }
}

import CoreGraphics
import CoreLocation
import XCTest
@testable import SmartDashboard

/// 線路の形(同梱した国土数値情報)の読み込み、ODPT の路線との対応、線への投影と補間、駅の位置の合わせ込み
final class RailwayTrackTests: XCTestCase {
    private let origin = GeoPoint(35.68, 139.76)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(east: Double, north: Double) -> GeoPoint {
        GeoMath.offset(origin, east: east, north: north)
    }

    /// 半径1500mで90度曲がる線路。A駅(0, 0)から、中心(1500, 0)のまわりを回って B駅(1500, 1500)へ。3度ごとの点。
    private func curveTrack() -> [GeoPoint] {
        stride(from: 0.0, through: 90.0, by: 3.0).map { degrees in
            let angle = degrees * .pi / 180
            return point(east: 1500 - 1500 * cos(angle), north: 1500 * sin(angle))
        }
    }

    private func curveStations() -> [(id: String, name: String, point: GeoPoint)] {
        [(id: "A", name: "A駅", point: point(east: 0, north: 0)), (id: "B", name: "B駅", point: point(east: 1500, north: 1500))]
    }

    /// 円弧までの距離(m)
    private func distanceToArc(_ p: GeoPoint) -> Double {
        let local = GeoMath.local(p, origin: origin)
        return abs(((local.x - 1500) * (local.x - 1500) + local.y * local.y).squareRoot() - 1500)
    }

    // MARK: - 同梱したデータと ODPT の路線の対応

    func testBundledTracksForToei() throws {
        let catalog = RailwayTrackCatalog.bundled
        XCTAssertTrue(catalog.source.contains("国土数値情報"))
        XCTAssertFalse(catalog.fetched.isEmpty)
        let ids = ["Asakusa", "Mita", "Shinjuku", "Oedo", "Arakawa", "NipporiToneri"].map { "odpt.Railway:Toei." + $0 }
        for id in ids {
            let track = try XCTUnwrap(catalog.track(for: id), id)
            XCTAssertGreaterThanOrEqual(track.count, 10, id)
        }
        // 長さは実際の路線に近い(浅草線 18.3km、大江戸線 40.7km)
        XCTAssertEqual(GeoPath(try XCTUnwrap(catalog.track(for: ids[0]))).length, 18_400, accuracy: 700)
        XCTAssertEqual(GeoPath(try XCTUnwrap(catalog.track(for: ids[3]))).length, 40_700, accuracy: 1000)
        XCTAssertNil(catalog.track(for: "odpt.Railway:Unknown.Line"))
        XCTAssertTrue(RailwayTrackCatalog.attribution.contains("加工"))
    }

    func testCatalogDecoding() throws {
        let json = """
        {"source":"テスト","fetched":"2026-09-28","railways":{
          "r1":{"n02":["1号線"],"points":[[35.0,139.0],[35.001,139.001]]},
          "r2":{"n02":[],"points":[[35.0,139.0]]},
          "r3":{"points":[[35.0],[35.1,139.1],[35.2,139.2]]}}}
        """
        let catalog = try RailwayTrackCatalog(data: Data(json.utf8))
        XCTAssertEqual(catalog.fetched, "2026-09-28")
        XCTAssertEqual(catalog.track(for: "r1"), [GeoPoint(35.0, 139.0), GeoPoint(35.001, 139.001)])
        // 点が2つない線と、壊れた点は使わない
        XCTAssertNil(catalog.track(for: "r2"))
        XCTAssertEqual(catalog.track(for: "r3")?.count, 2)
    }

    /// ODPT の駅(路線の駅の順)を、同梱した線路の形に合わせる
    func testODPTStationsSnapToBundledTrack() throws {
        let railway = try XCTUnwrap(ODPTClient.decode([ODPTRailway].self, from: Fixture.data("odpt_railway")).first)
        let stations = try ODPTClient.decode([ODPTStation].self, from: Fixture.data("odpt_station"))
        let shape = RailwayShape.build(railway: railway, stations: stations)
        let track = RailwayTrackCatalog.bundled.track(for: railway.sameAs)
        let line = try XCTUnwrap(RideLine.make(shape: shape, name: "浅草線", track: track))
        XCTAssertTrue(line.usesTrack)
        XCTAssertEqual(line.stations.map(\.name), ["西馬込", "馬込", "中延"])
        // 駅は線路の近く(50m以内)にあり、線に沿った位置は駅の順に増える
        XCTAssertTrue(line.stations.allSatisfy { $0.offset < 50 })
        XCTAssertEqual(line.stations.map(\.along), line.stations.map(\.along).sorted())
        XCTAssertLessThan(line.stations[0].along, 300)
        // 合わせた位置は線路の上
        let snapped = try XCTUnwrap(line.stationPoint("odpt.Station:Toei.Asakusa.Magome"))
        XCTAssertEqual(try XCTUnwrap(line.path.project(snapped)).lateral, 0, accuracy: 0.5)
        // 線路の形がなければ、駅を結んだ直線
        let straight = try XCTUnwrap(RideLine.make(shape: shape, name: "浅草線"))
        XCTAssertFalse(straight.usesTrack)
        XCTAssertEqual(straight.path.points.count, 3)
    }

    // MARK: - 駅の位置の合わせ込み

    func testSnapStationsOntoStraightTrack() throws {
        // 50mごとの点がある、東へまっすぐな線路
        let track = stride(from: 0.0, through: 3000.0, by: 50.0).map { point(east: $0, north: 0) }
        let line = RideLine(railwayID: "r", name: "線", stations: [
            (id: "S1", name: "S1", point: point(east: -20, north: 10)),
            (id: "S2", name: "S2", point: point(east: 1000, north: 40)),
            (id: "S3", name: "S3", point: point(east: 2010, north: -30)),
        ], track: track)
        XCTAssertEqual(line.stations[0].along, 0, accuracy: 0.5)
        XCTAssertEqual(line.stations[1].along, 1000, accuracy: 1)
        XCTAssertEqual(line.stations[1].offset, 40, accuracy: 0.5)
        XCTAssertEqual(line.stations[2].along, 2010, accuracy: 1)
        XCTAssertEqual(line.stations[2].offset, 30, accuracy: 0.5)
        // 点の位置ちょうどなら、補間の誤差なしにその点
        XCTAssertEqual(line.path.point(atAlong: line.path.cumulative[4]), track[4])
    }

    func testSnapKeepsStationOrderOnLoop() throws {
        // 環状の線: 出発点の近くに戻ってくる(大江戸線の都庁前のように、同じ駅を2回通る)
        let track = [point(east: 0, north: 0), point(east: 1000, north: 0), point(east: 1000, north: 1000),
                     point(east: 0, north: 1000), point(east: 0, north: 40)]
        let line = RideLine(railwayID: "r", name: "環状", stations: [
            (id: "T", name: "都庁前", point: point(east: 0, north: 10)),
            (id: "E", name: "東", point: point(east: 1000, north: 500)),
            (id: "N", name: "北", point: point(east: 500, north: 1000)),
            (id: "T", name: "都庁前", point: point(east: 0, north: 10)),
        ], track: track)
        let alongs = line.stations.map(\.along)
        // 最初の都庁前は線の始め、最後の都庁前は線の終わりに合わせる(先の区間へ飛ばない、手前に戻らない)
        XCTAssertEqual(alongs[0], 0, accuracy: 0.5)
        XCTAssertEqual(alongs[1], 1500, accuracy: 1)
        XCTAssertEqual(alongs[2], 2500, accuracy: 1)
        XCTAssertEqual(alongs[3], line.path.length, accuracy: 1)
        XCTAssertEqual(line.stationAlong("T", near: 3900) ?? 0, line.path.length, accuracy: 1)
        XCTAssertEqual(line.stationAlong("T", near: 100) ?? -1, 0, accuracy: 0.5)
    }

    // MARK: - 線路の形に沿った補間

    func testTrainPositionFollowsCurve() throws {
        let track = RideLine(railwayID: "r", name: "カーブ線", stations: curveStations(), track: curveTrack())
        let straight = RideLine(railwayID: "r", name: "カーブ線", stations: curveStations())
        let schedule = LineSchedule(railwayID: "r", downloadedAt: Date(), stationIDs: ["A", "B"], trains: [])
        let position = TrainPosition(id: "t", number: "t", direction: "up", trainType: "普通", destination: "B駅", delay: .timetable,
                                     fromStation: 0, toStation: 1, fraction: 0.5, isStopped: false, isWaitingToDepart: false,
                                     upcoming: [TrainPosition.UpcomingStop(station: 1, arrival: start)])
        let onTrack = try XCTUnwrap(TrainBoard.coordinate(of: position, in: BoardLine(railwayID: "r", name: "カーブ線", schedule: schedule,
                                                                                    shape: nil, positions: [], ride: track)))
        // 駅の間の半分は、円弧の真ん中(45度)。進む向きは北東。
        let expected = point(east: 1500 - 1500 * cos(.pi / 4), north: 1500 * sin(.pi / 4))
        XCTAssertLessThan(GeoMath.distance(GeoPoint(onTrack.coordinate), expected), 15)
        XCTAssertEqual(try XCTUnwrap(onTrack.heading), 45, accuracy: 3)
        // 駅を結んだ直線では、円弧から400m以上離れた弦の上になる
        let onChord = try XCTUnwrap(TrainBoard.coordinate(of: position, in: BoardLine(railwayID: "r", name: "カーブ線", schedule: schedule,
                                                                                    shape: nil, positions: [], ride: straight)))
        XCTAssertGreaterThan(distanceToArc(GeoPoint(onChord.coordinate)), 400)
    }

    /// デバッグの場面「カーブの大きい区間」: 線路に沿って走ったとき、線路の形なら判定が途切れず、駅を結んだ直線では途切れる
    func testRideDetectionOnSharpCurve() throws {
        let track = RideLine(railwayID: "r", name: "カーブ線", stations: curveStations(), track: curveTrack())
        let straight = RideLine(railwayID: "r", name: "カーブ線", stations: curveStations())
        // 「路線に沿わせる」で作った経路は、線路の形に沿う
        var base = VirtualPlan()
        base.speedKmh = 57.6
        let plan = try XCTUnwrap(VirtualPlan.stationPlan(line: track, fromStation: 0, toStation: 1, dwell: 0, base: base))
        XCTAssertGreaterThan(plan.points.count, 10)
        XCTAssertTrue(plan.points.allSatisfy { distanceToArc($0) < 2 })
        XCTAssertTrue(plan.stops.isEmpty)

        var mover = VirtualMover(plan: plan)
        var onTrack = RideDetector()
        var onChord = RideDetector()
        var trackStates: [RideJudgement.State] = []
        var chordStates: [RideJudgement.State] = []
        var time = start
        while !mover.isFinished {
            mover.advance(realSeconds: 1, speedKmh: plan.speedKmh, timeScale: 1)
            time = time.addingTimeInterval(1)
            let sample = try XCTUnwrap(mover.sample(at: time, accuracy: 10, speedKmh: plan.speedKmh))
            trackStates.append(onTrack.add(sample, context: RideContext(lines: [track], trains: [])).state)
            chordStates.append(onChord.add(sample, context: RideContext(lines: [straight], trains: [])).state)
        }
        // 円弧の長さ 約2356m ÷ 16m/s ≒ 147秒
        XCTAssertGreaterThan(trackStates.count, 140)
        XCTAssertTrue(trackStates[40..<140].allSatisfy { $0 == .riding }, "線路の形なら、カーブでも判定が続く")
        XCTAssertFalse(chordStates[40..<110].contains(.riding), "駅を結んだ直線では、カーブの途中で線から離れて判定が出ない")
    }

    func testStationPlanFollowsTrackAndStopsAtStations() throws {
        // 折れ曲がった線路の上の3駅
        let track = [point(east: 0, north: 0), point(east: 600, north: 0), point(east: 1000, north: 400), point(east: 1000, north: 1200)]
        let line = RideLine(railwayID: "r", name: "線", stations: [
            (id: "S0", name: "S0", point: point(east: 0, north: 5)),
            (id: "S1", name: "S1", point: point(east: 1010, north: 600)),
            (id: "S2", name: "S2", point: point(east: 1000, north: 1200)),
        ], track: track)
        let plan = try XCTUnwrap(VirtualPlan.stationPlan(line: line, fromStation: 0, toStation: 2, dwell: 20, base: VirtualPlan()))
        // 駅と、その間の線路の点(600,0)(1000,400)
        XCTAssertEqual(plan.points.count, 5)
        XCTAssertEqual(plan.points[1], track[1])
        XCTAssertEqual(plan.points[2], track[2])
        XCTAssertEqual(plan.stops.map(\.pointIndex), [3])
        XCTAssertEqual(plan.stops.first?.name, "S1")
        XCTAssertLessThan(GeoMath.distance(plan.points[3], point(east: 1000, north: 600)), 1)
        // 逆向き
        let back = try XCTUnwrap(VirtualPlan.stationPlan(line: line, fromStation: 2, toStation: 0, dwell: 20, base: VirtualPlan()))
        XCTAssertEqual(back.points.count, 5)
        XCTAssertEqual(back.points[2], track[2])
        XCTAssertEqual(back.points[3], track[1])
        XCTAssertEqual(back.stops.map(\.pointIndex), [1])
    }

    // MARK: - 画面の構成

    func testMapHeightOnSmallScreen() {
        // iPhone SE(高さ667pt)では、スクロールの見える高さは約470pt。地図はその55%で、画面の約4割。
        XCTAssertEqual(TrainView.mapHeight(visibleHeight: 470), 258.5, accuracy: 0.1)
        XCTAssertEqual(TrainView.mapHeight(visibleHeight: 300), 220)
        XCTAssertEqual(TrainView.mapHeight(visibleHeight: 1000), 420)
    }
}

import CoreGraphics
import XCTest
@testable import SmartDashboard

/// 経路の検索(接続を順に調べる方式)
final class JourneyPlannerTests: XCTestCase {
    private let calendar = JapaneseHolidays.calendar
    private let weekday = "odpt.Calendar:Weekday"
    private typealias Links = [String: [(stationID: String, seconds: TimeInterval)]]

    /// 2026-09-16〜18 は平日(水・木・金)
    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute, second: second))!
    }

    private func train(_ number: String, direction: String = "up", type: String = "普通", destination: String = "終点",
                       stops: [(Int, Int?, Int?)]) -> LineSchedule.Train {
        LineSchedule.Train(number: number, calendar: weekday, direction: direction, trainType: type, destination: destination,
                           stops: stops.map { LineSchedule.Stop(station: $0.0, arrival: $0.1, departure: $0.2) })
    }

    /// X線: x0→x1→x2→x3。8:00〜9:00に10分ごと。駅の間は3分。
    private func lineX(extra: [LineSchedule.Train] = []) -> LineSchedule {
        var trains: [LineSchedule.Train] = []
        for (index, t) in stride(from: 480, through: 540, by: 10).enumerated() {
            trains.append(train("X\(index)", stops: [(0, nil, t), (1, t + 3, t + 3), (2, t + 6, t + 6), (3, t + 9, nil)]))
        }
        return LineSchedule(railwayID: "x", downloadedAt: Date(), stationIDs: ["x0", "x1", "x2", "x3"], trains: trains + extra)
    }

    /// Y線: y0→y1→y2。y0 は x2 と乗り換えできる。every 分ごとに、8:02から。
    private func lineY(every: Int = 10) -> LineSchedule {
        var trains: [LineSchedule.Train] = []
        for (index, t) in stride(from: 482, through: 560, by: every).enumerated() {
            trains.append(train("Y\(index)", stops: [(0, nil, t), (1, t + 4, t + 4), (2, t + 8, nil)]))
        }
        return LineSchedule(railwayID: "y", downloadedAt: Date(), stationIDs: ["y0", "y1", "y2"], trains: trains)
    }

    /// Z線: z0→z1。z0 は y2 と乗り換えできる。8:05から15分ごと。
    private func lineZ() -> LineSchedule {
        var trains: [LineSchedule.Train] = []
        for (index, t) in stride(from: 485, through: 590, by: 15).enumerated() {
            trains.append(train("Z\(index)", stops: [(0, nil, t), (1, t + 5, nil)]))
        }
        return LineSchedule(railwayID: "z", downloadedAt: Date(), stationIDs: ["z0", "z1"], trains: trains)
    }

    private func links(_ seconds: TimeInterval) -> Links {
        ["x2": [("y0", seconds)], "y0": [("x2", seconds)], "y2": [("z0", seconds)], "z0": [("y2", seconds)]]
    }

    private func search(_ schedules: [LineSchedule], from origins: Set<String>, to destinations: Set<String>, at start: Date,
                        transfer: TimeInterval = 300, links table: Links? = nil) -> [JourneyOption] {
        let transfers = table ?? links(transfer)
        let trips = JourneyPlanner.trips(schedules: schedules, from: start, horizon: 6 * 3600, resolver: DayTypeResolver())
        return JourneyPlanner.search(trips: trips, query: JourneyQuery(origins: origins, destinations: destinations, departure: start),
                                     sameStationTransfer: transfer, transfers: { transfers[$0] ?? [] },
                                     stationName: { $0.uppercased() }, railwayName: { $0 + "線" })
    }

    func testDirectJourneyAndLaterTrains() throws {
        let options = search([lineX()], from: ["x0"], to: ["x3"], at: date(17, 8, 1))
        XCTAssertEqual(options.map(\.kind), [.fastest, .later, .later])
        XCTAssertEqual(options.map(\.journey.departure), [date(17, 8, 10), date(17, 8, 20), date(17, 8, 30)])
        let journey = try XCTUnwrap(options.first?.journey)
        XCTAssertEqual(journey.transfers, 0)
        XCTAssertEqual(journey.arrival, date(17, 8, 19))
        let leg = try XCTUnwrap(journey.legs.first)
        XCTAssertEqual(leg.trainNumber, "X1")
        XCTAssertEqual(leg.board.stationID, "x0")
        XCTAssertEqual(leg.alight.stationID, "x3")
        XCTAssertEqual(leg.board.name, "X0")
        XCTAssertEqual(leg.stops.count, 4)
        XCTAssertEqual(leg.railwayName, "x線")
        // 列車のIDは、時刻表から計算した列車の位置(乗車中の判定)と同じ形
        XCTAssertEqual(leg.tripID, TrainPositionCalculator.tripID(number: "X1", calendar: weekday, day: date(17, 0, 0)))
    }

    func testOneTransfer() throws {
        let options = search([lineX(), lineY()], from: ["x0"], to: ["y2"], at: date(17, 8, 0))
        let journey = try XCTUnwrap(options.first?.journey)
        XCTAssertEqual(options.first?.kind, .fastest)
        XCTAssertEqual(journey.transfers, 1)
        XCTAssertEqual(journey.legs.map(\.railwayID), ["x", "y"])
        XCTAssertEqual(journey.legs.map(\.trainNumber), ["X0", "Y1"])
        XCTAssertEqual(journey.departure, date(17, 8, 0))
        XCTAssertEqual(journey.legs[0].alight.arrival, date(17, 8, 6))
        XCTAssertEqual(journey.legs[1].board.departure, date(17, 8, 12))
        XCTAssertEqual(journey.arrival, date(17, 8, 20))
        XCTAssertEqual(journey.waits.map(\.seconds), [360])
        XCTAssertEqual(journey.waits.first?.stationName, "X2")
        XCTAssertEqual(journey.waits.first?.nextStationName, "Y0")
        XCTAssertEqual(options.count, 3)
    }

    func testTransferTimeIsRespected() throws {
        // 乗り換えに7分かかると、8:12のY線には間に合わず、8:22になる
        let options = search([lineX(), lineY()], from: ["x0"], to: ["y2"], at: date(17, 8, 0), transfer: 420)
        let journey = try XCTUnwrap(options.first?.journey)
        XCTAssertEqual(journey.legs.map(\.trainNumber), ["X0", "Y2"])
        XCTAssertEqual(journey.arrival, date(17, 8, 30))
        XCTAssertEqual(JourneyPlanner.transferTime("x2", "y0", sameStationTransfer: 60, transfers: { self.links(420)[$0] ?? [] }), 420)
        XCTAssertEqual(JourneyPlanner.transferTime("x2", "x2", sameStationTransfer: 60, transfers: { self.links(420)[$0] ?? [] }), 60)
    }

    func testLatestFirstTrainForTheSameArrival() throws {
        // Y線が30分ごと(8:02、8:32)なら、8:00・8:10・8:20のどのX線でも8:32に乗れる。一番遅い8:20を出す。
        let options = search([lineX(), lineY(every: 30)], from: ["x0"], to: ["y2"], at: date(17, 8, 0))
        let journey = try XCTUnwrap(options.first?.journey)
        XCTAssertEqual(journey.legs.map(\.trainNumber), ["X2", "Y1"])
        XCTAssertEqual(journey.departure, date(17, 8, 20))
        XCTAssertEqual(journey.arrival, date(17, 8, 40))
        XCTAssertEqual(journey.waits.map(\.seconds), [360])
    }

    func testTwoTransfers() throws {
        let options = search([lineX(), lineY(), lineZ()], from: ["x0"], to: ["z1"], at: date(17, 8, 0))
        let journey = try XCTUnwrap(options.first?.journey)
        XCTAssertEqual(journey.transfers, 2)
        XCTAssertEqual(journey.legs.map(\.railwayID), ["x", "y", "z"])
        // 8:35のZ線に間に合う範囲で、前の2本もできるだけ遅い列車にする
        XCTAssertEqual(journey.legs.map(\.trainNumber), ["X1", "Y2", "Z2"])
        XCTAssertEqual(journey.departure, date(17, 8, 10))
        XCTAssertEqual(journey.arrival, date(17, 8, 40))
        XCTAssertEqual(journey.waits.map(\.seconds), [360, 300])
    }

    func testFewerTransfersOptionComesAfterFastest() throws {
        // a→b(L1)→b2→c(L3)は8:15着で乗り換え1回、a2→c2(L2)は8:30着で乗り換えなし
        let l1 = LineSchedule(railwayID: "l1", downloadedAt: Date(), stationIDs: ["a", "b"],
                              trains: [train("P1", stops: [(0, nil, 480), (1, 485, nil)])])
        let l3 = LineSchedule(railwayID: "l3", downloadedAt: Date(), stationIDs: ["b2", "c"],
                              trains: [train("Q1", stops: [(0, nil, 490), (1, 495, nil)])])
        let l2 = LineSchedule(railwayID: "l2", downloadedAt: Date(), stationIDs: ["a2", "c2"],
                              trains: [train("S1", stops: [(0, nil, 482), (1, 510, nil)])])
        let table: Links = ["b": [("b2", 180)], "b2": [("b", 180)]]
        let options = search([l1, l2, l3], from: ["a", "a2"], to: ["c", "c2"], at: date(17, 7, 59), transfer: 180, links: table)
        XCTAssertEqual(options.map(\.kind), [.fastest, .fewerTransfers])
        XCTAssertEqual(options.map(\.journey.arrival), [date(17, 8, 15), date(17, 8, 30)])
        XCTAssertEqual(options.map(\.journey.transfers), [1, 0])
    }

    func testAcrossMidnight() throws {
        // 23:55発(24:04着)と、24:20発の列車
        let late = [
            train("X90", stops: [(0, nil, 1435), (1, 1438, 1438), (2, 1441, 1441), (3, 1444, nil)]),
            train("X91", stops: [(0, nil, 1460), (1, 1463, 1463), (2, 1466, 1466), (3, 1469, nil)]),
        ]
        let evening = search([lineX(extra: late)], from: ["x0"], to: ["x3"], at: date(17, 23, 50))
        let first = try XCTUnwrap(evening.first?.journey)
        XCTAssertEqual(first.departure, date(17, 23, 55))
        XCTAssertEqual(first.arrival, date(18, 0, 4))
        XCTAssertEqual(evening.map(\.journey.departure), [date(17, 23, 55), date(18, 0, 20)])

        // 0時を過ぎてから探すと、前の日の運行日の 24:20 発に乗れる
        let night = search([lineX(extra: late)], from: ["x0"], to: ["x3"], at: date(18, 0, 10))
        let journey = try XCTUnwrap(night.first?.journey)
        XCTAssertEqual(night.count, 1)
        XCTAssertEqual(journey.departure, date(18, 0, 20))
        XCTAssertEqual(journey.legs.first?.tripID, TrainPositionCalculator.tripID(number: "X91", calendar: weekday, day: date(17, 0, 0)))
    }

    func testNoRouteAfterLastTrainAndSameStation() {
        XCTAssertTrue(search([lineX()], from: ["x0"], to: ["x3"], at: date(17, 10, 0)).isEmpty)
        XCTAssertTrue(search([lineX()], from: ["x0"], to: ["x0"], at: date(17, 8, 0)).isEmpty)
        // 乗り換えのない路線どうしは、つながらない
        XCTAssertTrue(search([lineX(), lineZ()], from: ["x0"], to: ["z1"], at: date(17, 8, 0), links: [:]).isEmpty)
    }

    func testTripsAroundStart() {
        let trips = JourneyPlanner.trips(schedules: [lineX()], from: date(17, 8, 25), horizon: 3600, resolver: DayTypeResolver())
        // 8:25より前に着いた列車(8:00、8:10)は使わない。8:20発の列車は、まだ走っているので含める。
        XCTAssertEqual(trips.map(\.number), ["X2", "X3", "X4", "X5", "X6"])
        XCTAssertEqual(trips.first?.stops.map(\.stationID), ["x0", "x1", "x2", "x3"])
    }
}

/// 駅の時刻表と「急げば間に合う」
final class StationDepartureTests: XCTestCase {
    private let calendar = JapaneseHolidays.calendar

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func schedule() -> LineSchedule {
        var trains: [LineSchedule.Train] = []
        for (index, t) in stride(from: 480, through: 540, by: 10).enumerated() {
            trains.append(LineSchedule.Train(number: "X\(index)", calendar: "odpt.Calendar:Weekday", direction: "up", trainType: "普通",
                                             destination: "終点", stops: [
                                                 LineSchedule.Stop(station: 0, arrival: nil, departure: t, platform: "1"),
                                                 LineSchedule.Stop(station: 1, arrival: t + 3, departure: t + 3),
                                                 LineSchedule.Stop(station: 2, arrival: t + 6, departure: nil),
                                             ]))
        }
        trains.append(LineSchedule.Train(number: "D1", calendar: "odpt.Calendar:Weekday", direction: "down", trainType: "急行",
                                         destination: "始点", stops: [
                                             LineSchedule.Stop(station: 2, arrival: nil, departure: 500),
                                             LineSchedule.Stop(station: 1, arrival: 503, departure: 504),
                                             LineSchedule.Stop(station: 0, arrival: 507, departure: nil),
                                         ]))
        return LineSchedule(railwayID: "x", downloadedAt: Date(), stationIDs: ["x0", "x1", "x2"], trains: trains)
    }

    func testDeparturesFromStation() throws {
        let now = date(17, 8, 5)
        let list = StationDepartures.scheduled(schedule: schedule(), stationID: "x1", now: now, resolver: DayTypeResolver())
        // 前日・今日・翌日の運行日の分(1日に8本)
        XCTAssertEqual(list.count, 24)
        XCTAssertEqual(list.map(\.scheduled), list.map(\.scheduled).sorted())
        let today = list.filter { $0.serviceDay == date(17, 0, 0) }
        XCTAssertEqual(today.count, 8)
        XCTAssertEqual(today.first?.scheduled, date(17, 8, 3))
        // 終点での到着は出発ではないので出さない。始発駅は「当駅始発」、番線も出す。
        XCTAssertTrue(StationDepartures.scheduled(schedule: schedule(), stationID: "x2", now: now, resolver: DayTypeResolver())
            .allSatisfy { $0.trainNumber == "D1" })
        let origin = StationDepartures.scheduled(schedule: schedule(), stationID: "x0", now: now, resolver: DayTypeResolver())
        XCTAssertTrue(origin.allSatisfy(\.isOrigin))
        XCTAssertEqual(origin.first?.platform, "1")

        // 遅れは、今の前後3時間の列車にだけ反映する(列車番号は毎日同じなので)
        let delayed = StationDepartures.applyingDelays(list, delays: ["X1": 120], now: now)
        let x1Today = try XCTUnwrap(delayed.first { $0.trainNumber == "X1" && $0.serviceDay == date(17, 0, 0) })
        XCTAssertEqual(x1Today.expected, date(17, 8, 15))
        XCTAssertEqual(x1Today.effective, date(17, 8, 15))
        XCTAssertNil(delayed.first { $0.trainNumber == "X1" && $0.serviceDay == date(16, 0, 0) }?.expected)

        // 方面ごと(方面の一覧の順)。今から6本と、今の運行日の始発・終電。
        let boards = StationDepartures.boards(delayed, now: now, directionOrder: ["up", "down"])
        XCTAssertEqual(boards.map(\.direction), ["up", "down"])
        XCTAssertEqual(boards[0].departures.count, 6)
        XCTAssertEqual(boards[0].departures.first?.trainNumber, "X1")
        XCTAssertEqual(boards[0].first, date(17, 8, 3))
        XCTAssertEqual(boards[0].last, date(17, 9, 3))
        XCTAssertEqual(boards[1].departures.first?.scheduled, date(17, 8, 24))

        // 3時より前は、前の日の運行日
        XCTAssertEqual(StationDepartures.serviceDay(of: date(18, 2, 0)), date(17, 0, 0))
        XCTAssertEqual(StationDepartures.serviceDay(of: date(18, 3, 0)), date(18, 0, 0))
    }

    func testCatchStatus() throws {
        let walk = WalkSettings()
        // 400m: 400×1.3÷(4.8km/h)=390秒 + 駅の中2分 = 510秒。急げば 260秒 + 120秒 = 380秒。
        XCTAssertEqual(CatchEstimator.walkSeconds(distance: 400, settings: walk, hurry: false), 510, accuracy: 0.5)
        XCTAssertEqual(CatchEstimator.walkSeconds(distance: 400, settings: walk, hurry: true), 380, accuracy: 0.5)
        let now = date(17, 8, 0)
        XCTAssertEqual(CatchEstimator.status(departure: now.addingTimeInterval(600), now: now, distance: 400, settings: walk), .comfortable)
        XCTAssertEqual(CatchEstimator.status(departure: now.addingTimeInterval(450), now: now, distance: 400, settings: walk), .hurry)
        XCTAssertEqual(CatchEstimator.status(departure: now.addingTimeInterval(300), now: now, distance: 400, settings: walk), .missed)
        // 駅にいても、駅の中の移動の時間はかかる
        XCTAssertEqual(CatchEstimator.status(departure: now.addingTimeInterval(100), now: now, distance: 0, settings: walk), .missed)
        // 設定を変えると結果も変わる
        var slow = walk
        slow.speedKmh = 3
        slow.accessMinutes = 0
        XCTAssertEqual(CatchEstimator.walkSeconds(distance: 300, settings: slow, hurry: false), 468, accuracy: 0.5)

        let list = StationDepartures.scheduled(schedule: schedule(), stationID: "x1", now: now, resolver: DayTypeResolver())
            .filter { $0.scheduled >= now }
        // 8:03(3分後)は間に合わず、8:13が「間に合う」
        let next = try XCTUnwrap(CatchEstimator.nextComfortable(list, now: now, distance: 400, settings: walk))
        XCTAssertEqual(next.scheduled, date(17, 8, 13))
        XCTAssertEqual(CatchStatus.hurry.label, "急げば間に合う")
    }
}

/// 地図の駅に重ねる電車の選び方と並べ方
final class StationTrainPlacementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func position(_ id: String, direction: String = "N", from: Int, to: Int, stopped: Bool, waiting: Bool = false,
                          next: TimeInterval? = nil, type: String = "普通", destination: String = "西馬込",
                          platform: String? = nil, nextPlatform: String? = nil, delay: DelaySource = .timetable) -> TrainPosition {
        TrainPosition(id: id, number: id, direction: direction, trainType: type, destination: destination, delay: delay,
                      fromStation: from, toStation: to, fraction: 0.5, isStopped: stopped, isWaitingToDepart: waiting,
                      upcoming: next.map { [TrainPosition.UpcomingStop(station: to, arrival: now.addingTimeInterval($0), platform: nextPlatform)] } ?? [],
                      currentPlatform: platform)
    }

    private func line() -> BoardLine {
        BoardLine(railwayID: "r", name: "線", schedule: LineSchedule(railwayID: "r", downloadedAt: Date(), stationIDs: ["A", "B", "C"], trains: []),
                  shape: nil, positions: [])
    }

    func testChoosesStoppedAndArrivingTrains() {
        let positions = [
            position("t1", from: 0, to: 1, stopped: true),
            position("t2", from: 0, to: 1, stopped: false, next: 120, type: "急行"),
            position("t3", from: 1, to: 2, stopped: false, next: 400),
            position("t4", from: 0, to: 1, stopped: true, waiting: true, next: 60),
            position("t5", direction: "S", from: 1, to: 0, stopped: true, delay: .realtime(180)),
            position("t6", direction: "S", from: 2, to: 1, stopped: false, next: 60),
        ]
        let items = StationTrainPlacement.items(positions: positions, line: line(), now: now, directionOrder: ["N", "S"])
        // 3分より先に着く電車と、始発駅で発車を待つ電車は出さない
        XCTAssertEqual(Set(items.map(\.trainID)), ["t1", "t2", "t5", "t6"])
        let t2 = items.first { $0.trainID == "t2" }
        XCTAssertEqual(t2?.stationID, "B")
        XCTAssertEqual(t2?.isStopped, false)
        XCTAssertEqual(t2?.label, "急西")
        XCTAssertEqual(t2?.isExpress, true)
        XCTAssertEqual(items.first { $0.trainID == "t1" }?.stationID, "A")
        XCTAssertEqual(items.first { $0.trainID == "t1" }?.label, "西")
        XCTAssertEqual(items.first { $0.trainID == "t5" }?.tone, .delayed)

        // B駅: 方面の順に行を分け、行の中は停車中が先、あとは着く順
        let slots = StationTrainPlacement.place(items)["B"] ?? []
        XCTAssertEqual(slots.map(\.item.trainID), ["t2", "t5", "t6"])
        XCTAssertEqual(slots.map(\.row), [0, 1, 1])
        XCTAssertEqual(slots.map(\.column), [0, 0, 1])
        XCTAssertTrue(slots.allSatisfy { $0.rowCount == 2 })
        // 駅の点の左に、行を上下に並べる
        XCTAssertEqual(StationTrainPlacement.offset(of: slots[0]), CGPoint(x: -21, y: -8))
        XCTAssertEqual(StationTrainPlacement.offset(of: slots[2]), CGPoint(x: -47, y: 8))
    }

    func testPlatformOrderAndOverflow() {
        let items = [
            StationTrainItem(trainID: "a", stationID: "S", direction: "N", directionRank: 0, platform: "2", label: "a", isExpress: false,
                             tone: .onTime, isStopped: true, secondsToArrival: 0),
            StationTrainItem(trainID: "b", stationID: "S", direction: "S", directionRank: 1, platform: "1", label: "b", isExpress: false,
                             tone: .onTime, isStopped: false, secondsToArrival: 30),
        ]
        // 番線がすべての電車で分かるときは、方面ではなく番線の順
        XCTAssertEqual(StationTrainPlacement.slots(items).map(\.item.trainID), ["b", "a"])

        let many = (0..<5).map { index in
            StationTrainItem(trainID: "t\(index)", stationID: "S", direction: "N", directionRank: 0, platform: nil, label: "", isExpress: false,
                             tone: .onTime, isStopped: false, secondsToArrival: Double(100 - index * 10))
        }
        let slots = StationTrainPlacement.slots(many)
        XCTAssertEqual(slots.count, StationTrainPlacement.maxPerRow)
        XCTAssertEqual(slots.map(\.item.trainID), ["t4", "t3", "t2"])
        XCTAssertEqual(slots.map(\.hiddenCount), [0, 0, 2])
        XCTAssertTrue(StationTrainPlacement.slots([]).isEmpty)
    }
}

/// 駅の一覧と乗り換えの関係
final class TransitDirectoryTests: XCTestCase {
    private let origin = GeoPoint(35.6568, 139.7546)

    private func directory() -> TransitDirectory {
        func station(_ id: String, _ name: String, _ railway: String, east: Double, north: Double, connecting: [String] = []) -> TransitStation {
            let point = GeoMath.offset(origin, east: east, north: north)
            return TransitStation(id: "odpt.Station:T.\(railway).\(id)", name: name, railwayID: "odpt.Railway:T.\(railway)",
                                  latitude: point.latitude, longitude: point.longitude, connecting: connecting)
        }
        let list = [
            // 片方の駅にだけ乗り換えが書かれている
            station("Daimon", "大門", "A", east: 0, north: 0, connecting: ["odpt.Station:T.B.Daimon", "odpt.Station:Other.X.Hamamatsucho"]),
            station("Daimon", "大門", "B", east: 95, north: 0),
            // 乗り換えが書かれていない同じ名前の駅(285m)
            station("Mita", "三田", "A", east: 0, north: 2000),
            station("Mita", "三田", "C", east: 285, north: 2000),
            // 名前の違う乗り換え
            station("HigashiNihombashi", "東日本橋", "A", east: 0, north: 4000, connecting: ["odpt.Station:T.B.BakuroYokoyama"]),
            station("BakuroYokoyama", "馬喰横山", "B", east: 171, north: 4000),
            // 同じ名前でも900m離れていれば、乗り換えとみなさない
            station("Higashiguchi", "東口", "A", east: 0, north: 6000),
            station("Higashiguchi", "東口", "D", east: 900, north: 6000),
        ]
        return TransitDirectory(stations: list, railwayNames: ["odpt.Railway:T.A": "A線", "odpt.Railway:T.B": "B線"])
    }

    func testTransfers() {
        let d = directory()
        XCTAssertEqual(d.transferTargets(from: "odpt.Station:T.B.Daimon"), ["odpt.Station:T.A.Daimon"])
        XCTAssertEqual(d.transferTargets(from: "odpt.Station:T.A.Daimon"), ["odpt.Station:T.B.Daimon"])
        XCTAssertEqual(d.transferTargets(from: "odpt.Station:T.C.Mita"), ["odpt.Station:T.A.Mita"])
        XCTAssertEqual(d.transferTargets(from: "odpt.Station:T.B.BakuroYokoyama"), ["odpt.Station:T.A.HigashiNihombashi"])
        XCTAssertTrue(d.transferTargets(from: "odpt.Station:T.D.Higashiguchi").isEmpty)

        let walk = WalkSettings()
        // 150m以内は乗り換えの時間だけ。離れた駅は、150mを超えた分の歩く時間を足す。
        XCTAssertEqual(d.transferSeconds(from: "odpt.Station:T.A.Daimon", to: "odpt.Station:T.B.Daimon", transferMinutes: 5, walk: walk), 300)
        XCTAssertEqual(d.transferSeconds(from: "odpt.Station:T.A.Mita", to: "odpt.Station:T.C.Mita", transferMinutes: 5, walk: walk),
                       300 + 135 * 1.3 / (4.8 / 3.6), accuracy: 2)
        XCTAssertEqual(d.name(of: "odpt.Station:T.C.Mita"), "三田")
        XCTAssertEqual(d.railwayName(of: "odpt.Railway:T.A"), "A線")
        XCTAssertEqual(d.railwayName(of: "odpt.Railway:T.C"), "C")
    }

    func testGroupsSearchAndNearest() throws {
        let d = directory()
        let groups = d.groups()
        let daimon = try XCTUnwrap(groups.first { $0.name == "大門" })
        XCTAssertEqual(daimon.stationIDs, ["odpt.Station:T.A.Daimon", "odpt.Station:T.B.Daimon"])
        XCTAssertEqual(daimon.railwayIDs, ["odpt.Railway:T.A", "odpt.Railway:T.B"])
        // 名前の違う駅と、離れた同じ名前の駅は、別のグループ
        XCTAssertEqual(groups.filter { $0.name == "東口" }.count, 2)
        XCTAssertNotNil(groups.first { $0.name == "馬喰横山" })
        XCTAssertEqual(d.group(containing: "odpt.Station:T.C.Mita")?.stationIDs.count, 2)

        XCTAssertEqual(d.search("大").first?.name, "大門")
        XCTAssertEqual(d.search("daimon").first?.name, "大門")
        XCTAssertEqual(d.search("ＤＡＩＭＯＮ").first?.name, "大門")
        XCTAssertEqual(d.search("yokoyama").map(\.name), ["馬喰横山"])
        XCTAssertEqual(d.search("").count, groups.count)

        let near = try XCTUnwrap(d.nearest(to: GeoMath.offset(origin, east: 250, north: 1950)))
        XCTAssertEqual(near.station.id, "odpt.Station:T.C.Mita")
        XCTAssertEqual(d.nearest(to: origin, railways: ["odpt.Railway:T.B"])?.station.id, "odpt.Station:T.B.Daimon")
    }

    func testRailwaysOnShortestPaths() {
        let d = directory()
        XCTAssertEqual(d.railwaysOnShortestPaths(from: ["odpt.Railway:T.A"], to: ["odpt.Railway:T.C"]),
                       ["odpt.Railway:T.A", "odpt.Railway:T.C"])
        XCTAssertEqual(d.railwaysOnShortestPaths(from: ["odpt.Railway:T.B"], to: ["odpt.Railway:T.C"]),
                       ["odpt.Railway:T.B", "odpt.Railway:T.A", "odpt.Railway:T.C"])
        XCTAssertTrue(d.railwaysOnShortestPaths(from: ["odpt.Railway:T.A"], to: ["odpt.Railway:T.D"]).isEmpty)
        XCTAssertEqual(d.railwayGraph()["odpt.Railway:T.A"], ["odpt.Railway:T.B", "odpt.Railway:T.C"])
    }

    func testStationsFromODPT() throws {
        let list = try ODPTClient.decode([ODPTStation].self, from: Fixture.data("odpt_station"))
        let nakanobu = try XCTUnwrap(list.first { $0.sameAs == "odpt.Station:Toei.Asakusa.Nakanobu" })
        XCTAssertEqual(nakanobu.railway, "odpt.Railway:Toei.Asakusa")
        XCTAssertEqual(nakanobu.connectingStation, ["odpt.Station:Tokyu.Oimachi.Nakanobu"])
        let station = try XCTUnwrap(TransitStation(nakanobu))
        XCTAssertEqual(station.name, "中延")
        XCTAssertEqual(station.railwayID, "odpt.Railway:Toei.Asakusa")
        XCTAssertNotNil(station.point)
        XCTAssertNil(TransitStation(ODPTStation(sameAs: "x", title: nil, stationTitle: nil, latitude: nil, longitude: nil)))
        XCTAssertEqual(RouteRailwayResolver.operatorID(forRailway: "odpt.Railway:Toei.Mita"), "odpt.Operator:Toei")
        XCTAssertEqual(RouteRailwayResolver.operatorID(forRailway: "odpt.Railway:TokyoMetro.Ginza"), "odpt.Operator:TokyoMetro")
    }
}

/// 選んだ経路と乗車中の判定の連動、降りる駅の通知、デバッグで経路の列車に乗る動き
final class JourneyTrackingTests: XCTestCase {
    private let origin = GeoPoint(35.68, 139.76)
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func stop(_ id: String, _ arrival: TimeInterval, _ departure: TimeInterval) -> JourneyStop {
        JourneyStop(stationID: id, name: id.uppercased(), arrival: base.addingTimeInterval(arrival), departure: base.addingTimeInterval(departure))
    }

    private func journey() -> Journey {
        Journey(legs: [
            JourneyLeg(tripID: "t1", railwayID: "x", railwayName: "X線", trainNumber: "1", trainType: "普通", destination: "X9",
                       direction: "up", stops: [stop("x0", 0, 0), stop("x1", 120, 150), stop("x2", 270, 270)]),
            JourneyLeg(tripID: "t2", railwayID: "y", railwayName: "Y線", trainNumber: "2", trainType: "急行", destination: "Y9",
                       direction: "up", stops: [stop("y0", 600, 600), stop("y2", 840, 840)]),
        ])
    }

    private func riding(train: String?, railway: String) -> RideJudgement {
        var judgement = RideJudgement(state: .riding)
        judgement.trainID = train
        judgement.railwayID = railway
        return judgement
    }

    func testStatusAndAlightAlert() {
        let journey = journey()
        XCTAssertEqual(JourneyTracking.status(journey: journey, judgement: RideJudgement(state: .idle)), .notRiding)
        XCTAssertEqual(JourneyTracking.status(journey: journey, judgement: riding(train: "t1", railway: "x")), .onPlan(leg: 0))
        XCTAssertEqual(JourneyTracking.status(journey: journey, judgement: riding(train: "other", railway: "y")), .onLine(leg: 1))
        XCTAssertEqual(JourneyTracking.status(journey: journey, judgement: riding(train: nil, railway: "z")), .offRoute)

        // 次に止まる駅が降りる駅になったら(1駅前で)知らせる。区間ごとに1回だけ。
        let onX = riding(train: "t1", railway: "x")
        XCTAssertNil(JourneyTracking.alightAlert(journey: journey, judgement: onX, nextStationID: "x1", alerted: []))
        XCTAssertEqual(JourneyTracking.alightAlert(journey: journey, judgement: onX, nextStationID: "x2", alerted: []), 0)
        XCTAssertNil(JourneyTracking.alightAlert(journey: journey, judgement: onX, nextStationID: "x2", alerted: [0]))
        XCTAssertNil(JourneyTracking.alightAlert(journey: journey, judgement: onX, nextStationID: nil, alerted: []))
        // 列車を特定できなくても、経路の路線に乗っていれば知らせる
        XCTAssertEqual(JourneyTracking.alightAlert(journey: journey, judgement: riding(train: nil, railway: "y"), nextStationID: "y2", alerted: [0]), 1)
        XCTAssertNil(JourneyTracking.alightAlert(journey: journey, judgement: riding(train: nil, railway: "z"), nextStationID: "y2", alerted: []))

        XCTAssertEqual(JourneyTracking.alertText(journey: journey, leg: 0), "次はX2。降りてY線に乗り換えます")
        XCTAssertEqual(JourneyTracking.alertText(journey: journey, leg: 1), "次はY2。降りる準備をしてください")
    }

    func testNextStationID() {
        let line = RideLine(railwayID: "x", name: "X線", stations: (0..<3).map { index in
            (id: "x\(index)", name: "X\(index)", point: GeoMath.offset(origin, east: Double(index) * 1000, north: 0))
        })
        var judgement = RideJudgement(state: .riding)
        judgement.railwayID = "x"
        judgement.along = 1200
        judgement.isAscending = true
        XCTAssertEqual(RideInfo.nextStationID(judgement: judgement, lines: [line], trains: []), "x2")
        judgement.isAscending = false
        XCTAssertEqual(RideInfo.nextStationID(judgement: judgement, lines: [line], trains: []), "x1")
        judgement.trainID = "t"
        let train = RideTrainCandidate(id: "t", railwayID: "x", number: "t", trainType: "", destination: "", delay: .timetable, along: 1200,
                                       isAscending: false, isStopped: false,
                                       upcoming: [.init(stationID: "x1", name: "X1", arrival: base, along: 1000)])
        XCTAssertEqual(RideInfo.nextStationID(judgement: judgement, lines: [line], trains: [train]), "x1")
        XCTAssertNil(RideInfo.nextStationID(judgement: RideJudgement(state: .candidate), lines: [line], trains: []))
    }

    func testJourneyMotionFollowsTimetable() throws {
        let line = RideLine(railwayID: "x", name: "X線", stations: (0..<3).map { index in
            (id: "x\(index)", name: "X\(index)", point: GeoMath.offset(origin, east: Double(index) * 1000, north: 0))
        })
        let y0 = GeoMath.offset(origin, east: 2000, north: 100)
        let y2 = GeoMath.offset(origin, east: 2000, north: 1100)
        let motion = JourneyMotion(journey: journey(), lines: [line]) { id in
            switch id {
            case "y0": return y0
            case "y2": return y2
            default: return nil
            }
        }
        XCTAssertEqual(motion.legs.count, 2)
        XCTAssertEqual(motion.start, base)
        XCTAssertEqual(motion.end, base.addingTimeInterval(840))
        func distance(_ seconds: TimeInterval, _ expected: GeoPoint) throws -> Double {
            GeoMath.distance(try XCTUnwrap(motion.position(at: base.addingTimeInterval(seconds))), expected)
        }
        // 乗る前は最初の駅、駅の間は線に沿って進み、停車中は駅
        XCTAssertEqual(try distance(-60, line.path.points[0]), 0, accuracy: 1)
        XCTAssertEqual(try distance(60, GeoMath.offset(origin, east: 500, north: 0)), 0, accuracy: 2)
        XCTAssertEqual(try distance(135, line.path.points[1]), 0, accuracy: 1)
        // 乗り換えの間は、待ち時間の半分までは降りた駅、そのあとは次に乗る駅
        XCTAssertEqual(try distance(400, line.path.points[2]), 0, accuracy: 1)
        XCTAssertEqual(try distance(500, y0), 0, accuracy: 1)
        // 線のない路線は、駅の間をまっすぐに進む
        XCTAssertEqual(try distance(720, GeoMath.offset(origin, east: 2000, north: 600)), 0, accuracy: 3)
        XCTAssertEqual(try distance(2000, y2), 0, accuracy: 1)
    }

    /// デバッグの流れ: 経路の列車に時刻表どおりに乗って動き、判定・「予定どおり」・降りる駅の通知が出ること
    func testRideAlongJourneyTriggersAlertOnce() throws {
        let line = RideLine(railwayID: "x", name: "X線", stations: (0..<5).map { index in
            (id: "s\(index)", name: "S\(index)", point: GeoMath.offset(origin, east: Double(index) * 1000, north: 0))
        })
        // 駅の間は90秒(時速40km)、各駅で30秒停車
        var stops = [JourneyStop(stationID: "s0", name: "S0", arrival: base, departure: base)]
        for index in 1..<5 {
            let arrival = base.addingTimeInterval(Double(index) * 120 - 30)
            stops.append(JourneyStop(stationID: "s\(index)", name: "S\(index)", arrival: arrival,
                                     departure: index == 4 ? arrival : arrival.addingTimeInterval(30)))
        }
        let journey = Journey(legs: [JourneyLeg(tripID: "t1", railwayID: "x", railwayName: "X線", trainNumber: "1", trainType: "普通",
                                                destination: "S4", direction: "up", stops: stops)])
        let motion = JourneyMotion(journey: journey, lines: [line]) { _ in nil }
        var detector = RideDetector()
        var alerted: Set<Int> = []
        var alertTimes: [TimeInterval] = []
        var sawOnPlan = false
        for second in -60...500 {
            let time = base.addingTimeInterval(Double(second))
            let point = try XCTUnwrap(motion.position(at: time))
            let along = try XCTUnwrap(line.path.project(point)).along
            let ahead = line.stationsAhead(of: along, ascending: true)
            let train = RideTrainCandidate(id: "t1", railwayID: "x", number: "1", trainType: "普通", destination: "S4", delay: .timetable,
                                           along: along, isAscending: true, isStopped: false,
                                           upcoming: ahead.map { RideTrainCandidate.Stop(stationID: $0.stationID, name: $0.name, arrival: time, along: $0.along) })
            let context = RideContext(lines: [line], trains: [train])
            let judgement = detector.add(RideSample(time: time, point: point, accuracy: 10), context: context)
            if JourneyTracking.status(journey: journey, judgement: judgement) == .onPlan(leg: 0) { sawOnPlan = true }
            let next = RideInfo.nextStationID(judgement: judgement, lines: [line], trains: [train])
            if let leg = JourneyTracking.alightAlert(journey: journey, judgement: judgement, nextStationID: next, alerted: alerted) {
                alerted.insert(leg)
                alertTimes.append(Double(second))
            }
        }
        XCTAssertTrue(sawOnPlan)
        XCTAssertEqual(alertTimes.count, 1)
        // S3 に着いて(次が降りる駅 S4 になって)から、S3 を出るまでの間に知らせる
        let at = try XCTUnwrap(alertTimes.first)
        XCTAssertGreaterThanOrEqual(at, 3 * 120 - 30 - 1)
        XCTAssertLessThanOrEqual(at, 3 * 120 + 5)
    }
}

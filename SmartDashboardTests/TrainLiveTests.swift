import CoreLocation
import XCTest
@testable import SmartDashboard

/// 列車ごとの時刻表からの位置の計算(駅間の補間、遅れの補正、方面の判定、0時またぎ)
final class TrainPositionTests: XCTestCase {
    private let northbound = "odpt.RailDirection:Northbound"
    private let southbound = "odpt.RailDirection:Southbound"

    /// 実データ(都営浅草線。平日の北行・南行・0時またぎ、土休日1本)から作る。駅の番号は最初の列車に出てくる順。
    private func schedule() throws -> LineSchedule {
        let tables = try ODPTClient.decode([ODPTTrainTimetable].self, from: Fixture.data("odpt_train_timetable"))
        XCTAssertEqual(tables.count, 4)
        return LineSchedule(railwayID: "odpt.Railway:Toei.Asakusa", downloadedAt: Date(), orderedStationIDs: [], timetables: tables,
                            trainTypeNames: ["odpt.TrainType:Toei.Local": "普通"],
                            stationNames: ["odpt.Station:Toei.Asakusa.NishiMagome": "西馬込"])
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        JapaneseHolidays.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    func testScheduleIsBuiltFromRealResponse() throws {
        let schedule = try schedule()
        XCTAssertEqual(schedule.trains.map(\.number), ["1029N", "1008T", "2208T", "1981K"])
        XCTAssertEqual(schedule.stationIDs.count, 20)
        XCTAssertEqual(schedule.stationIDs.first, "odpt.Station:Toei.Asakusa.NishiMagome")
        XCTAssertEqual(schedule.stationIDs.last, "odpt.Station:Toei.Asakusa.Oshiage")
        let first = schedule.trains[0]
        XCTAssertEqual(first.direction, northbound)
        XCTAssertEqual(first.trainType, "普通")
        XCTAssertEqual(first.destination, "ImbaNihonIdai")
        XCTAssertEqual(first.stops.first, LineSchedule.Stop(station: 0, arrival: nil, departure: 10 * 60 + 54))
        XCTAssertEqual(first.stops[1], LineSchedule.Stop(station: 1, arrival: 10 * 60 + 55, departure: 10 * 60 + 56))
        XCTAssertEqual(schedule.trains[1].destination, "西馬込")

        // 0時をまたぐ列車は、1440分以降として続ける
        let late = schedule.trains[2]
        XCTAssertEqual(late.stops.first?.departure, 23 * 60 + 33)
        XCTAssertEqual(late.stops.last?.arrival, 24 * 60 + 11)
        XCTAssertEqual(late.stops.map(\.arrivalMinute), late.stops.map(\.arrivalMinute).sorted())

        // 保存して読み直せる
        let again = try JSONDecoder().decode(LineSchedule.self, from: JSONEncoder().encode(schedule))
        XCTAssertEqual(again, schedule)
        XCTAssertFalse(schedule.isExpired(now: schedule.downloadedAt.addingTimeInterval(29 * 86400)))
        XCTAssertTrue(schedule.isExpired(now: schedule.downloadedAt.addingTimeInterval(31 * 86400)))
    }

    func testInterpolatesBetweenStations() throws {
        let schedule = try schedule()
        // 2026-09-17(木)は平日。1029N は西馬込 10:54 発、馬込 10:55 着。
        let positions = TrainPositionCalculator.positions(in: schedule, now: date(2026, 9, 17, 10, 54, 42))
        XCTAssertEqual(positions.count, 1)
        let train = try XCTUnwrap(positions.first)
        XCTAssertEqual(train.number, "1029N")
        XCTAssertEqual(train.fromStation, 0)
        XCTAssertEqual(train.toStation, 1)
        XCTAssertFalse(train.isStopped)
        XCTAssertEqual(train.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(train.delay, .timetable)
        XCTAssertEqual(train.upcoming.first?.station, 1)
        XCTAssertEqual(train.upcoming.first?.arrival, date(2026, 9, 17, 10, 55))
        XCTAssertEqual(train.upcoming.count, 19)
    }

    func testStoppedAtStation() throws {
        let schedule = try schedule()
        let train = try XCTUnwrap(TrainPositionCalculator.positions(in: schedule, now: date(2026, 9, 17, 10, 55, 30)).first)
        XCTAssertTrue(train.isStopped)
        XCTAssertEqual(train.fromStation, 1)
        XCTAssertEqual(train.toStation, 2)
        XCTAssertEqual(train.fraction, 0)
        XCTAssertEqual(train.upcoming.first?.station, 2)
    }

    func testDelayShiftsPositionAndArrival() throws {
        let schedule = try schedule()
        // 2分遅れなら、10:57:30 の位置は時刻表の 10:55:30 の位置(馬込に停車中)と同じ
        let now = date(2026, 9, 17, 10, 57, 30)
        let onTime = try XCTUnwrap(TrainPositionCalculator.positions(in: schedule, now: now).first)
        XCTAssertEqual(onTime.fromStation, 2)
        let delayed = try XCTUnwrap(TrainPositionCalculator.positions(in: schedule, now: now, delays: ["1029N": 120]).first)
        XCTAssertEqual(delayed.delay, .realtime(120))
        XCTAssertTrue(delayed.isStopped)
        XCTAssertEqual(delayed.fromStation, 1)
        // 到着予定も遅れの分だけ後ろにずれる(中延 10:57 着 → 10:59)
        XCTAssertEqual(delayed.upcoming.first?.arrival, date(2026, 9, 17, 10, 59))
        XCTAssertEqual(delayed.delay.label, "遅れ2分(リアルタイム)")
        XCTAssertEqual(delayed.delay.tone, .delayed)
        // 対応する遅れがなく、路線に遅延があるとき
        let unknown = try XCTUnwrap(TrainPositionCalculator.positions(in: schedule, now: now, delays: ["9999X": 300], lineIsDelayed: true).first)
        XCTAssertEqual(unknown.delay, .lineDelayed)
        XCTAssertEqual(unknown.fromStation, 2)
        XCTAssertEqual(unknown.delay.tone, .unknown)
        XCTAssertEqual(DelaySource.realtime(0).label, "遅れなし(リアルタイム)")
        XCTAssertEqual(DelaySource.realtime(0).tone, .onTime)
        XCTAssertEqual(DelaySource.timetable.label, "時刻表どおり")
    }

    func testAfterMidnightUsesPreviousServiceDay() throws {
        let schedule = try schedule()
        // 2208T は木曜 23:33 発、高輪台に 0:00 着・0:01 発。金曜 0:00:30 には高輪台に停車中。
        let positions = TrainPositionCalculator.positions(in: schedule, now: date(2026, 9, 18, 0, 0, 30))
        XCTAssertEqual(positions.map(\.number), ["2208T"])
        let train = try XCTUnwrap(positions.first)
        XCTAssertTrue(train.isStopped)
        XCTAssertEqual(schedule.stationIDs[train.fromStation], "odpt.Station:Toei.Asakusa.Takanawadai")
        XCTAssertEqual(train.upcoming.last?.arrival, date(2026, 9, 18, 0, 11))
        // 終点に着いたあとは出てこない
        XCTAssertTrue(TrainPositionCalculator.positions(in: schedule, now: date(2026, 9, 18, 0, 12)).isEmpty)
    }

    func testCalendarFollowsDayType() throws {
        let schedule = try schedule()
        // 2026-09-19(土)は土休日ダイヤ。1981K は馬込 19:41 発、中延 19:43 着。
        let saturday = TrainPositionCalculator.positions(in: schedule, now: date(2026, 9, 19, 19, 42))
        XCTAssertEqual(saturday.map(\.number), ["1981K"])
        XCTAssertEqual(saturday.first?.fraction ?? -1, 0.375, accuracy: 0.001)
        // 同じ時刻でも平日には走っていない
        XCTAssertTrue(TrainPositionCalculator.positions(in: schedule, now: date(2026, 9, 17, 19, 42)).isEmpty)
        // 手動で土休日ダイヤに切り替えた平日
        let thursday = date(2026, 9, 17, 19, 42)
        let resolver = DayTypeResolver(overrideDayKey: DayTypeResolver.dayKey(thursday), overrideType: .holiday)
        XCTAssertEqual(TrainPositionCalculator.positions(in: schedule, now: thursday, resolver: resolver).map(\.number), ["1981K"])
    }

    func testApproachesFilterByDirectionAndStation() throws {
        let schedule = try schedule()
        let now = date(2026, 9, 17, 10, 54, 42)
        let positions = TrainPositionCalculator.positions(in: schedule, now: now)
        let sengakuji = try XCTUnwrap(schedule.stationIDs.firstIndex(of: "odpt.Station:Toei.Asakusa.Sengakuji"))
        let approaches = TrainPositionCalculator.approaches(to: sengakuji, direction: northbound, positions: positions, now: now)
        XCTAssertEqual(approaches.count, 1)
        XCTAssertEqual(approaches.first?.arrival, date(2026, 9, 17, 11, 6))
        XCTAssertEqual(approaches.first?.stopsAway, 6)
        XCTAssertEqual(TrainBoard.approachText(try XCTUnwrap(approaches.first), now: now), "あと12分で到着・5駅前")
        // 逆の方面や、すでに通り過ぎた駅には出てこない
        XCTAssertTrue(TrainPositionCalculator.approaches(to: sengakuji, direction: southbound, positions: positions, now: now).isEmpty)
        XCTAssertTrue(TrainPositionCalculator.approaches(to: 0, direction: northbound, positions: positions, now: now).isEmpty)
        XCTAssertEqual(TrainPositionCalculator.directions(in: schedule), [northbound, southbound])
    }

    func testWaitingTrainsAreIncludedOnlyOnRequest() throws {
        let schedule = try schedule()
        let now = date(2026, 9, 17, 10, 40)
        XCTAssertTrue(TrainPositionCalculator.positions(in: schedule, now: now).isEmpty)
        // 30分以内に発車する列車だけ(1029N は 10:54 発、1008T は 11:31 発)
        let waiting = TrainPositionCalculator.positions(in: schedule, now: now, includesWaiting: true)
        XCTAssertEqual(waiting.map(\.number), ["1029N"])
        XCTAssertEqual(waiting.first?.isWaitingToDepart, true)
        XCTAssertEqual(waiting.first?.fromStation, 0)
        XCTAssertEqual(waiting.first?.upcoming.first?.station, 1)
    }
}

final class TrainLiveLogicTests: XCTestCase {
    func testParsesDelaysFromRealResponse() throws {
        let response = try ODPTClient.decode([ODPTTrain].self, from: Fixture.data("odpt_train"))
        XCTAssertEqual(response.count, 3)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let parsed = TrainLiveStore.parseDelays(response, railwayIDs: ["odpt.Railway:Toei.Oedo", "odpt.Railway:Toei.NipporiToneri"], now: now)
        XCTAssertEqual(parsed.support["odpt.Railway:Toei.Oedo"], true)
        // 応答に列車がない路線は「列車ごとの遅れは取れない」
        XCTAssertEqual(parsed.support["odpt.Railway:Toei.NipporiToneri"], false)
        let oedo = try XCTUnwrap(parsed.delays["odpt.Railway:Toei.Oedo"])
        XCTAssertEqual(oedo["2116A"]?.seconds, 60)
        XCTAssertEqual(oedo["2028B"]?.seconds, 0)
        XCTAssertEqual(oedo["2116A"]?.direction, "odpt.RailDirection:InnerLoop")
        // dct:valid (2026-09-19T21:42:29+09:00) まで有効
        XCTAssertEqual(oedo["2116A"]?.validUntil, ISO8601DateFormatter().date(from: "2026-09-19T21:42:29+09:00"))
    }

    func testTrainsWithoutDelayFieldAreNotSupported() throws {
        // 都電荒川線のように、odpt:Train はあるが odpt:delay がない場合
        let json = """
        [{"odpt:trainNumber":"ODPT3722","odpt:railway":"odpt.Railway:Toei.Arakawa","odpt:railDirection":"odpt.RailDirection:Toei.Waseda",
          "dc:date":"2026-09-19T21:37:38+09:00","dct:valid":"2026-09-19T21:42:38+09:00","odpt:fromStation":"x","odpt:toStation":null}]
        """
        let response = try ODPTClient.decode([ODPTTrain].self, from: Data(json.utf8))
        let parsed = TrainLiveStore.parseDelays(response, railwayIDs: ["odpt.Railway:Toei.Arakawa"], now: Date())
        XCTAssertEqual(parsed.support["odpt.Railway:Toei.Arakawa"], false)
        XCTAssertTrue(parsed.delays.isEmpty)
    }

    func testDelayFetchInterval() {
        let wifi = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: false, isWiFi: true)
        let cellular = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: false, isWiFi: false)
        let lowData = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: true, isWiFi: false)
        XCTAssertEqual(RefreshPolicy.trainDelayInterval(network: wifi), 120)
        XCTAssertEqual(RefreshPolicy.trainDelayInterval(network: cellular), 300)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = RefreshPolicy(wifiOnly: false)
        XCTAssertEqual(policy.autoDecision(kind: .trainDelay, fetchedAt: now.addingTimeInterval(-60), now: now, network: wifi), .fresh)
        XCTAssertEqual(policy.autoDecision(kind: .trainDelay, fetchedAt: now.addingTimeInterval(-130), now: now, network: wifi), .refresh)
        // 省データモードと、月のモバイル通信量の上限を超えたときは自動取得しない
        XCTAssertEqual(policy.autoDecision(kind: .trainDelay, fetchedAt: nil, now: now, network: lowData), .blockedByConstrained)
        XCTAssertEqual(RefreshPolicy(wifiOnly: false, cellularLimitReached: true)
            .autoDecision(kind: .trainDelay, fetchedAt: nil, now: now, network: cellular), .blockedByCellularLimit)
    }

    func testTypeBadge() {
        XCTAssertEqual(TrainBoard.typeBadge("普通").label, "")
        XCTAssertFalse(TrainBoard.typeBadge("各停").isExpress)
        XCTAssertEqual(TrainBoard.typeBadge("エアポート快特").label, "快特")
        XCTAssertEqual(TrainBoard.typeBadge("アクセス特急").label, "特")
        XCTAssertEqual(TrainBoard.typeBadge("急行").label, "急")
        XCTAssertTrue(TrainBoard.typeBadge("急行").isExpress)
        XCTAssertEqual(TrainBoard.typeBadge("通勤準急").label, "通")
    }

    private func position(from: Int, to: Int, fraction: Double, upcoming: [Int] = []) -> TrainPosition {
        TrainPosition(id: "t", number: "t", direction: "d", trainType: "普通", destination: "x", delay: .timetable,
                      fromStation: from, toStation: to, fraction: fraction, isStopped: fraction == 0, isWaitingToDepart: false,
                      upcoming: upcoming.map { TrainPosition.UpcomingStop(station: $0, arrival: Date()) })
    }

    func testDiagramPositionAndSide() throws {
        let ids = ["A", "B", "C", "D"]
        let line = BoardLine(railwayID: "r", name: "r", schedule: LineSchedule(railwayID: "r", downloadedAt: Date(), stationIDs: ids, trains: []),
                             shape: nil, positions: [])
        let down = try XCTUnwrap(TrainBoard.diagramPosition(of: position(from: 1, to: 2, fraction: 0.25), in: line, order: ids))
        XCTAssertEqual(down.value, 1.25, accuracy: 0.001)
        XCTAssertTrue(down.isAscending)
        let up = try XCTUnwrap(TrainBoard.diagramPosition(of: position(from: 3, to: 2, fraction: 0.5), in: line, order: ids))
        XCTAssertEqual(up.value, 2.5, accuracy: 0.001)
        XCTAssertFalse(up.isAscending)
        // 環状線のように同じ駅が2回出てくるときは、近いほうを選ぶ(D → A は 3 → 4)
        let loop = ["A", "B", "C", "D", "A"]
        let wrapped = try XCTUnwrap(TrainBoard.diagramPosition(of: position(from: 3, to: 0, fraction: 0.5), in: line, order: loop))
        XCTAssertEqual(wrapped.value, 3.5, accuracy: 0.001)
        XCTAssertTrue(wrapped.isAscending)
        // 終点に着いた列車は、来た方向の側に描く
        let arrived = try XCTUnwrap(TrainBoard.diagramPosition(of: position(from: 3, to: 3, fraction: 0), in: line, order: ids))
        XCTAssertTrue(arrived.isAscending)
        let arrivedAtStart = try XCTUnwrap(TrainBoard.diagramPosition(of: position(from: 0, to: 0, fraction: 0), in: line, order: ids))
        XCTAssertFalse(arrivedAtStart.isAscending)
    }

    func testMapCoordinateAndBearing() throws {
        let shape = RailwayShape(railwayID: "r", colorHex: nil, stops: [
            RailwayShape.Stop(stationID: "A", name: "A", latitude: 35.0, longitude: 139.0),
            RailwayShape.Stop(stationID: "B", name: "B", latitude: 35.1, longitude: 139.0),
        ], missingStationIDs: [])
        let line = BoardLine(railwayID: "r", name: "r", schedule: LineSchedule(railwayID: "r", downloadedAt: Date(), stationIDs: ["A", "B"], trains: []),
                             shape: shape, positions: [])
        let north = try XCTUnwrap(TrainBoard.coordinate(of: position(from: 0, to: 1, fraction: 0.25), in: line))
        XCTAssertEqual(north.coordinate.latitude, 35.025, accuracy: 0.0001)
        XCTAssertEqual(north.heading ?? -1, 0, accuracy: 0.01)
        let south = try XCTUnwrap(TrainBoard.coordinate(of: position(from: 1, to: 0, fraction: 0.5), in: line))
        XCTAssertEqual(south.heading ?? -1, 180, accuracy: 0.01)
        XCTAssertEqual(MapBearing.degrees(from: CLLocationCoordinate2D(latitude: 35, longitude: 139), to: CLLocationCoordinate2D(latitude: 35, longitude: 139.1)) ?? -1, 90, accuracy: 0.1)
        XCTAssertNil(MapBearing.degrees(from: CLLocationCoordinate2D(latitude: 35, longitude: 139), to: CLLocationCoordinate2D(latitude: 35, longitude: 139)))
        XCTAssertEqual(line.stationName(1), "B")
    }

    func testStationNamesByZoomAndNearestStation() {
        // 広域では主要駅だけ
        XCTAssertFalse(MapStationRule.showsName(zoom: 9, isMajor: true))
        XCTAssertTrue(MapStationRule.showsName(zoom: 11, isMajor: true))
        XCTAssertFalse(MapStationRule.showsName(zoom: 11, isMajor: false))
        XCTAssertTrue(MapStationRule.showsName(zoom: 13, isMajor: false))

        let shape = RailwayShape(railwayID: "r", colorHex: nil, stops: [
            RailwayShape.Stop(stationID: "A", name: "A駅", latitude: 35.0, longitude: 139.0),
            RailwayShape.Stop(stationID: "B", name: "B駅", latitude: 35.01, longitude: 139.0),
            RailwayShape.Stop(stationID: "C", name: "C駅", latitude: 35.02, longitude: 139.0),
        ], missingStationIDs: [])
        let nearest = TrainLiveStore.nearestStation(to: CLLocation(latitude: 35.011, longitude: 139.0), shapes: [shape])
        XCTAssertEqual(nearest?.stationID, "B")
        XCTAssertEqual(nearest?.distance ?? -1, 111, accuracy: 3)
        XCTAssertNil(TrainLiveStore.nearestStation(to: CLLocation(latitude: 35, longitude: 139), shapes: []))

        let dots = TrainMapBuilder.stationDots(shapes: [shape], registered: ["B"], nearestStationID: nil)
        XCTAssertEqual(dots.map(\.isMajor), [true, true, true])
        let plain = TrainMapBuilder.stationDots(shapes: [shape], registered: [], nearestStationID: nil)
        XCTAssertEqual(plain.map(\.isMajor), [true, false, true])
        XCTAssertEqual(plain.map(\.isRegistered), [false, false, false])
    }
}

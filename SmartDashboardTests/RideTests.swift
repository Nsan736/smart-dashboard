import CoreLocation
import XCTest
@testable import SmartDashboard

/// 決まった順に値を返す乱数(テスト用)
private struct RideTestGenerator: RandomNumberGenerator {
    var state: UInt64 = 0xDEAD_BEEF_1234_5678

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// 線への投影、乗車中の判定、GPSが途切れたときの推定
final class RideDetectionTests: XCTestCase {
    private let origin = GeoPoint(35.68, 139.76)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 東西にまっすぐな路線。A駅(0m)、B駅(3000m)、C駅(6000m)
    private func straightLine() -> RideLine {
        RideLine(railwayID: "r", name: "テスト線", stations: [
            (id: "A", name: "A駅", point: origin),
            (id: "B", name: "B駅", point: GeoMath.offset(origin, east: 3000, north: 0)),
            (id: "C", name: "C駅", point: GeoMath.offset(origin, east: 6000, north: 0)),
        ])
    }

    /// L字に曲がる路線。A駅(0m)から東へ2000mでB駅、そこから北へ2000mでC駅
    private func curvedLine() -> RideLine {
        RideLine(railwayID: "c", name: "カーブ線", stations: [
            (id: "A", name: "A駅", point: origin),
            (id: "B", name: "B駅", point: GeoMath.offset(origin, east: 2000, north: 0)),
            (id: "C", name: "C駅", point: GeoMath.offset(origin, east: 2000, north: 2000)),
        ])
    }

    /// 線の上の位置から、北へ north m ずらした点
    private func sample(_ line: RideLine, along: Double, north: Double = 0, second: Double, accuracy: Double = 10) -> RideSample {
        let point = line.path.point(atAlong: along)!
        return RideSample(time: start.addingTimeInterval(second), point: GeoMath.offset(point, east: 0, north: north), accuracy: accuracy)
    }

    private func train(_ id: String, railway: String = "r", along: Double, ascending: Bool?) -> RideTrainCandidate {
        RideTrainCandidate(id: id, railwayID: railway, number: id, trainType: "普通", destination: "終点", delay: .timetable,
                           along: along, isAscending: ascending, isStopped: false, upcoming: [])
    }

    // MARK: - 線への投影

    func testProjectionOnStraightAndCurvedLines() throws {
        let line = straightLine()
        XCTAssertEqual(line.path.length, 6000, accuracy: 1)
        XCTAssertEqual(line.stations.map(\.along)[1], 3000, accuracy: 1)
        let point = GeoMath.offset(origin, east: 1200, north: 35)
        let projection = try XCTUnwrap(line.path.project(point))
        XCTAssertEqual(projection.along, 1200, accuracy: 1)
        XCTAssertEqual(projection.lateral, 35, accuracy: 0.5)
        XCTAssertEqual(projection.segment, 0)
        // 線の外側(始点より手前)は、始点に投影する
        let before = try XCTUnwrap(line.path.project(GeoMath.offset(origin, east: -100, north: 0)))
        XCTAssertEqual(before.along, 0, accuracy: 0.01)
        XCTAssertEqual(before.lateral, 100, accuracy: 0.5)

        // カーブ: 2本目の区間(北向き)の上
        let curve = curvedLine()
        let onSecond = try XCTUnwrap(curve.path.project(GeoMath.offset(origin, east: 2020, north: 700)))
        XCTAssertEqual(onSecond.along, 2700, accuracy: 1)
        XCTAssertEqual(onSecond.lateral, 20, accuracy: 0.5)
        XCTAssertEqual(onSecond.segment, 1)
        // 線に沿った距離の位置と、部分の切り出し
        let back = try XCTUnwrap(curve.path.point(atAlong: 2700))
        XCTAssertEqual(GeoMath.distance(back, GeoMath.offset(origin, east: 2000, north: 700)), 0, accuracy: 0.5)
        let part = curve.path.subpath(from: 1500, to: 2500)
        XCTAssertEqual(part.count, 3)
        XCTAssertEqual(GeoPath(part).length, 1000, accuracy: 1)

        XCTAssertEqual(curve.stationsAhead(of: 1000, ascending: true).map(\.name), ["B駅", "C駅"])
        XCTAssertEqual(curve.stationsAhead(of: 1000, ascending: false).map(\.name), ["A駅"])
        XCTAssertEqual(curve.terminalName(ascending: false), "A駅")
    }

    // MARK: - 判定(直線)

    func testStraightRideNeedsDurationAndMatchesTrainInSameDirection() throws {
        let line = straightLine()
        var detector = RideDetector()
        var judgement = RideJudgement()
        for second in 0...45 {
            let along = 200 + 16.0 * Double(second)
            let trains = [
                train("ahead", along: along + 150, ascending: true),
                // 一番近いが、向きが逆
                train("opposite", along: along - 40, ascending: false),
                train("far", along: along + 2500, ascending: true),
            ]
            judgement = detector.add(sample(line, along: along, north: 12, second: Double(second)),
                                     context: RideContext(lines: [line], trains: trains))
            if second == 3 { XCTAssertEqual(judgement.state, .idle) }
            // 条件は5秒目から。30秒たつまでは判定を出さない
            if second == 25 { XCTAssertEqual(judgement.state, .candidate) }
            if second == 34 { XCTAssertEqual(judgement.state, .candidate) }
        }
        XCTAssertEqual(judgement.state, .riding)
        XCTAssertEqual(judgement.railwayID, "r")
        XCTAssertEqual(judgement.isAscending, true)
        XCTAssertEqual(judgement.trainID, "ahead")
        XCTAssertEqual(try XCTUnwrap(judgement.trainDistance), 150, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(judgement.debug.lateral), 12, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(judgement.debug.alongSpeed), 16, accuracy: 0.5)
        XCTAssertEqual(judgement.confidence, .medium)
        XCTAssertEqual(judgement.debug.candidates.map(\.trainID), ["ahead", "far"])

        // 手動で選び直せる
        detector.selectTrain("far")
        var manual = detector.tick(now: start.addingTimeInterval(46), context: RideContext(lines: [line], trains: [
            train("ahead", along: 1100, ascending: true), train("far", along: 3500, ascending: true),
        ]))
        XCTAssertEqual(manual.trainID, "far")
        XCTAssertTrue(manual.isManual)
        detector.selectTrain(nil)
        manual = detector.tick(now: start.addingTimeInterval(47), context: RideContext(lines: [line], trains: [
            train("ahead", along: 1100, ascending: true), train("far", along: 3500, ascending: true),
        ]))
        XCTAssertEqual(manual.trainID, "ahead")
        XCTAssertFalse(manual.isManual)
    }

    func testSlowOrFarMovementIsNotRide() throws {
        let line = straightLine()
        // 歩く速さ(時速5km)
        var walking = RideDetector()
        var judgement = RideJudgement()
        for second in 0...60 {
            judgement = walking.add(sample(line, along: 100 + 1.4 * Double(second), second: Double(second)),
                                    context: RideContext(lines: [line], trains: []))
        }
        XCTAssertEqual(judgement.state, .idle)
        // 線から150m離れた道を、時速60kmで走る
        var far = RideDetector()
        for second in 0...60 {
            judgement = far.add(sample(line, along: 100 + 16.0 * Double(second), north: 150, second: Double(second)),
                                context: RideContext(lines: [line], trains: []))
        }
        XCTAssertEqual(judgement.state, .idle)
        XCTAssertEqual(try XCTUnwrap(judgement.debug.lateral), 150, accuracy: 1)
    }

    // MARK: - 判定(カーブ)

    func testCurveKeepsAlongDistanceAndDirection() throws {
        let line = curvedLine()
        var detector = RideDetector()
        var judgement = RideJudgement()
        for second in 0...60 {
            let along = 1500 + 16.0 * Double(second)
            judgement = detector.add(sample(line, along: along, north: 8, second: Double(second)),
                                     context: RideContext(lines: [line], trains: [train("t", railway: "c", along: along + 300, ascending: true)]))
        }
        // 角(2000m)を過ぎても、線に沿った距離は続けて増える
        XCTAssertEqual(judgement.state, .riding)
        XCTAssertEqual(judgement.isAscending, true)
        XCTAssertEqual(try XCTUnwrap(judgement.along), 2468, accuracy: 20)
        XCTAssertLessThan(try XCTUnwrap(judgement.debug.lateral), 10)
        XCTAssertEqual(judgement.trainID, "t")

        // 逆向き(C駅からA駅へ)。近い列車でも、向きが違えば選ばない
        var reverse = RideDetector()
        for second in 0...60 {
            let along = 2600 - 16.0 * Double(second)
            judgement = reverse.add(sample(line, along: along, second: Double(second)), context: RideContext(lines: [line], trains: [
                train("up", railway: "c", along: along - 100, ascending: true),
                train("down", railway: "c", along: along - 400, ascending: false),
            ]))
        }
        XCTAssertEqual(judgement.state, .riding)
        XCTAssertEqual(judgement.isAscending, false)
        XCTAssertEqual(judgement.trainID, "down")
    }

    // MARK: - 線路と並行する道路(車)

    func testCarOnParallelRoadIsRejectedAfterStoppingAwayFromStations() throws {
        let line = straightLine()
        var detector = RideDetector()
        var judgement = RideJudgement()
        var along = 500.0
        var beforeStop: RideJudgement?
        for second in 0...150 {
            // 時速40kmで走り、40〜80秒は信号で止まる(駅から離れた場所)
            if !(40..<80).contains(second), second > 0 { along += 11.1 }
            judgement = detector.add(sample(line, along: along, north: 60, second: Double(second)),
                                     context: RideContext(lines: [line], trains: []))
            if second == 39 { beforeStop = judgement }
        }
        // 止まる前は「可能性あり」になるが、線から遠く、列車とも照合できないので確からしさは低い
        let early = try XCTUnwrap(beforeStop)
        XCTAssertEqual(early.state, .riding)
        XCTAssertEqual(early.confidence, .low)
        XCTAssertNil(early.trainID)
        // 駅以外で止まったあとは、駅での停止を見るまで判定を出さない
        XCTAssertEqual(judgement.debug.offStationStops, 1)
        XCTAssertEqual(judgement.debug.stationStops, 0)
        XCTAssertEqual(judgement.state, .candidate)
        XCTAssertTrue(judgement.note?.contains("駅での停止") ?? false)
    }

    // MARK: - 駅での停車

    func testStationStopKeepsRideAndRaisesConfidence() throws {
        let line = straightLine()
        var detector = RideDetector()
        var judgement = RideJudgement()
        var along = 2000.0
        var lost = false
        for second in 0...150 {
            // B駅(3000m)で40秒止まる
            if second > 0 {
                if along < 3000 { along = min(3000, along + 16) } else if second >= 103 { along += 16 }
            }
            judgement = detector.add(sample(line, along: along, north: 5, second: Double(second)),
                                     context: RideContext(lines: [line], trains: [train("t", along: along + 80, ascending: true)]))
            if second >= 35, judgement.state != .riding { lost = true }
        }
        XCTAssertFalse(lost, "駅で止まっている間も、判定は続く")
        XCTAssertEqual(judgement.debug.stationStops, 1)
        XCTAssertEqual(judgement.debug.offStationStops, 0)
        XCTAssertEqual(judgement.trainID, "t")
        XCTAssertEqual(judgement.confidence, .high)
    }

    // MARK: - GPSが途切れたとき

    func testEstimatesWithTimetableWhileGPSIsLost() throws {
        let line = straightLine()
        var detector = RideDetector()
        func userAlong(_ second: Double) -> Double { 300 + 15 * second }
        func context(_ second: Double) -> RideContext {
            RideContext(lines: [line], trains: [train("t", along: userAlong(second) + 100, ascending: true)])
        }
        for second in 0...50 {
            detector.add(sample(line, along: userAlong(Double(second)), second: Double(second)), context: context(Double(second)))
        }
        XCTAssertEqual(detector.judgement.state, .riding)
        // 地下に入り、位置が届かない。20秒までは、そのまま
        var judgement = detector.tick(now: start.addingTimeInterval(65), context: context(65))
        XCTAssertEqual(judgement.state, .riding)
        judgement = detector.tick(now: start.addingTimeInterval(80), context: context(80))
        XCTAssertEqual(judgement.state, .estimating)
        XCTAssertEqual(judgement.trainID, "t")
        XCTAssertEqual(try XCTUnwrap(judgement.along), userAlong(80) + 100, accuracy: 0.1)
        XCTAssertTrue(judgement.isRiding)
        // 位置が戻ったら答え合わせをして、判定を続ける
        judgement = detector.tick(now: start.addingTimeInterval(95), context: context(95))
        judgement = detector.add(sample(line, along: userAlong(96), second: 96), context: context(96))
        XCTAssertEqual(judgement.state, .riding)
        // 推定(95秒の列車の位置 = 自分より100m先)と、96秒の実際の位置との差
        XCTAssertEqual(try XCTUnwrap(judgement.answerCheck), 85, accuracy: 2)
        XCTAssertEqual(judgement.trainID, "t")
    }

    func testGPSLossWithoutTrainEndsRide() {
        let line = straightLine()
        var detector = RideDetector()
        for second in 0...50 {
            detector.add(sample(line, along: 300 + 15 * Double(second), second: Double(second)), context: RideContext(lines: [line], trains: []))
        }
        XCTAssertEqual(detector.judgement.state, .riding)
        let judgement = detector.tick(now: start.addingTimeInterval(80), context: RideContext(lines: [line], trains: []))
        XCTAssertEqual(judgement.state, .idle)
        XCTAssertNotNil(judgement.note)
    }

    func testInaccurateFixesAreIgnored() {
        let line = straightLine()
        var detector = RideDetector()
        var judgement = RideJudgement()
        for second in 0...50 {
            judgement = detector.add(sample(line, along: 300 + 15 * Double(second), second: Double(second), accuracy: 200),
                                     context: RideContext(lines: [line], trains: []))
        }
        XCTAssertEqual(judgement.state, .idle)
    }

    // MARK: - 列車の位置を線に沿った距離に直す

    func testTrainCandidateFromTimetablePosition() throws {
        let line = straightLine()
        let schedule = LineSchedule(railwayID: "r", downloadedAt: Date(), stationIDs: ["A", "B", "C"], trains: [])
        let board = BoardLine(railwayID: "r", name: "テスト線", schedule: schedule, shape: nil, positions: [])
        let arrival = start.addingTimeInterval(120)
        let forward = TrainPosition(id: "1", number: "1", direction: "d", trainType: "急行", destination: "C駅", delay: .realtime(60),
                                    fromStation: 0, toStation: 1, fraction: 0.5, isStopped: false, isWaitingToDepart: false,
                                    upcoming: [.init(station: 1, arrival: arrival), .init(station: 2, arrival: arrival.addingTimeInterval(180))])
        let candidate = try XCTUnwrap(RideTrainCandidate.make(position: forward, line: board, ride: line))
        XCTAssertEqual(candidate.along, 1500, accuracy: 1)
        XCTAssertEqual(candidate.isAscending, true)
        XCTAssertEqual(candidate.upcoming.map(\.name), [board.stationName(1), board.stationName(2)])
        XCTAssertEqual(try XCTUnwrap(candidate.upcoming.first?.along), 3000, accuracy: 1)
        XCTAssertEqual(candidate.label, "急行 C駅行")

        let backward = TrainPosition(id: "2", number: "2", direction: "u", trainType: "", destination: "", delay: .timetable,
                                     fromStation: 2, toStation: 1, fraction: 0.25, isStopped: false, isWaitingToDepart: false, upcoming: [])
        let back = try XCTUnwrap(RideTrainCandidate.make(position: backward, line: board, ride: line))
        XCTAssertEqual(back.along, 5250, accuracy: 1)
        XCTAssertEqual(back.isAscending, false)
        // 始発駅で発車を待っている列車は、照合に使わない
        var waiting = forward
        waiting.isWaitingToDepart = true
        XCTAssertNil(RideTrainCandidate.make(position: waiting, line: board, ride: line))
    }

    func testRideInfoShowsNextStopsAndRegisteredStation() {
        let line = straightLine()
        var judgement = RideJudgement(state: .riding)
        judgement.railwayID = "r"
        judgement.along = 1000
        judgement.isAscending = true
        judgement.trainID = "t"
        judgement.debug.alongSpeed = 15
        let arrival = start.addingTimeInterval(100)
        var candidate = train("t", along: 1000, ascending: true)
        candidate.destination = "C駅"
        candidate.upcoming = [
            .init(stationID: "B", name: "B駅", arrival: arrival, along: 3000),
            .init(stationID: "C", name: "C駅", arrival: arrival.addingTimeInterval(200), along: 6000),
        ]
        let info = RideInfo.make(judgement: judgement, lines: [line], trains: [candidate], registeredStationIDs: ["C"])
        XCTAssertEqual(info.railwayName, "テスト線")
        XCTAssertEqual(info.directionText, "C駅行")
        XCTAssertEqual(info.nextStops.map(\.name), ["B駅", "C駅"])
        XCTAssertEqual(info.nextStopDistance ?? 0, 2000, accuracy: 0.1)
        XCTAssertEqual(info.targets, [RideInfo.Target(name: "C駅", stopsAway: 2, arrival: arrival.addingTimeInterval(200))])
        XCTAssertEqual(info.speedKmh ?? 0, 54, accuracy: 0.1)

        // 列車を特定できないときは、線の駅から「◯◯方面」と次の駅を出す
        judgement.trainID = nil
        let noTrain = RideInfo.make(judgement: judgement, lines: [line], trains: [], registeredStationIDs: ["C"])
        XCTAssertEqual(noTrain.directionText, "C駅方面")
        XCTAssertEqual(noTrain.aheadStations, ["B駅", "C駅"])
        XCTAssertEqual(noTrain.targets.first?.stopsAway, 2)
        XCTAssertEqual(RideInfo.make(judgement: RideJudgement(state: .idle), lines: [line], trains: [], registeredStationIDs: []).stateText,
                       "乗車中ではありません")
    }
}

/// 仮想の移動(速さ・倍率・停車・GPSなしの区間)、GPXの読み書き、記録
final class VirtualMovementTests: XCTestCase {
    private let origin = GeoPoint(35.68, 139.76)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(_ distances: [Double]) -> VirtualPlan {
        var plan = VirtualPlan()
        plan.points = distances.map { GeoMath.offset(origin, east: $0, north: 0) }
        plan.speedKmh = 36
        return plan
    }

    func testSpeedAndTimeScale() {
        var mover = VirtualMover(plan: plan([0, 1000]))
        mover.advance(realSeconds: 1, speedKmh: 36, timeScale: 10)
        XCTAssertEqual(mover.along, 100, accuracy: 0.5)
        XCTAssertEqual(mover.virtualElapsed, 10, accuracy: 0.001)
        // 動かしながら速さと倍率を変える
        mover.advance(realSeconds: 1, speedKmh: 72, timeScale: 5)
        XCTAssertEqual(mover.along, 200, accuracy: 0.5)
        mover.advance(realSeconds: 100, speedKmh: 72, timeScale: 5)
        XCTAssertTrue(mover.isFinished)
        XCTAssertEqual(mover.along, mover.path.length, accuracy: 0.01)
    }

    func testStopsAtStations() {
        var p = plan([0, 300, 1000])
        p.stops = [VirtualPlan.Stop(pointIndex: 1, dwell: 30)]
        var mover = VirtualMover(plan: p)
        mover.advance(realSeconds: 29, speedKmh: 36, timeScale: 1)
        XCTAssertEqual(mover.along, 290, accuracy: 0.5)
        XCTAssertFalse(mover.isStopped)
        mover.advance(realSeconds: 2, speedKmh: 36, timeScale: 1)
        XCTAssertEqual(mover.along, 300, accuracy: 0.5)
        XCTAssertTrue(mover.isStopped)
        XCTAssertEqual(mover.dwellRemaining, 29, accuracy: 0.6)
        let stopped = mover.sample(at: start, accuracy: 5, speedKmh: 36)
        XCTAssertEqual(stopped?.speed, 0)
        mover.advance(realSeconds: 29.5, speedKmh: 36, timeScale: 1)
        XCTAssertFalse(mover.isStopped)
        mover.advance(realSeconds: 5, speedKmh: 36, timeScale: 1)
        XCTAssertEqual(mover.along, 350, accuracy: 6)
        // 倍率を上げても、停車時間は仮想の秒で数える(1秒 = 10秒なら3秒で終わる)
        var fast = VirtualMover(plan: p)
        fast.advance(realSeconds: 3, speedKmh: 36, timeScale: 10)
        XCTAssertTrue(fast.isStopped)
        fast.advance(realSeconds: 3, speedKmh: 36, timeScale: 10)
        XCTAssertFalse(fast.isStopped)
        XCTAssertEqual(fast.along, 300, accuracy: 0.5)
        fast.advance(realSeconds: 1, speedKmh: 36, timeScale: 10)
        XCTAssertEqual(fast.along, 400, accuracy: 0.5)
    }

    func testGPSGapAndNoise() throws {
        var p = plan([0, 300, 1000])
        p.gaps = [VirtualPlan.Gap(fromIndex: 1, toIndex: 2)]
        var mover = VirtualMover(plan: p)
        mover.advance(realSeconds: 20, speedKmh: 36, timeScale: 1)
        XCTAssertFalse(mover.isInGap)
        XCTAssertNotNil(mover.sample(at: start, accuracy: 5, speedKmh: 36))
        mover.advance(realSeconds: 20, speedKmh: 36, timeScale: 1)
        XCTAssertTrue(mover.isInGap)
        XCTAssertNil(mover.sample(at: start, accuracy: 5, speedKmh: 36))
        XCTAssertNotNil(mover.position, "GPSなしの区間でも、線の上の位置は分かる")

        var generator = RideTestGenerator()
        var mover2 = VirtualMover(plan: plan([0, 1000]))
        mover2.advance(realSeconds: 10, speedKmh: 36, timeScale: 1)
        let exact = try XCTUnwrap(mover2.position)
        for _ in 0..<200 {
            let noise = VirtualMover.noise(meters: 10, using: &generator)
            XCTAssertLessThanOrEqual((noise.east * noise.east + noise.north * noise.north).squareRoot(), 10.0001)
            let noisy = try XCTUnwrap(mover2.sample(at: start, noise: noise, accuracy: 10, speedKmh: 36))
            XCTAssertLessThanOrEqual(GeoMath.distance(noisy.point, exact), 10.1)
        }
        XCTAssertEqual(VirtualMover.noise(meters: 0, using: &generator).east, 0)
    }

    func testPlanAlongRailwayAndEditing() throws {
        let line = RideLine(railwayID: "r", name: "線", stations: (0..<4).map { index in
            (id: "S\(index)", name: "駅\(index)", point: GeoMath.offset(origin, east: Double(index) * 1000, north: 0))
        })
        let forward = try XCTUnwrap(VirtualPlan.stationPlan(line: line, fromStation: 0, toStation: 3, dwell: 20, base: VirtualPlan()))
        XCTAssertEqual(forward.points.count, 4)
        XCTAssertEqual(forward.stops.map(\.pointIndex), [1, 2])
        XCTAssertEqual(forward.stops.map(\.name), ["駅1", "駅2"])
        let backward = try XCTUnwrap(VirtualPlan.stationPlan(line: line, fromStation: 3, toStation: 1, dwell: 20, base: VirtualPlan()))
        XCTAssertEqual(backward.points, [line.path.points[3], line.path.points[2], line.path.points[1]])
        XCTAssertEqual(backward.stops.map(\.name), ["駅2"])
        XCTAssertNil(VirtualPlan.stationPlan(line: line, fromStation: 1, toStation: 1, dwell: 20, base: VirtualPlan()))

        // 点を消すと、停車とGPSなしの区間の番号を詰める
        var edited = forward
        edited.gaps = [VirtualPlan.Gap(fromIndex: 2, toIndex: 3)]
        edited.removePoint(at: 1)
        XCTAssertEqual(edited.points.count, 3)
        XCTAssertEqual(edited.stops.map(\.pointIndex), [1])
        XCTAssertEqual(edited.gaps, [VirtualPlan.Gap(fromIndex: 1, toIndex: 2)])
    }

    func testVirtualClockAndReplay() {
        var clock = VirtualClock(start: start)
        clock.advance(realSeconds: 1, timeScale: 10)
        XCTAssertEqual(clock.now, start.addingTimeInterval(10))
        let morning = VirtualClock.start(on: start, hour: 8, minute: 0)
        XCTAssertEqual(JapaneseHolidays.calendar.component(.hour, from: morning), 8)

        let recorded = [0.0, 5, 10, 20].map { RideSample(time: start.addingTimeInterval($0), latitude: 35.68, longitude: 139.76 + $0 / 10000) }
        var replay = GPXReplay(samples: recorded.reversed())
        XCTAssertEqual(replay.duration, 20)
        let clockStart = start.addingTimeInterval(86400)
        let first = replay.advance(realSeconds: 1, timeScale: 10, clockStart: clockStart)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first.map(\.time), [0.0, 5, 10].map { clockStart.addingTimeInterval($0) })
        let second = replay.advance(realSeconds: 1, timeScale: 10, clockStart: clockStart)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(replay.isFinished)
    }

    /// 仮想の移動を判定に通す(線路に沿って走り、途中の駅で止まり、地下でGPSが途切れる)
    func testVirtualRideThroughDetector() throws {
        let line = RideLine(railwayID: "r", name: "線", stations: (0..<4).map { index in
            (id: "S\(index)", name: "駅\(index)", point: GeoMath.offset(origin, east: Double(index) * 2000, north: 0))
        })
        var p = try XCTUnwrap(VirtualPlan.stationPlan(line: line, fromStation: 0, toStation: 3, dwell: 30, base: plan([])))
        p.speedKmh = 60
        p.gaps = [VirtualPlan.Gap(fromIndex: 2, toIndex: 3)]
        var mover = VirtualMover(plan: p)
        var detector = RideDetector()
        var states: [RideJudgement.State] = []
        var time = start
        for _ in 0..<600 {
            mover.advance(realSeconds: 1, speedKmh: p.speedKmh, timeScale: 1)
            time = time.addingTimeInterval(1)
            // 列車は自分と同じ位置を走っているものとする
            let context = RideContext(lines: [line], trains: [RideTrainCandidate(
                id: "t", railwayID: "r", number: "t", trainType: "普通", destination: "駅3", delay: .timetable,
                along: mover.along, isAscending: true, isStopped: mover.isStopped, upcoming: [])])
            if let sample = mover.sample(at: time, accuracy: 10, speedKmh: p.speedKmh) {
                states.append(detector.add(sample, context: context).state)
            } else {
                states.append(detector.tick(now: time, context: context).state)
            }
            if mover.isFinished { break }
        }
        XCTAssertTrue(states.contains(.riding))
        XCTAssertTrue(states.contains(.estimating), "GPSなしの区間では推定に切り替わる")
        XCTAssertGreaterThanOrEqual(detector.judgement.debug.stationStops, 1)
        XCTAssertEqual(detector.judgement.trainID, "t")
    }

    // MARK: - GPX

    func testGPXRoundTrip() throws {
        let samples = [
            RideSample(time: start, latitude: 35.6812345, longitude: 139.7671234, accuracy: 8.5, speed: 12.25),
            RideSample(time: start.addingTimeInterval(5.5), latitude: 35.6822345, longitude: 139.7681234, accuracy: -1, speed: -1),
            RideSample(time: start.addingTimeInterval(11), latitude: 35.6832345, longitude: 139.7691234, accuracy: 12, speed: 0),
        ]
        let ride = MovementRide(railwayID: "r", railwayName: "浅草線 <テスト> & 確認", trainLabel: "普通 西馬込行",
                                start: start, end: start.addingTimeInterval(11), confidence: 2)
        let text = GPXCodec.write(name: "移動の記録", samples: samples, rides: [ride])
        XCTAssertTrue(text.contains("&lt;テスト&gt; &amp; 確認"))
        let track = try XCTUnwrap(GPXCodec.parse(Data(text.utf8)))
        XCTAssertEqual(track.name, "移動の記録")
        XCTAssertEqual(track.samples.count, 3)
        for (parsed, original) in zip(track.samples, samples) {
            XCTAssertEqual(parsed.latitude, original.latitude, accuracy: 1e-6)
            XCTAssertEqual(parsed.longitude, original.longitude, accuracy: 1e-6)
            XCTAssertEqual(parsed.time.timeIntervalSince1970, original.time.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(parsed.accuracy, original.accuracy, accuracy: 0.05)
            XCTAssertEqual(parsed.speed, original.speed, accuracy: 0.005)
        }
    }

    func testGPXFromOtherApps() throws {
        let other = """
        <?xml version="1.0"?>
        <gpx version="1.1" creator="other" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>メタデータの名前</name></metadata>
          <trk><name>通勤</name><trkseg>
            <trkpt lat="35.1" lon="139.1"><ele>10</ele><time>2026-09-24T08:00:00Z</time></trkpt>
            <trkpt lat="35.2" lon="139.2"><time>2026-09-24T08:00:10Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """
        let track = try XCTUnwrap(GPXCodec.parse(Data(other.utf8)))
        XCTAssertEqual(track.name, "通勤")
        XCTAssertEqual(track.samples.count, 2)
        XCTAssertEqual(track.samples[1].time.timeIntervalSince(track.samples[0].time), 10)
        XCTAssertEqual(track.samples[0].accuracy, -1)

        // 時刻のない経路(rtept)は、1秒間隔とみなす
        let route = """
        <gpx><rte><rtept lat="35.0" lon="139.0"/><rtept lat="35.001" lon="139.0"/><rtept lat="999" lon="0"/></rte></gpx>
        """
        let routeTrack = try XCTUnwrap(GPXCodec.parse(Data(route.utf8)))
        XCTAssertEqual(routeTrack.samples.count, 2)
        XCTAssertEqual(routeTrack.samples[1].time.timeIntervalSince(routeTrack.samples[0].time), 1)

        XCTAssertNil(GPXCodec.parse(Data("<gpx><trk></trk></gpx>".utf8)))
        XCTAssertNil(GPXCodec.parse(Data("これはGPXではない".utf8)))
    }

    // MARK: - 記録

    func testMovementLogPolicy() {
        let first = RideSample(time: start, latitude: 35.68, longitude: 139.76)
        XCTAssertTrue(MovementLogPolicy.shouldAppend(first, after: nil))
        XCTAssertFalse(MovementLogPolicy.shouldAppend(RideSample(time: start.addingTimeInterval(2), latitude: 35.68, longitude: 139.76), after: first))
        XCTAssertTrue(MovementLogPolicy.shouldAppend(RideSample(time: start.addingTimeInterval(5), latitude: 35.68, longitude: 139.76), after: first))
        XCTAssertTrue(MovementLogPolicy.shouldAppend(RideSample(time: start.addingTimeInterval(1), latitude: 35.6805, longitude: 139.76), after: first))

        let calendar = JapaneseHolidays.calendar
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 12))!
        let keys = ["2026-09-24", "2026-09-23", "2026-09-18", "2026-09-17"]
        XCTAssertEqual(MovementLogPolicy.dayKey(today), "2026-09-24")
        XCTAssertEqual(MovementLogPolicy.expiredKeys(keys, today: today, retention: .today), ["2026-09-23", "2026-09-18", "2026-09-17"])
        XCTAssertEqual(MovementLogPolicy.expiredKeys(keys, today: today, retention: .week), ["2026-09-17"])
        XCTAssertEqual(MovementLogPolicy.expiredKeys(keys, today: today, retention: .none), keys)

        // 乗車と判定した区間だけを色分けする(区切りの点は両方に入れる)
        let samples = (0..<6).map { RideSample(time: start.addingTimeInterval(Double($0) * 10), latitude: 35.68, longitude: 139.76 + Double($0) / 1000) }
        let day = MovementDay(day: "2026-09-24", samples: samples, rides: [
            MovementRide(railwayID: "r", railwayName: "線", trainLabel: nil, start: start.addingTimeInterval(20), end: start.addingTimeInterval(30), confidence: 1),
        ])
        let segments = MovementLogPolicy.segments(day)
        XCTAssertEqual(segments.map { $0.isRide }, [false, true, false])
        XCTAssertEqual(segments.map { $0.points.count }, [2, 3, 3])
        XCTAssertGreaterThan(MovementLogPolicy.distance(samples), 400)
    }
}

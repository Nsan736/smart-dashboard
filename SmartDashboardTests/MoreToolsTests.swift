import XCTest
@testable import SmartDashboard

/// 決まった順に値を返す乱数(テスト用)
private struct SequenceGenerator: RandomNumberGenerator {
    var state: UInt64 = 0x1234_5678_9ABC_DEF1

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// v0.9.8 で足したツールと、「決める・遊ぶ」の見た目のためのロジック
final class MoreToolLogicTests: XCTestCase {
    // MARK: - トーナメント表の配置

    func testTournamentLayoutPositions() throws {
        let tournament = try XCTUnwrap(Tournament(players: ["A", "B", "C", "D", "E", "F", "G", "H"]))
        let metrics = TournamentLayout.Metrics()
        let layout = TournamentLayout.make(tournament, metrics: metrics)
        XCTAssertEqual(layout.boxes.count, 7)
        func rect(_ round: Int, _ index: Int) throws -> CGRect {
            try XCTUnwrap(layout.boxes.first { $0.round == round && $0.index == index }).rect
        }
        let r00 = try rect(0, 0)
        let r01 = try rect(0, 1)
        let r10 = try rect(1, 0)
        let r11 = try rect(1, 1)
        let r20 = try rect(2, 0)
        // 1回戦が左端、決勝が右端
        XCTAssertLessThan(r00.minX, r10.minX)
        XCTAssertLessThan(r10.minX, r20.minX)
        XCTAssertLessThan(r20.maxX, layout.championRect.minX)
        XCTAssertEqual(r10.minX - r00.maxX, metrics.columnGap, accuracy: 0.001)
        // 1回戦は等間隔で重ならず、次の回戦は前の2試合の中間
        XCTAssertEqual(r01.minY - r00.maxY, metrics.rowGap, accuracy: 0.001)
        XCTAssertEqual(r10.midY, (r00.midY + r01.midY) / 2, accuracy: 0.001)
        XCTAssertEqual(r20.midY, (r10.midY + r11.midY) / 2, accuracy: 0.001)
        XCTAssertEqual(layout.championRect.midY, r20.midY, accuracy: 0.001)
        // すべてが表の大きさの中に入る
        let bounds = CGRect(origin: .zero, size: layout.size)
        XCTAssertTrue(layout.boxes.allSatisfy { bounds.contains($0.rect) })
        XCTAssertTrue(bounds.contains(layout.championRect))
        XCTAssertEqual(layout.roundTitles.map(\.title), ["1回戦", "準決勝", "決勝"])
    }

    func testTournamentLayoutConnectors() throws {
        var tournament = try XCTUnwrap(Tournament(players: ["A", "B", "C", "D"]))
        var layout = TournamentLayout.make(tournament)
        // 1回戦2試合 → 決勝、決勝 → 優勝
        XCTAssertEqual(layout.connectors.count, 3)
        XCTAssertTrue(layout.connectors.allSatisfy { !$0.isWon })
        let final = try XCTUnwrap(layout.boxes.first { $0.round == 1 })
        let first = try XCTUnwrap(layout.boxes.first { $0.round == 0 && $0.index == 0 })
        let second = try XCTUnwrap(layout.boxes.first { $0.round == 0 && $0.index == 1 })
        // 上の試合は決勝の上の枠へ、下の試合は下の枠へ。線は直角に折れる
        let upper = layout.connectors[0].points
        XCTAssertEqual(upper.count, 4)
        XCTAssertEqual(upper.first, CGPoint(x: first.rect.maxX, y: first.rect.midY))
        XCTAssertEqual(upper.last, CGPoint(x: final.rect.minX, y: final.first.rect.midY))
        XCTAssertEqual(upper[0].y, upper[1].y)
        XCTAssertEqual(upper[1].x, upper[2].x)
        XCTAssertEqual(upper[2].y, upper[3].y)
        XCTAssertEqual(layout.connectors[1].points.first, CGPoint(x: second.rect.maxX, y: second.rect.midY))
        XCTAssertEqual(layout.connectors[1].points.last, CGPoint(x: final.rect.minX, y: final.second.rect.midY))

        // 勝者を決めると、その線と枠に色が付く
        let winnerName = try XCTUnwrap(first.first.name)
        tournament.setWinner(round: 0, index: 0, name: winnerName)
        layout = TournamentLayout.make(tournament)
        XCTAssertEqual(layout.connectors.map(\.isWon), [true, false, false])
        let played = try XCTUnwrap(layout.boxes.first { $0.round == 0 && $0.index == 0 })
        XCTAssertTrue(played.first.isWinner)
        XCTAssertFalse(played.first.isLoser)
        XCTAssertTrue(played.second.isLoser)
        XCTAssertEqual(layout.boxes.first { $0.round == 1 }?.first.name, winnerName)
        XCTAssertNil(layout.champion)
        let otherName = try XCTUnwrap(second.second.name)
        tournament.setWinner(round: 0, index: 1, name: otherName)
        tournament.setWinner(round: 1, index: 0, name: otherName)
        layout = TournamentLayout.make(tournament)
        XCTAssertEqual(layout.champion, otherName)
        XCTAssertEqual(layout.connectors.last?.isWon, true)
    }

    func testTournamentLayoutSeedsAndByes() throws {
        // 5人: 8枠で、A・B・C が不戦勝。1回戦の実際の試合は D 対 E だけ
        let tournament = try XCTUnwrap(Tournament(players: ["A", "B", "C", "D", "E"]))
        let layout = TournamentLayout.make(tournament)
        let firstRound = layout.boxes.filter { $0.round == 0 }
        XCTAssertEqual(firstRound.count, 1)
        XCTAssertEqual(Set([firstRound[0].first.name, firstRound[0].second.name].compactMap { $0 }), Set(["D", "E"]))
        // 不戦勝の試合からは線を出さない: 1回戦1本 + 準決勝2本 + 優勝1本
        XCTAssertEqual(layout.connectors.count, 4)
        let secondRound = layout.boxes.filter { $0.round == 1 }.flatMap { [$0.first, $0.second] }
        XCTAssertEqual(Set(secondRound.filter(\.isSeeded).compactMap(\.name)), Set(["A", "B", "C"]))
        // 線がつながる枠(D 対 E の勝者)は、シードの印なしで、まだ未定
        let open = secondRound.filter { !$0.isSeeded }
        XCTAssertEqual(open.count, 1)
        XCTAssertNil(open.first?.name)
        XCTAssertTrue(layout.boxes.filter { $0.round == 2 }.allSatisfy { !$0.first.isSeeded && !$0.second.isSeeded })
    }

    func testTournamentLayoutHitNamesAndFit() throws {
        let tournament = try XCTUnwrap(Tournament(players: ["A", "B", "C", "D"]))
        let layout = TournamentLayout.make(tournament)
        let box = try XCTUnwrap(layout.boxes.first { $0.round == 0 && $0.index == 1 })
        let upper = try XCTUnwrap(layout.hit(at: CGPoint(x: box.rect.midX, y: box.rect.minY + 5)))
        XCTAssertEqual(upper.box.index, 1)
        XCTAssertTrue(upper.isFirst)
        XCTAssertEqual(layout.hit(at: CGPoint(x: box.rect.midX, y: box.rect.maxY - 5))?.isFirst, false)
        XCTAssertNil(layout.hit(at: CGPoint(x: layout.size.width - 1, y: 1)))

        XCTAssertEqual(TournamentLayout.shortName("たなか", units: 14), "たなか")
        XCTAssertEqual(TournamentLayout.shortName("とても長い名前のチーム", units: 14), "とても長い名前…")
        XCTAssertEqual(TournamentLayout.shortName("abcdefghijklmnopq", units: 14), "abcdefghijklmn…")

        XCTAssertEqual(TournamentLayout.fitScale(content: CGSize(width: 750, height: 400), viewport: CGSize(width: 375, height: 500)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TournamentLayout.fitScale(content: CGSize(width: 100, height: 100), viewport: CGSize(width: 375, height: 500)), 1)
        // 64人でも作れる
        let big = TournamentLayout.make(try XCTUnwrap(Tournament(players: (1...64).map { "選手" + String($0) })))
        XCTAssertEqual(big.boxes.count, 63)
        XCTAssertEqual(big.connectors.count, 63)
    }

    // MARK: - ルーレット、コイン、サイコロ

    func testRouletteStopsOnTheResult() {
        for count in [1, 2, 3, 7, 12, 40] {
            var rotation = 0.0
            for index in 0..<count {
                for fraction in [0.0, 0.15, 0.5, 0.85, 1.0] {
                    let target = RouletteWheel.stopRotation(current: rotation, index: index, count: count, turns: 4, fraction: fraction)
                    XCTAssertGreaterThanOrEqual(target, rotation + 4 * 360)
                    XCTAssertLessThan(target, rotation + 5 * 360 + 0.0001)
                    XCTAssertEqual(RouletteWheel.index(atRotation: target, count: count), index)
                    rotation = target
                }
            }
        }
        // 回していなければ、針の下は先頭の項目。少し時計回りに回すと、最後の項目
        XCTAssertEqual(RouletteWheel.index(atRotation: 0, count: 4), 0)
        XCTAssertEqual(RouletteWheel.index(atRotation: 10, count: 4), 3)
        XCTAssertEqual(RouletteWheel.index(atRotation: -100, count: 4), 1)
    }

    func testCoinAndDice() {
        var angle = 0.0
        for heads in [true, false, false, true, true, false] {
            let target = CoinFlip.targetAngle(current: angle, heads: heads, turns: 3)
            XCTAssertGreaterThanOrEqual(target, angle + 3 * 360)
            XCTAssertLessThan(target, angle + 4 * 360 + 0.0001)
            XCTAssertEqual(CoinFlip.showsHeads(angle: target), heads)
            angle = target
        }
        XCTAssertTrue(CoinFlip.showsHeads(angle: 45))
        XCTAssertFalse(CoinFlip.showsHeads(angle: 135))

        for value in 1...6 {
            let positions = DicePips.positions(value)
            XCTAssertEqual(positions.count, value)
            XCTAssertEqual(Set(positions.map { $0.column * 3 + $0.row }).count, value)
            // 点対称
            XCTAssertTrue(positions.allSatisfy { point in positions.contains { $0.column == 2 - point.column && $0.row == 2 - point.row } })
        }
        XCTAssertTrue(DicePips.positions(7).isEmpty)
    }

    // MARK: - 時間計算

    func testTimeCalcParseAndFormat() {
        XCTAssertEqual(TimeCalc.parse("1:30"), 5400)
        XCTAssertEqual(TimeCalc.parse("1:30:15"), 5415)
        XCTAssertEqual(TimeCalc.parse("1時間30分"), 5400)
        XCTAssertEqual(TimeCalc.parse("90分"), 5400)
        XCTAssertEqual(TimeCalc.parse("45秒"), 45)
        XCTAssertEqual(TimeCalc.parse("1h 30m"), 5400)
        XCTAssertEqual(TimeCalc.parse("90"), 5400)
        XCTAssertEqual(TimeCalc.parse("-0:45"), -2700)
        XCTAssertEqual(TimeCalc.parse("１：３０"), 5400)
        XCTAssertEqual(TimeCalc.parse("25:00"), 90000)
        XCTAssertNil(TimeCalc.parse(""))
        XCTAssertNil(TimeCalc.parse("abc"))
        XCTAssertNil(TimeCalc.parse("1:2:3:4"))
        XCTAssertNil(TimeCalc.parse("1:"))
        XCTAssertNil(TimeCalc.parse("30分10"))

        XCTAssertEqual(TimeCalc.format(5415), "1:30:15")
        XCTAssertEqual(TimeCalc.format(-2700), "−0:45:00")
        XCTAssertEqual(TimeCalc.japanese(5400), "1時間30分")
        XCTAssertEqual(TimeCalc.japanese(3605), "1時間5秒")
        XCTAssertEqual(TimeCalc.japanese(0), "0秒")
    }

    func testTimeCalcSumAndClock() {
        let sum = TimeCalc.sum(lines: ["1:30", "45分", "", "-0:15", "だめ"].joined(separator: "\n"))
        XCTAssertEqual(sum.total, 7200)
        XCTAssertEqual(sum.invalidLines, [5])

        XCTAssertEqual(TimeCalc.minutesBetween(startMinutes: 9 * 60, endMinutes: 17 * 60 + 30), 510)
        XCTAssertEqual(TimeCalc.minutesBetween(startMinutes: 22 * 60, endMinutes: 6 * 60), 480)
        XCTAssertEqual(TimeCalc.minutesBetween(startMinutes: 600, endMinutes: 600), 0)

        var result = TimeCalc.clock(adding: 5400, toMinutes: 23 * 60)
        XCTAssertEqual(result.dayOffset, 1)
        XCTAssertEqual(result.minutes, 30)
        result = TimeCalc.clock(adding: -5400, toMinutes: 60)
        XCTAssertEqual(result.dayOffset, -1)
        XCTAssertEqual(result.minutes, 23 * 60 + 30)
        result = TimeCalc.clock(adding: 3600, toMinutes: 600)
        XCTAssertEqual(result.dayOffset, 0)
        XCTAssertEqual(TimeCalc.clockText(result.minutes), "11:00")
    }

    // MARK: - 世界時計

    func testWorldClockOffsets() throws {
        func date(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let delhi = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let sydney = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let winter = try date("2026-01-15T03:00:00Z")
        let summer = try date("2026-07-15T03:00:00Z")
        // 夏時間で1時間変わる
        XCTAssertEqual(WorldClock.offsetFromJapan(newYork, at: winter), -14 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(newYork, at: summer), -13 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(london, at: winter), -9 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(london, at: summer), -8 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(delhi, at: winter), -(3 * 3600 + 1800))
        XCTAssertEqual(WorldClock.offsetFromJapan(sydney, at: winter), 2 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(WorldClock.japan, at: winter), 0)

        XCTAssertEqual(WorldClock.offsetText(-14 * 3600), "−14時間")
        XCTAssertEqual(WorldClock.offsetText(-(3 * 3600 + 1800)), "−3時間30分")
        XCTAssertEqual(WorldClock.offsetText(2 * 3600), "+2時間")
        XCTAssertEqual(WorldClock.offsetText(0), "日本と同じ")

        // UTC 3:00 = 日本の12:00。ニューヨークは前日の22:00
        XCTAssertEqual(WorldClock.timeText(WorldClock.japan, at: winter), "12:00")
        XCTAssertEqual(WorldClock.timeText(newYork, at: winter), "22:00")
        XCTAssertEqual(WorldClock.dayDifference(newYork, at: winter), -1)
        XCTAssertEqual(WorldClock.dayDifference(london, at: winter), 0)
        // UTC 14:00 = 日本の23:00。シドニーは翌日の1:00
        XCTAssertEqual(WorldClock.dayDifference(sydney, at: try date("2026-01-15T14:00:00Z")), 1)
        XCTAssertEqual(WorldClock.dayText(-1), "前日")

        // 都市の表のタイムゾーンは、すべて iOS が知っている。IDは重複しない
        XCTAssertTrue(WorldClock.cities.allSatisfy { TimeZone(identifier: $0.zone) != nil })
        XCTAssertEqual(Set(WorldClock.cities.map(\.id)).count, WorldClock.cities.count)
        XCTAssertEqual(WorldClock.cities.first?.id, "tokyo")
        XCTAssertEqual(WorldClock.decode("london,nowhere,sydney").map(\.name), ["ロンドン", "シドニー"])
        XCTAssertEqual(WorldClock.encode(WorldClock.decode("london,sydney")), "london,sydney")
    }

    // MARK: - あみだくじ

    func testAmidaTrace() {
        // 縦線3本。1段目: 0-1、2段目: 1-2、3段目: 0-1
        let amida = Amida(columns: 3, rungs: [[true, false], [false, true], [true, false]])
        XCTAssertEqual(amida.columnsVisited(from: 0), [0, 1, 2, 2])
        XCTAssertEqual(amida.result(from: 0), 2)
        XCTAssertEqual(amida.result(from: 1), 1)
        XCTAssertEqual(amida.result(from: 2), 0)
        XCTAssertEqual(amida.path(from: 0), [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 2), CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 4),
        ])
        // 横線がなければ、まっすぐ下りる
        XCTAssertEqual(Amida(columns: 2, rungs: [[false], [false]]).path(from: 1), [CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 3)])
    }

    func testAmidaGeneratedIsAPermutation() {
        var generator = SequenceGenerator()
        for columns in 2...12 {
            let amida = Amida(columns: columns, rows: columns + 4, using: &generator)
            XCTAssertEqual(amida.rungs.count, columns + 4)
            // 同じ段で、横線が隣り合わない
            for row in amida.rungs {
                XCTAssertEqual(row.count, columns - 1)
                for gap in row.indices.dropFirst() { XCTAssertFalse(row[gap] && row[gap - 1]) }
            }
            // どの縦線の間にも横線がある
            for gap in 0..<(columns - 1) { XCTAssertTrue(amida.rungs.contains { $0[gap] }) }
            // 結果は重ならない(全員が別のゴールに着く)
            XCTAssertEqual(Set((0..<columns).map { amida.result(from: $0) }), Set(0..<columns))
        }
    }

    // MARK: - スコアボード、メトロノーム

    func testScoreboard() throws {
        var board = Scoreboard()
        board.add(1, to: 0)
        board.add(1, to: 0)
        board.add(1, to: 1)
        board.add(-5, to: 1)
        board.add(1, to: 9)
        XCTAssertEqual(board.teams.map(\.score), [2, 0])
        XCTAssertTrue(board.finishSet())
        XCTAssertEqual(board.teams.map(\.sets), [1, 0])
        XCTAssertEqual(board.teams.map(\.score), [0, 0])
        // 同点では決めない
        XCTAssertFalse(board.finishSet())
        XCTAssertEqual(board.teams.map(\.sets), [1, 0])
        let restored = try JSONDecoder().decode(Scoreboard.self, from: JSONEncoder().encode(board))
        XCTAssertEqual(restored, board)
        board.resetAll()
        XCTAssertEqual(board.teams.map(\.sets), [0, 0])
    }

    func testMetronome() {
        XCTAssertEqual(MetronomeLogic.framesPerBeat(bpm: 120, sampleRate: 44100), 22050)
        XCTAssertEqual(MetronomeLogic.clamped(10), 30)
        XCTAssertEqual(MetronomeLogic.clamped(999), 240)
        XCTAssertEqual(MetronomeLogic.beatIndex(elapsed: 0.1, bpm: 120, beatsPerBar: 4), 0)
        XCTAssertEqual(MetronomeLogic.beatIndex(elapsed: 1.6, bpm: 120, beatsPerBar: 4), 3)
        XCTAssertEqual(MetronomeLogic.beatIndex(elapsed: 2.1, bpm: 120, beatsPerBar: 4), 0)
        XCTAssertNil(MetronomeLogic.tapTempo([1.0]))
        XCTAssertEqual(MetronomeLogic.tapTempo([0, 0.5, 1.0, 1.5]), 120)
        // 2秒以上空いたら、数え直す
        XCTAssertEqual(MetronomeLogic.tapTempo([0, 0.5, 10, 11, 12]), 60)

        let samples = MetronomeLogic.barSamples(bpm: 120, beatsPerBar: 4, accent: true, sampleRate: 44100)
        XCTAssertEqual(samples.count, 22050 * 4)
        // 各拍の先頭だけに音があり、拍の後半は無音
        XCTAssertTrue(samples[1..<200].contains { abs($0) > 0.1 })
        XCTAssertTrue(samples[22051..<22250].contains { abs($0) > 0.1 })
        XCTAssertTrue(samples[11000..<22050].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 1 })
    }
}

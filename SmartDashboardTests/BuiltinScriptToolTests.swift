import JavaScriptCore
import XCTest
@testable import SmartDashboard

/// 組み込みのツールの JavaScript 版(v0.9.32): 同梱、一覧の並び、複製、試しの実行、計算の部分
final class BuiltinScriptToolTests: XCTestCase {
    /// 同梱したツールのスクリプトを、アプリの関数なしの JSContext で読む(読み込んだ時点ではアプリの関数を呼ばない作り)
    private func context(_ file: String) throws -> JSContext {
        let tool = try XCTUnwrap(BuiltinScriptTools.all.first { $0.file == file }, file)
        let script = try XCTUnwrap(tool.tool.script?.script)
        let context = try XCTUnwrap(JSContext())
        let errors = ErrorBox()
        context.exceptionHandler = { _, value in errors.text = value?.toString() }
        context.evaluateScript(script)
        XCTAssertNil(errors.text, file)
        // 決まった乱数(テスト用)
        context.evaluateScript("var R = (function () { var s = 7; return function () { s = (s * 16807) % 2147483647; return (s - 1) / 2147483646; }; })();")
        return context
    }

    private final class ErrorBox {
        var text: String?
    }

    private func text(_ c: JSContext, _ expression: String) -> String { c.evaluateScript(expression)?.toString() ?? "" }
    private func number(_ c: JSContext, _ expression: String) -> Double { c.evaluateScript(expression)?.toDouble() ?? .nan }
    private func bool(_ c: JSContext, _ expression: String) -> Bool { c.evaluateScript(expression)?.toBool() ?? false }

    // MARK: - 同梱と一覧

    func testBundleLoadsAllTools() {
        let tools = BuiltinScriptTools.all
        XCTAssertEqual(tools.count, 21)
        XCTAssertTrue(tools.allSatisfy { $0.tool.id.hasPrefix(BuiltinScriptTools.idPrefix) && $0.tool.kind == .script })
        // どれも Swift の版を置き換える(重ならない)。懐中電灯・世界時計・メトロノームは Swift のまま
        let replaced = tools.compactMap(\.replaces)
        XCTAssertEqual(replaced.count, tools.count)
        XCTAssertEqual(Set(replaced).count, replaced.count)
        XCTAssertEqual(Set(BuiltinTool.allCases).subtracting(replaced), [.flashlight, .worldClock, .metronome])
        // スクリプトは上限の中
        XCTAssertTrue(tools.allSatisfy { ($0.tool.script?.script.count ?? .max) <= ScriptToolContent.maxScriptLength })
    }

    func testListPlacesJavaScriptVersionAfterSwiftVersion() throws {
        let list = BuiltinTools.withScripts
        XCTAssertEqual(list.count, BuiltinTools.all.count + BuiltinScriptTools.all.count)
        XCTAssertEqual(Set(list.map(\.id)).count, list.count)
        let timer = try XCTUnwrap(list.firstIndex { $0.id == "builtin.timer" })
        let js = list[timer + 1]
        XCTAssertEqual(js.id, "bundled.builtin-js.timer")
        XCTAssertEqual(js.name, "タイマー(JavaScript 版)")
        XCTAssertTrue(js.isBundled)
        XCTAssertTrue(js.isScript)
        XCTAssertFalse(js.isCustom)
        XCTAssertEqual(js.category, .time)
        // 検索でも見つかる
        XCTAssertTrue(ToolSearch.filter(list, query: "javascript トーナメント").contains { $0.isBundled })
    }

    func testCopyJSONMakesEditableTool() throws {
        let bundled = try XCTUnwrap(BuiltinScriptTools.all.first { $0.file == "tournament" })
        let identity = BuiltinScriptTools.copyIdentity(of: bundled, existing: [], random: { 1234 })
        XCTAssertEqual(identity.name, "トーナメント表(コピー)")
        XCTAssertTrue(identity.id.hasPrefix("my-tournament-"))
        // すでにある ID は避ける
        var calls: UInt32 = 0
        let second = BuiltinScriptTools.copyIdentity(of: bundled, existing: [identity.id], random: { calls += 1; return calls == 1 ? 1234 : 99 })
        XCTAssertNotEqual(second.id, identity.id)
        let json = try XCTUnwrap(BuiltinScriptTools.copyJSON(bundled.json, newID: identity.id, name: identity.name))
        guard case .success(let copy) = CustomToolParser.parse(json) else { return XCTFail("複製を読めるはず") }
        XCTAssertEqual(copy.id, identity.id)
        XCTAssertEqual(copy.name, "トーナメント表(コピー)")
        XCTAssertFalse(BuiltinScriptTools.isReserved(copy.id))
        XCTAssertEqual(copy.script?.script, bundled.tool.script?.script)
        XCTAssertEqual(copy.script?.controls, bundled.tool.script?.controls)
        XCTAssertFalse(copy.summary.contains("複製して編集"))
        XCTAssertNil(BuiltinScriptTools.copyJSON("not json", newID: "x", name: "x"))
    }

    func testBundledToolsRunWithoutErrors() throws {
        for bundled in BuiltinScriptTools.all {
            let content = try XCTUnwrap(bundled.tool.script, bundled.file)
            XCTAssertNil(ScriptTrial.syntaxError(content.script), bundled.file)
            XCTAssertEqual(ScriptTrial.run(content), [], bundled.file)
        }
    }

    // MARK: - 共通の部品(日付・数)

    func testKitDatesAndNumbers() throws {
        let c = try context("date-calc")
        XCTAssertEqual(number(c, "K.days(1970, 1, 1)"), 0)
        XCTAssertEqual(number(c, "K.days(2000, 3, 1) - K.days(2000, 2, 28)"), 2)
        XCTAssertEqual(text(c, "JSON.stringify(K.civil(K.days(2026, 10, 19)))"), #"{"y":2026,"m":10,"d":19}"#)
        XCTAssertEqual(text(c, "K.weekdayNames[K.weekday(K.days(2026, 10, 19))]"), "月")
        XCTAssertEqual(text(c, "JSON.stringify(K.parseDate('２０２６年２月２８日'))"), #"{"y":2026,"m":2,"d":28}"#)
        XCTAssertEqual(text(c, "JSON.stringify(K.parseDate('10/19', { y: 2026 }))"), #"{"y":2026,"m":10,"d":19}"#)
        XCTAssertEqual(text(c, "String(K.parseDate('2026/2/30'))"), "null")
        XCTAssertEqual(text(c, "K.group(-1234567)"), "−1,234,567")
        XCTAssertEqual(text(c, "K.number(1234.5)"), "1,234.5")
        XCTAssertEqual(text(c, "K.number(1 / 3)"), "0.3333333")
        XCTAssertEqual(number(c, "K.parseNumber('１２，８００円')"), 12800)
        XCTAssertEqual(text(c, "JSON.stringify(K.splitNames('A、B,\\n C\\n\\n'))"), #"["A","B","C"]"#)
        // 日数の差と、年・月・日
        XCTAssertEqual(number(c, "DateCalc.diff({ y: 2026, m: 1, d: 1 }, { y: 2026, m: 12, d: 31 })"), 364)
        XCTAssertEqual(text(c, "JSON.stringify(DateCalc.span({ y: 2026, m: 1, d: 31 }, { y: 2026, m: 3, d: 1 }))"), #"{"years":0,"months":1,"days":1}"#)
        XCTAssertEqual(text(c, "JSON.stringify(DateCalc.span({ y: 2000, m: 4, d: 1 }, { y: 2026, m: 10, d: 19 }))"), #"{"years":26,"months":6,"days":18}"#)
        XCTAssertEqual(text(c, "JSON.stringify(DateCalc.add({ y: 2026, m: 10, d: 19 }, 100))"), #"{"y":2027,"m":1,"d":27}"#)
    }

    // MARK: - 時間

    func testTimeCalc() throws {
        let c = try context("time-calc")
        XCTAssertEqual(number(c, "TimeCalc.parse('1:30')"), 5400)
        XCTAssertEqual(number(c, "TimeCalc.parse('１：３０：１５')"), 5415)
        XCTAssertEqual(number(c, "TimeCalc.parse('90')"), 5400)
        XCTAssertEqual(number(c, "TimeCalc.parse('1時間30分')"), 5400)
        XCTAssertEqual(number(c, "TimeCalc.parse('1h30m15s')"), 5415)
        XCTAssertEqual(number(c, "TimeCalc.parse('-45分')"), -2700)
        XCTAssertEqual(text(c, "String(TimeCalc.parse('abc'))"), "null")
        XCTAssertEqual(text(c, "String(TimeCalc.parse('1:2:3:4'))"), "null")
        XCTAssertEqual(text(c, "JSON.stringify(TimeCalc.sum('1:30\\n45分\\n-15分\\nあ'))"), #"{"total":7200,"invalid":[4]}"#)
        XCTAssertEqual(text(c, "K.clock(-5400)"), "−1:30:00")
        XCTAssertEqual(text(c, "K.japaneseDuration(3725)"), "1時間2分5秒")
        XCTAssertEqual(number(c, "TimeCalc.clockMinutes('9:30')"), 570)
        XCTAssertEqual(number(c, "TimeCalc.clockMinutes('1730')"), 1050)
        XCTAssertEqual(number(c, "TimeCalc.minutesBetween(22 * 60, 6 * 60)"), 480)
        XCTAssertEqual(text(c, "JSON.stringify(TimeCalc.addToClock(23 * 60, 7200))"), #"{"text":"1:00","dayOffset":1}"#)
        XCTAssertEqual(text(c, "JSON.stringify(TimeCalc.addToClock(30, -3600))"), #"{"text":"23:30","dayOffset":-1}"#)
    }

    func testTimerAndStopwatch() throws {
        let c = try context("timer")
        c.evaluateScript("var t = { id: 1, total: 60, left: 60, state: 'idle', endAt: null }; TimerLogic.start(t, 0);")
        XCTAssertEqual(number(c, "TimerLogic.remaining(t, 30000)"), 30)
        c.evaluateScript("TimerLogic.pause(t, 30000)")
        XCTAssertEqual(number(c, "TimerLogic.remaining(t, 99999)"), 30)
        c.evaluateScript("TimerLogic.start(t, 100000)")
        XCTAssertEqual(number(c, "t.endAt"), 130000)
        XCTAssertEqual(number(c, "TimerLogic.advance([t], 129999).length"), 0)
        XCTAssertEqual(number(c, "TimerLogic.advance([t], 130000).length"), 1)
        XCTAssertEqual(text(c, "t.state"), "done")
        // 表示は切り上げ(残り59.2秒は 1:00)
        XCTAssertEqual(text(c, "TimerLogic.text(59.2)"), "1:00")
        XCTAssertEqual(text(c, "TimerLogic.text(3600)"), "1:00:00")
        let s = try context("stopwatch")
        s.evaluateScript("var w = { startedAt: null, elapsed: 0, laps: [] }; StopwatchLogic.start(w, 1000); StopwatchLogic.lap(w, 3500); StopwatchLogic.stop(w, 5000);")
        XCTAssertEqual(number(s, "StopwatchLogic.elapsed(w, 99999)"), 4000)
        XCTAssertEqual(text(s, "JSON.stringify(w.laps)"), "[2500]")
        XCTAssertEqual(text(s, "StopwatchLogic.text(62340)"), "1:02.34")
        XCTAssertEqual(text(s, "StopwatchLogic.text(3723450)"), "1:02:03.45")
    }

    func testWareki() throws {
        let c = try context("wareki")
        XCTAssertEqual(text(c, "JSON.stringify(Wareki.fromYear(2019))"), #"["令和元年","平成31年"]"#)
        XCTAssertEqual(text(c, "JSON.stringify(Wareki.fromYear(1989))"), #"["平成元年","昭和64年"]"#)
        XCTAssertEqual(text(c, "JSON.stringify(Wareki.fromYear(2026))"), #"["令和8年"]"#)
        XCTAssertEqual(text(c, "Wareki.fromDate({ y: 1989, m: 1, d: 7 }).text"), "昭和64年")
        XCTAssertEqual(text(c, "Wareki.fromDate({ y: 1989, m: 1, d: 8 }).text"), "平成元年")
        XCTAssertEqual(number(c, "Wareki.toYear('R8').year"), 2026)
        XCTAssertEqual(number(c, "Wareki.toYear('平成元年').year"), 1989)
        XCTAssertEqual(number(c, "Wareki.toYear('Ｓ６４').year"), 1989)
        XCTAssertEqual(text(c, "String(Wareki.toYear('2019'))"), "null")
        XCTAssertEqual(text(c, "Wareki.zodiac(2026)"), "午")
        XCTAssertEqual(number(c, "Wareki.age({ y: 2000, m: 4, d: 1 }, { y: 2026, m: 3, d: 31 })"), 25)
        XCTAssertEqual(number(c, "Wareki.age({ y: 2000, m: 4, d: 1 }, { y: 2026, m: 4, d: 1 })"), 26)
        XCTAssertEqual(number(c, "Wareki.daysToBirthday({ y: 2000, m: 2, d: 29 }, { y: 2026, m: 2, d: 28 })"), 1)
    }

    // MARK: - 計算

    func testSplitBillPercentUnitsAndBases() throws {
        let b = try context("split-bill")
        XCTAssertEqual(text(b, "JSON.stringify(SplitBill.calculate(10000, 3, 100))"), #"{"perPerson":3400,"collected":10200,"surplus":200}"#)
        XCTAssertEqual(text(b, "JSON.stringify(SplitBill.calculate(10000, 3, 1))"), #"{"perPerson":3334,"collected":10002,"surplus":2}"#)
        XCTAssertEqual(text(b, "JSON.stringify(SplitBill.organizer(10000, 3, 1000))"), #"{"others":3000,"organizer":4000}"#)
        XCTAssertEqual(text(b, "String(SplitBill.calculate(100, 0, 1))"), "null")
        let p = try context("percent")
        XCTAssertEqual(number(p, "PercentCalc.discounted(1000, 30)"), 700)
        XCTAssertEqual(number(p, "PercentCalc.withTax(1000, 10)"), 1100)
        XCTAssertEqual(number(p, "PercentCalc.withoutTax(1100, 10)"), 1000)
        XCTAssertEqual(number(p, "PercentCalc.withTax(108, 8)"), 116)
        XCTAssertEqual(number(p, "PercentCalc.ratio(30, 120)"), 25)
        let u = try context("unit-convert")
        XCTAssertEqual(number(u, "Units.convert(1, '長さ', Units.index('長さ', 'インチ'), Units.index('長さ', 'cm'))"), 2.54, accuracy: 1e-9)
        XCTAssertEqual(number(u, "Units.convert(100, '温度', 0, 1)"), 212, accuracy: 1e-9)
        XCTAssertEqual(number(u, "Units.convert(0, '温度', 2, 0)"), -273.15, accuracy: 1e-9)
        XCTAssertEqual(number(u, "Units.convert(1, '面積', Units.index('面積', '坪'), Units.index('面積', 'm²'))"), 400.0 / 121, accuracy: 1e-9)
        let x = try context("base-convert")
        XCTAssertEqual(text(x, "BaseConvert.format(BaseConvert.parse('FF', 16), 2)"), "11111111")
        XCTAssertEqual(text(x, "BaseConvert.format(BaseConvert.parse('0b1010_1010', 2), 16)"), "AA")
        XCTAssertEqual(text(x, "BaseConvert.format(BaseConvert.parse('-255', 10), 16)"), "-FF")
        XCTAssertEqual(text(x, "BaseConvert.format(BaseConvert.parse('18446744073709551616', 10), 16)"), "10000000000000000")
        XCTAssertEqual(text(x, "String(BaseConvert.parse('12', 2))"), "null")
        XCTAssertEqual(text(x, "BaseConvert.grouped('11111111', 4)"), "1111 1111")
    }

    // MARK: - 決める・遊ぶ

    func testTournamentPairingAndAdvancing() throws {
        let c = try context("tournament")
        XCTAssertEqual(text(c, "JSON.stringify(Tournament.seedOrder(8))"), "[1,8,4,5,2,7,3,6]")
        XCTAssertEqual(text(c, "String(Tournament.make(['A']))"), "null")
        // 6人は8枠。第1・第2シードは不戦勝で2回戦へ
        c.evaluateScript("var t = Tournament.make(['A', 'B', 'C', 'D', 'E', 'F']);")
        XCTAssertEqual(number(c, "t.rounds.length"), 3)
        XCTAssertEqual(text(c, "JSON.stringify(t.rounds[0])"),
                       #"[{"a":0,"b":null,"winner":0},{"a":3,"b":4,"winner":null},{"a":1,"b":null,"winner":1},{"a":2,"b":5,"winner":null}]"#)
        XCTAssertEqual(text(c, "JSON.stringify([t.rounds[1][0].a, t.rounds[1][1].a])"), "[0,1]")
        XCTAssertTrue(bool(c, "Tournament.seeded(t, 0) && !Tournament.seeded(t, 1)"))
        // 第1と第2シードは決勝まで当たらない(64人でも)
        c.evaluateScript("var big = Tournament.make(Array.from({ length: 64 }, function (_, i) { return 'P' + i; }));")
        XCTAssertTrue(bool(c, "big.rounds[0].slice(0, 16).some(function (m) { return m.a === 0 || m.b === 0; }) && big.rounds[0].slice(16).some(function (m) { return m.a === 1 || m.b === 1; })"))
        // 勝ち上がりと、先の結果の取り消し
        c.evaluateScript("Tournament.setWinner(t, 0, 1, 3); Tournament.setWinner(t, 1, 0, 3); Tournament.setWinner(t, 0, 3, 2); Tournament.setWinner(t, 1, 1, 1); Tournament.setWinner(t, 2, 0, 3);")
        XCTAssertEqual(number(c, "Tournament.champion(t)"), 3)
        c.evaluateScript("Tournament.setWinner(t, 0, 1, 4);")
        XCTAssertEqual(text(c, "JSON.stringify([t.rounds[1][0].b, t.rounds[1][0].winner, t.rounds[2][0].a, Tournament.champion(t)])"), "[4,null,null,null]")
        // 試合にいない参加者は勝者にできない。同じ名前でも番号で区別する
        XCTAssertFalse(bool(c, "Tournament.setWinner(t, 0, 1, 0)"))
        c.evaluateScript("var same = Tournament.make(['A', 'A']); Tournament.setWinner(same, 0, 0, 1);")
        XCTAssertEqual(number(c, "Tournament.champion(same)"), 1)
    }

    func testRouletteStopsOnChosenItem() throws {
        let c = try context("roulette")
        for n in [2, 3, 5, 12, 30] {
            for index in 0..<n {
                for offset in [0.0, 0.5, 0.999] {
                    let expression = "(function () { var r = Roulette.stopRotation(1.3, \(index), \(n), \(offset), 4); return [Roulette.indexAt(r, \(n)), r >= 1.3 + 8 * Math.PI]; })()"
                    XCTAssertEqual(text(c, expression), "\(index),true", "n=\(n) index=\(index)")
                }
            }
        }
        XCTAssertEqual(number(c, "Roulette.pick(4, function () { return 0.999999; })"), 3)
        XCTAssertEqual(number(c, "Roulette.pick(4, function () { return 0; })"), 0)
        XCTAssertEqual(number(c, "Roulette.ease(1)"), 1)
        XCTAssertEqual(text(c, "JSON.stringify(Roulette.remaining(['a', 'b', 'c'], [1]))"), "[0,2]")
        // 抽選がかたよらない(各項目が 1/n ± 20% 程度)
        let counts = text(c, "(function () { var c = [0, 0, 0, 0]; for (var i = 0; i < 4000; i++) c[Roulette.pick(4, R)]++; return c.join(','); })()")
            .split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(counts.count, 4)
        XCTAssertTrue(counts.allSatisfy { (800...1200).contains($0) }, "\(counts)")
    }

    func testTeamsOrderDiceAndCoin() throws {
        let c = try context("teams")
        c.evaluateScript("var names = ['a', 'b', 'c', 'd', 'e', 'f', 'g']; var teams = Teams.split(names, 3, R);")
        XCTAssertEqual(text(c, "teams.map(function (t) { return t.length; }).join(',')"), "3,2,2")
        XCTAssertEqual(text(c, "[].concat.apply([], teams).sort().join('')"), "abcdefg")
        XCTAssertEqual(number(c, "Teams.split(['a', 'b'], 5, R).length"), 2)
        let o = try context("order")
        XCTAssertEqual(text(o, "Order.make(['x', 'y', 'z'], R).slice().sort().join('')"), "xyz")
        let d = try context("dice")
        XCTAssertTrue(bool(d, "Dice.roll(1000, 6, R).every(function (v) { return v >= 1 && v <= 6; })"))
        XCTAssertEqual(number(d, "Dice.roll(3, 6, function () { return 0.9999999; }).length"), 3)
        XCTAssertEqual(number(d, "Dice.sum([1, 2, 6])"), 9)
        XCTAssertEqual(number(d, "Dice.pips(5).length"), 5)
        let coin = try context("coin")
        XCTAssertEqual(number(coin, "Coin.halfTurns(0, 0, 9)"), 10)
        XCTAssertEqual(number(coin, "Coin.halfTurns(0, 1, 9)"), 9)
        XCTAssertEqual(number(coin, "Coin.faceAt(0, 9 * Math.PI)"), 1)
        XCTAssertEqual(number(coin, "Coin.faceAt(1, 10 * Math.PI)"), 1)
    }

    func testAmidaIsFairLadder() throws {
        let c = try context("amida")
        for n in 2...8 {
            c.evaluateScript("var rungs = Amida.make(\(n), 12, R);")
            XCTAssertTrue(bool(c, "Amida.isPermutation(rungs, \(n))"), "n=\(n)")
            // どの間にも1本以上、同じ段で隣り合わない
            XCTAssertTrue(bool(c, "(function () { for (var g = 0; g < \(n) - 1; g++) if (!rungs.some(function (r) { return r[g]; })) return false; return true; })()"))
            XCTAssertTrue(bool(c, "rungs.every(function (r) { return r.every(function (on, g) { return !(on && r[g + 1]); }); })"))
        }
        // 横線が1本なら、その2本が入れ替わる
        XCTAssertEqual(number(c, "Amida.trace([[true, false]], 0).end"), 1)
        XCTAssertEqual(number(c, "Amida.trace([[false, true]], 2).end"), 1)
        XCTAssertEqual(text(c, "Amida.trace([[true, false], [false, true]], 0).cols.join(',')"), "0,1,2")
    }

    func testCounterAndScoreboard() throws {
        let c = try context("counter")
        c.evaluateScript("var list = []; for (var i = 1; i <= 9; i++) Counter.add(list, '', i);")
        XCTAssertEqual(number(c, "list.length"), 8)
        XCTAssertEqual(text(c, "list[0].name"), "カウンター1")
        XCTAssertEqual(number(c, "(function () { list[0].value = 999999; return Counter.step(list[0], 1); })()"), 999_999)
        XCTAssertEqual(number(c, "Counter.step(list[1], -3)"), -3)
        let s = try context("scoreboard")
        s.evaluateScript("var b = Score.make(3); Score.add(b, 0, 5); Score.add(b, 1, 3);")
        XCTAssertEqual(number(s, "Score.finishSet(b)"), 0)
        XCTAssertEqual(text(s, "b.teams.map(function (t) { return t.sets + ':' + t.points; }).join(',')"), "1:0,0:0,0:0")
        // 同点ならセットを付けない
        s.evaluateScript("Score.add(b, 1, 2); Score.add(b, 2, 2);")
        XCTAssertEqual(number(s, "Score.finishSet(b)"), -1)
        XCTAssertEqual(number(s, "Score.add(b, 0, -5)"), 0)
    }

    // MARK: - 文字

    func testTextCountKanaAndPassword() throws {
        let t = try context("text-count")
        XCTAssertEqual(text(t, "JSON.stringify(TextCount.count('あい u\\nｱB'))"),
                       #"{"all":7,"noNewline":6,"noSpace":5,"halfUnits":8,"lines":2,"bytes":13}"#)
        XCTAssertEqual(number(t, "TextCount.count('').lines"), 0)
        let k = try context("kana-convert")
        XCTAssertEqual(text(k, "Kana.toKatakana('ひらがなゝ')"), "ヒラガナヽ")
        XCTAssertEqual(text(k, "Kana.toHiragana('カタカナヴ')"), "かたかなゔ")
        XCTAssertEqual(text(k, "Kana.toHalf('ガギグ　ＡＢＣ１パ')"), "ｶﾞｷﾞｸﾞ ABC1ﾊﾟ")
        XCTAssertEqual(text(k, "Kana.toFull('ｶﾞｷﾞｸﾞ ABC1ﾊﾟｳﾞ')"), "ガギグ　ＡＢＣ１パヴ")
        // ひらがなの濁点は、半角にしてもそのまま
        XCTAssertEqual(text(k, "Kana.toHalf('がっこう')"), "がっこう")
        XCTAssertEqual(text(k, "Kana.toHalf('ＡＢガ', { alnum: true, kana: false })"), "ABガ")
        XCTAssertEqual(text(k, "Kana.convert('ｶﾞｯｺｳ', 'カタカナ→ひらがな')"), "がっこう")
        let p = try context("password")
        let options = "{ length: 20, lower: true, upper: true, digits: true, symbols: true, noAmbiguous: true }"
        let rnd = "function (a, b) { return a + Math.floor((b - a + 1) * R()); }"
        for _ in 0..<20 {
            let made = text(p, "Password.make(\(options), \(rnd))")
            XCTAssertEqual(made.count, 20)
            XCTAssertTrue(made.contains { $0.isLowercase } && made.contains { $0.isUppercase } && made.contains { $0.isNumber })
            XCTAssertTrue(made.contains { "!#$%&*+-=?@_".contains($0) })
            XCTAssertFalse(made.contains { "0Oo1lI".contains($0) })
        }
        XCTAssertEqual(text(p, "String(Password.make({ length: 8 }, \(rnd)))"), "null")
        XCTAssertEqual(number(p, "Password.bits({ length: 16, digits: true })"), 53)
        XCTAssertEqual(text(p, "Password.numbers(1, 5, 5, true, \(rnd)).slice().sort().join(',')"), "1,2,3,4,5")
        XCTAssertEqual(text(p, "String(Password.numbers(1, 3, 5, true, \(rnd)))"), "null")
        XCTAssertEqual(number(p, "Password.numbers(9, 1, 10, false, \(rnd)).filter(function (v) { return v < 1 || v > 9; }).length"), 0)
    }
}

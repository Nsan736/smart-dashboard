import XCTest
@testable import SmartDashboard

/// 決まった順に値を返す乱数(テスト用)
private struct FixedGenerator: RandomNumberGenerator {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// 小ツール: 検索、お気に入り、式の評価器、JSONの読み込みと検証
final class ToolFrameworkTests: XCTestCase {
    // MARK: - 検索

    func testSearchAbsorbsNotationDifferences() {
        let all = BuiltinTools.all
        func names(_ query: String) -> [String] { ToolSearch.filter(all, query: query).map(\.name) }
        // ひらがな・カタカナ・全角・大文字小文字・長音の違いを吸収する
        XCTAssertEqual(names("わりかん"), ["割り勘"])
        XCTAssertEqual(names("ワリカン"), ["割り勘"])
        XCTAssertTrue(names("ＴＩＭＥＲ").contains("タイマー"))
        XCTAssertTrue(names("たいまー").contains("タイマー"))
        XCTAssertTrue(names("とーなめんと").contains("トーナメント表"))
        XCTAssertTrue(names("トナメント").contains("トーナメント表"))
        // 説明とカテゴリも対象。複数の語は、すべて含むものだけ
        XCTAssertTrue(names("消費税").contains("パーセント・割引・消費税"))
        XCTAssertEqual(names("日付 計算"), ["日付計算"])
        XCTAssertTrue(names("存在しないツール").isEmpty)
        XCTAssertEqual(names("  ").count, all.count)
        XCTAssertEqual(ToolSearch.normalize("ＡＢｃ　カタ・カナー"), "abcかたかな")
    }

    func testBuiltinRegistryIsConsistent() {
        // すべての内蔵ツールが1回ずつ登録されていて、IDが重ならない
        XCTAssertEqual(BuiltinTools.all.count, BuiltinTool.allCases.count)
        XCTAssertEqual(Set(BuiltinTools.all.map(\.id)).count, BuiltinTools.all.count)
        XCTAssertTrue(BuiltinTools.all.allSatisfy { $0.id.hasPrefix("builtin.") && !$0.name.isEmpty && !$0.keywords.isEmpty })
        // タイマーとストップウォッチは、小ツールの中にある
        XCTAssertTrue(BuiltinTools.all.contains { $0.source == .builtin(.timer) && $0.category == .time })
        XCTAssertTrue(BuiltinTools.all.contains { $0.source == .builtin(.stopwatch) })
    }

    func testFavoritesAndRecents() {
        XCTAssertEqual(ToolLibrary.toggled(["a"], "b"), ["a", "b"])
        XCTAssertEqual(ToolLibrary.toggled(["a", "b"], "a"), ["b"])
        // 最近使ったものは先頭へ。同じものは1つだけ。上限まで
        XCTAssertEqual(ToolLibrary.pushedRecent(["a", "b", "c"], "b"), ["b", "a", "c"])
        XCTAssertEqual(ToolLibrary.pushedRecent(["a", "b", "c"], "d", limit: 3), ["d", "a", "b"])
    }

    func testTabAndHomeMigration() {
        // 以前の「タイマー」のタブは、同じ位置で「小ツール」になる
        let order = TabOrder.decode(["home", "timer", "weather", "waypoint", "train", "exchange", "sensors", "settings"])
        XCTAssertEqual(order[1], .tools)
        XCTAssertEqual(order.count, AppTab.allCases.count)
        // 初期の並びでは「その他」の中
        XCTAssertTrue(TabOrder.isInMore(.tools, order: TabOrder.initial))
        // ホームのタイマーのカードは、そのまま残る
        XCTAssertTrue(HomeLayout.initial.shows(.timer))
        XCTAssertTrue(HomeLayout.initial.order.contains(.tools))
    }

    // MARK: - 式の評価器

    private func value(_ source: String, _ values: [String: Double] = [:]) throws -> Double {
        try ToolExpression(source).evaluate(values)
    }

    func testExpressionArithmetic() throws {
        XCTAssertEqual(try value("1 + 2 * 3"), 7)
        XCTAssertEqual(try value("(1 + 2) * 3"), 9)
        XCTAssertEqual(try value("7 / 2"), 3.5)
        XCTAssertEqual(try value("10 % 3"), 1)
        XCTAssertEqual(try value("2 ^ 3 ^ 2"), 512)
        XCTAssertEqual(try value("-2 ^ 2"), -4)
        XCTAssertEqual(try value("- -3"), 3)
        XCTAssertEqual(try value("1.5 * 2"), 3)
        XCTAssertEqual(try value("a * b + a", ["a": 3, "b": 4]), 15)
        XCTAssertEqual(try ToolExpression("a * b + a").variables, ["a", "b"])
    }

    func testExpressionComparisonLogicAndFunctions() throws {
        XCTAssertEqual(try value("3 > 2"), 1)
        XCTAssertEqual(try value("1 == 2"), 0)
        XCTAssertEqual(try value("!(1 > 2) && 2 <= 2"), 1)
        XCTAssertEqual(try value("0 || 0"), 0)
        // if は、条件に合うほうだけを計算する(0で割る式を避けられる)
        XCTAssertEqual(try value("if(x > 0, 10 / x, 0)", ["x": 0]), 0)
        XCTAssertEqual(try value("if(x > 0, 10 / x, 0)", ["x": 4]), 2.5)
        XCTAssertEqual(try value("0 && 1 / 0"), 0)
        XCTAssertEqual(try value("round(2.5)"), 3)
        XCTAssertEqual(try value("round(-2.5)"), -3)
        XCTAssertEqual(try value("round(1234.567, 1)"), 1234.6, accuracy: 1e-9)
        XCTAssertEqual(try value("floor(2.9) + ceil(2.1) + trunc(-2.9)"), 3)
        XCTAssertEqual(try value("min(3, 1, 2) + max(3, 1, 2)"), 4)
        XCTAssertEqual(try value("sqrt(16) + abs(-3) + pow(2, 10)"), 1031)
        XCTAssertEqual(try value("sin(90) + cos(0)"), 2, accuracy: 1e-9)
        XCTAssertEqual(try value("days(10, 17)"), 7)
        XCTAssertEqual(try value("clamp(15, 0, 10) + mod(17, 7)"), 13)
        XCTAssertEqual(try value("2 * pi"), 2 * Double.pi, accuracy: 1e-12)
    }

    func testExpressionErrorsAreDetected() {
        func error(_ source: String, _ values: [String: Double] = [:], known: Set<String> = []) -> ToolExpressionError? {
            do {
                let expression = try ToolExpression(source)
                try expression.check(knownVariables: known.union(values.keys))
                _ = try expression.evaluate(values)
                return nil
            } catch {
                return error as? ToolExpressionError
            }
        }
        XCTAssertEqual(error("1 +"), .syntax("式が途中で終わっています", position: 3))
        XCTAssertEqual(error("(1 + 2"), .syntax("「)」が足りません", position: 6))
        XCTAssertEqual(error("1 $ 2"), .syntax("使えない文字です: $", position: 2))
        XCTAssertEqual(error("1 2"), .syntax("ここで式が終わるはずです", position: 2))
        XCTAssertEqual(error("1.2.3"), .syntax("数として読めません: 1.2.3", position: 0))
        XCTAssertEqual(error("price * 2"), .unknownVariable("price"))
        XCTAssertEqual(error("system(1)"), .unknownFunction("system"))
        XCTAssertEqual(error("min()"), .wrongArgumentCount("min", expected: "1〜8個"))
        XCTAssertEqual(error("if(1, 2)"), .wrongArgumentCount("if", expected: "3個"))
        XCTAssertEqual(error("10 / x", ["x": 0]), .divisionByZero)
        XCTAssertEqual(error("sqrt(-1)"), .notFinite)
        XCTAssertEqual(error("10 ^ 400"), .notFinite)
        XCTAssertNotNil(ToolExpressionError.divisionByZero.message)
    }

    func testExpressionLimits() throws {
        // 長さ
        XCTAssertThrowsError(try ToolExpression(String(repeating: "1+", count: 250) + "1")) { XCTAssertEqual($0 as? ToolExpressionError, .tooLong) }
        XCTAssertNoThrow(try ToolExpression(String(repeating: "1+", count: 249) + "1"))
        // 入れ子の深さ
        let deep = String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40)
        XCTAssertThrowsError(try ToolExpression(deep)) { XCTAssertEqual($0 as? ToolExpressionError, .tooDeep) }
        XCTAssertEqual(try value(String(repeating: "(", count: 10) + "1" + String(repeating: ")", count: 10)), 1)
        // 計算の回数
        let expression = try ToolExpression("1 + 2 + 3 + 4 + 5")
        XCTAssertThrowsError(try expression.evaluate([:], stepLimit: 4)) { XCTAssertEqual($0 as? ToolExpressionError, .tooManySteps) }
        XCTAssertEqual(try expression.evaluate([:], stepLimit: 9), 15)
        XCTAssertLessThanOrEqual(ToolExpression.maxSteps, 10_000)
    }

    // MARK: - JSONの読み込みと検証

    private func fixture(_ name: String) throws -> String {
        try XCTUnwrap(String(data: Fixture.data(name), encoding: .utf8))
    }

    private func tool(_ name: String) throws -> CustomTool {
        guard case .success(let tool) = CustomToolParser.parse(try fixture(name)) else {
            XCTFail("\(name) を読み込めません")
            throw ToolExpressionError.tooLong
        }
        return tool
    }

    func testSampleToolsAreValid() throws {
        // examples/tools/ と同じ内容
        let fuel = try tool("tool_fuel_economy")
        XCTAssertEqual(fuel.kind, .calc)
        XCTAssertEqual(fuel.category, .calc)
        XCTAssertEqual(fuel.inputs.map(\.id), ["distance", "fuel", "price", "people"])
        let results = CustomToolParser.evaluate(fuel, values: ["distance": 400, "fuel": 30, "price": 170, "people": 2])
        XCTAssertEqual(results.map(\.text), ["13.3 km/L", "5,100 円", "12.8 円", "2,550 円"])
        XCTAssertFalse(results.contains { $0.isError })
        // 0で割る入力でも、if で避けている
        XCTAssertEqual(CustomToolParser.evaluate(fuel, values: ["distance": 0, "fuel": 0, "price": 170, "people": 1]).first?.text, "0.0 km/L")

        let days = try tool("tool_days_until")
        XCTAssertEqual(CustomToolParser.evaluate(days, values: ["start": 100, "goal": 117]).map(\.text), ["17日", "2 週", "3日"])

        let table = try tool("tool_clothing_size")
        XCTAssertEqual(table.columns.count, 4)
        XCTAssertEqual(table.rows.count, 5)
        XCTAssertEqual(CustomToolTable.filter(table.rows, query: "ｌｌ").map { $0[0] }, ["LL(XL)"])
        XCTAssertEqual(CustomToolTable.filter(table.rows, query: "").count, 5)

        XCTAssertEqual(try tool("tool_travel_packing").kind, .checklist)
        let lunch = try tool("tool_lunch_roulette")
        XCTAssertEqual(lunch.listMode, .roulette)
        XCTAssertEqual(lunch.items.count, 9)
        // 読み込んだツールも、内蔵と同じく検索できる
        let descriptor = ToolDescriptor(lunch)
        XCTAssertEqual(descriptor.id, "custom.lunch-roulette")
        XCTAssertTrue(ToolSearch.matches(descriptor, query: "ランチ"))
        XCTAssertTrue(ToolSearch.matches(descriptor, query: "ひるごはん"))
    }

    func testValidationPointsToTheProblem() {
        func issues(_ json: String) -> [String] {
            guard case .failure(let issues) = CustomToolParser.parse(json) else { return [] }
            return issues.map(\.path)
        }
        XCTAssertEqual(issues("{ not json"), ["全体"])
        XCTAssertEqual(issues("[1, 2]"), ["全体"])
        XCTAssertEqual(issues(#"{"format":1,"id":"a","type":"calc","inputs":[],"outputs":[{"label":"x","formula":"1"}]}"#), ["name"])
        XCTAssertEqual(issues(#"{"format":2,"id":"a","name":"A","type":"list","items":["x"]}"#), ["format"])
        XCTAssertEqual(issues(#"{"format":1,"id":"a b","name":"A","type":"list","items":["x"]}"#), ["id"])
        XCTAssertEqual(issues(#"{"format":1,"id":"a","name":"A","type":"script","code":"x"}"#), ["type"])
        XCTAssertEqual(issues(#"{"format":1,"id":"a","name":"A","type":"list","mode":"spin","items":["x"]}"#), ["mode"])
        XCTAssertEqual(issues(#"{"format":1,"id":"a","name":"A","type":"checklist","items":[]}"#), ["items"])
        XCTAssertEqual(issues(#"{"format":1,"id":"a","name":"A","type":"table","columns":["x","y"],"rows":[["1","2"],["3"]]}"#), ["rows[1]"])
        // 式の誤りは、どの出力の式かが分かる
        let calc = #"{"format":1,"id":"a","name":"A","type":"calc","inputs":[{"id":"x","label":"X","type":"number"}],"outputs":[{"label":"ok","formula":"x*2"},{"label":"ng","formula":"y + 1"}]}"#
        XCTAssertEqual(issues(calc), ["outputs[1].formula"])
        if case .failure(let found) = CustomToolParser.parse(calc) { XCTAssertEqual(found.first?.message, "「y」という入力欄はありません") }
        // 入力欄の名前の重複、関数と同じ名前、真偽値を数として受け取らない
        let inputs = #"{"format":1,"id":"a","name":"A","type":"calc","inputs":[{"id":"x","label":"X","type":"number","default":true},{"id":"x","label":"X2","type":"number"},{"id":"min","label":"M","type":"number"},{"id":"c","label":"C","type":"choice","options":[]}],"outputs":[{"label":"o","formula":"x"}]}"#
        XCTAssertEqual(issues(inputs), ["inputs[0].default", "inputs[1].id", "inputs[2].id", "inputs[3].options"])
        // 大きすぎるものは読まない
        XCTAssertEqual(issues(String(repeating: " ", count: CustomToolParser.maxBytes + 1)), ["全体"])
    }
}

/// 内蔵ツールの計算
final class BuiltinToolLogicTests: XCTestCase {
    func testSplitBillRounding() {
        // 10,000円を3人で。足りなくならないよう、切り上げる
        XCTAssertEqual(SplitBill.calculate(total: 10_000, people: 3, rounding: .none), SplitBill.Result(perPerson: 3334, collected: 10_002, surplus: 2))
        XCTAssertEqual(SplitBill.calculate(total: 10_000, people: 3, rounding: .up10)?.perPerson, 3340)
        XCTAssertEqual(SplitBill.calculate(total: 10_000, people: 3, rounding: .up100), SplitBill.Result(perPerson: 3400, collected: 10_200, surplus: 200))
        XCTAssertEqual(SplitBill.calculate(total: 10_000, people: 3, rounding: .up500)?.perPerson, 3500)
        XCTAssertEqual(SplitBill.calculate(total: 10_000, people: 3, rounding: .up1000)?.perPerson, 4000)
        // 割り切れるときは、余りなし
        XCTAssertEqual(SplitBill.calculate(total: 9000, people: 3, rounding: .up100)?.surplus, 0)
        XCTAssertNil(SplitBill.calculate(total: 1000, people: 0, rounding: .none))
        XCTAssertNil(SplitBill.calculate(total: -1, people: 2, rounding: .none))
    }

    func testPercentAndTax() {
        XCTAssertEqual(PercentCalc.discounted(price: 1980, percentOff: 20), 1584)
        XCTAssertEqual(PercentCalc.discounted(price: 1000, percentOff: 30), 700)
        XCTAssertEqual(PercentCalc.withTax(price: 1000, rate: 10), 1100)
        XCTAssertEqual(PercentCalc.withTax(price: 999, rate: 8), 1078)
        // 2進数の誤差で1円ずれない
        XCTAssertEqual(PercentCalc.withoutTax(price: 1100, rate: 10), 1000)
        XCTAssertEqual(PercentCalc.withoutTax(price: 1080, rate: 8), 1000)
        XCTAssertEqual(PercentCalc.ratio(30, of: 120), 25)
        XCTAssertNil(PercentCalc.ratio(1, of: 0))
    }

    func testUnitConversion() throws {
        func convert(_ value: Double, _ kind: UnitKind, _ from: String, _ to: String) throws -> Double {
            let names = kind.units.map(\.name)
            return try XCTUnwrap(UnitConverter.convert(value, kind: kind, from: try XCTUnwrap(names.firstIndex(of: from)), to: try XCTUnwrap(names.firstIndex(of: to))))
        }
        XCTAssertEqual(try convert(1, .length, "インチ", "cm"), 2.54, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, .length, "マイル", "km"), 1.609344, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, .weight, "ポンド", "g"), 453.59237, accuracy: 1e-6)
        XCTAssertEqual(try convert(100, .temperature, "℃", "℉"), 212, accuracy: 1e-9)
        XCTAssertEqual(try convert(32, .temperature, "℉", "K"), 273.15, accuracy: 1e-9)
        XCTAssertEqual(try convert(1, .area, "坪", "m²"), 3.305785, accuracy: 1e-6)
        XCTAssertEqual(try convert(1, .volume, "L", "mL"), 1000, accuracy: 1e-9)
        XCTAssertEqual(try convert(60, .speed, "km/h", "m/s"), 16.6666667, accuracy: 1e-6)
        XCTAssertNil(UnitConverter.convert(1, kind: .length, from: 0, to: 99))
        XCTAssertEqual(Set(UnitKind.allCases.map(\.label)), ["長さ", "重さ", "温度", "面積", "体積", "速度"])
    }

    func testBaseConversion() {
        XCTAssertEqual(BaseConverter.convert("255", from: 10, to: 16), "FF")
        XCTAssertEqual(BaseConverter.convert("ff", from: 16, to: 2), "11111111")
        XCTAssertEqual(BaseConverter.convert("-10", from: 10, to: 2), "-1010")
        XCTAssertEqual(BaseConverter.convert("1111_0000", from: 2, to: 10), "240")
        XCTAssertNil(BaseConverter.convert("12", from: 2, to: 10))
        XCTAssertNil(BaseConverter.convert("", from: 10, to: 2))
    }

    func testWareki() {
        // 元号の切り替わりの日
        XCTAssertEqual(Wareki.text(year: 2019, month: 4, day: 30), "平成31年")
        XCTAssertEqual(Wareki.text(year: 2019, month: 5, day: 1), "令和元年")
        XCTAssertEqual(Wareki.text(year: 2026, month: 9, day: 20), "令和8年")
        XCTAssertEqual(Wareki.text(year: 1989, month: 1, day: 7), "昭和64年")
        XCTAssertEqual(Wareki.text(year: 1989, month: 1, day: 8), "平成元年")
        XCTAssertEqual(Wareki.text(year: 1926, month: 12, day: 24), "大正15年")
        XCTAssertNil(Wareki.text(year: 1868, month: 1, day: 24))
        XCTAssertEqual(Wareki.westernYear(era: "平成", year: 1), 1989)
        XCTAssertEqual(Wareki.westernYear(era: "令和", year: 8), 2026)
        XCTAssertEqual(Wareki.westernYear(era: "昭和", year: 64), 1989)
        XCTAssertNil(Wareki.westernYear(era: "令和", year: 0))
        XCTAssertNil(Wareki.westernYear(era: "未来", year: 1))
        // 満年齢は、誕生日の当日に増える
        XCTAssertEqual(Wareki.age(birthYear: 2000, birthMonth: 9, birthDay: 21, onYear: 2026, month: 9, day: 20), 25)
        XCTAssertEqual(Wareki.age(birthYear: 2000, birthMonth: 9, birthDay: 21, onYear: 2026, month: 9, day: 21), 26)
        XCTAssertEqual(Wareki.zodiac(year: 2026), "午")
        XCTAssertEqual(Wareki.zodiac(year: 2020), "子")
    }

    func testDateCalc() throws {
        let calendar = DateCalc.calendar
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 23)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 1)))
        // 時刻は無視して、日付だけで数える
        XCTAssertEqual(DateCalc.days(from: start, to: end), 30)
        XCTAssertEqual(DateCalc.days(from: end, to: start), -30)
        XCTAssertEqual(DateCalc.days(from: start, to: DateCalc.adding(days: 100, to: start)), 100)
        XCTAssertEqual(DateCalc.weekdayText(start), "日曜日")
    }

    func testTournamentSeedingAndByes() throws {
        XCTAssertEqual(Tournament.seedOrder(size: 8), [1, 8, 4, 5, 2, 7, 3, 6])
        // 5人: 8枠。第1〜3シード(A, B, C)が不戦勝
        var tournament = try XCTUnwrap(Tournament(players: ["A", "B", "C", "D", "E"]))
        XCTAssertEqual(tournament.rounds.map(\.count), [4, 2, 1])
        XCTAssertEqual(tournament.rounds[0].map(\.isBye), [true, false, true, true])
        XCTAssertEqual(tournament.rounds[0][1].first, "D")
        XCTAssertEqual(tournament.rounds[0][1].second, "E")
        // 不戦勝の人は、最初から次の試合に入っている。第1シードと第2シードは決勝まで当たらない
        XCTAssertEqual(tournament.rounds[1][0].first, "A")
        XCTAssertNil(tournament.rounds[1][0].second)
        XCTAssertEqual(tournament.rounds[1][1].first, "B")
        XCTAssertEqual(tournament.rounds[1][1].second, "C")
        // 勝者をタップして進める
        tournament.setWinner(round: 0, index: 1, name: "D")
        XCTAssertEqual(tournament.rounds[1][0].second, "D")
        tournament.setWinner(round: 1, index: 0, name: "D")
        tournament.setWinner(round: 1, index: 1, name: "B")
        XCTAssertEqual(tournament.rounds[2][0].first, "D")
        XCTAssertEqual(tournament.rounds[2][0].second, "B")
        tournament.setWinner(round: 2, index: 0, name: "B")
        XCTAssertEqual(tournament.champion, "B")
        // 前の試合の結果を変えたら、その先の結果は取り消す
        tournament.setWinner(round: 0, index: 1, name: "E")
        XCTAssertEqual(tournament.rounds[1][0].second, "E")
        XCTAssertNil(tournament.rounds[1][0].winner)
        XCTAssertNil(tournament.rounds[2][0].first)
        XCTAssertNil(tournament.champion)
        // 出場していない名前は勝者にできない
        tournament.setWinner(round: 1, index: 0, name: "Z")
        XCTAssertNil(tournament.rounds[1][0].winner)
        // 4人なら不戦勝なし。1人と65人は作れない
        XCTAssertEqual(try XCTUnwrap(Tournament(players: ["A", "B", "C", "D"])).rounds.map(\.count), [2, 1])
        XCTAssertNil(Tournament(players: ["A"]))
        XCTAssertNil(Tournament(players: (1...65).map(String.init)))
        // 保存して復元できる
        let restored = try JSONDecoder().decode(Tournament.self, from: JSONEncoder().encode(tournament))
        XCTAssertEqual(restored, tournament)
    }

    func testTeamsAndNames() {
        XCTAssertEqual(Shuffler.names(from: "A, B、C\nD\n\n ，E "), ["A", "B", "C", "D", "E"])
        var generator = FixedGenerator()
        let members = ["A", "B", "C", "D", "E", "F", "G"]
        let teams = Shuffler.teams(members, count: 3, using: &generator)
        // 人数がなるべく同じになる。全員がどこかに入る
        XCTAssertEqual(teams.map(\.count), [3, 2, 2])
        XCTAssertEqual(Set(teams.flatMap { $0 }), Set(members))
        XCTAssertEqual(Shuffler.teams(["A"], count: 3, using: &generator).map(\.count), [1])
        XCTAssertTrue(Shuffler.teams(members, count: 0, using: &generator).isEmpty)
    }

    func testTextCountAndKana() {
        let text = "abc あいう\n１２"
        let ignoring = TextCount.count(text, countsNewlines: false)
        XCTAssertEqual(ignoring.characters, 9)
        XCTAssertEqual(ignoring.charactersWithoutSpaces, 8)
        XCTAssertEqual(ignoring.halfWidthUnits, 14)
        XCTAssertEqual(ignoring.lines, 2)
        let counting = TextCount.count(text, countsNewlines: true)
        XCTAssertEqual(counting.characters, 10)
        XCTAssertEqual(counting.halfWidthUnits, 15)
        XCTAssertEqual(TextCount.count("", countsNewlines: true).lines, 0)
        // 絵文字は1文字
        XCTAssertEqual(TextCount.count("👨‍👩‍👧", countsNewlines: true).characters, 1)
        XCTAssertEqual(KanaConvert.hiragana("カタカナ"), "かたかな")
        XCTAssertEqual(KanaConvert.katakana("ひらがな"), "ヒラガナ")
        XCTAssertEqual(KanaConvert.halfWidth("ＡＢＣ１２３"), "ABC123")
        XCTAssertEqual(KanaConvert.fullWidth("abc"), "ａｂｃ")
    }

    func testPasswordGenerator() {
        var generator = FixedGenerator()
        let password = PasswordGenerator.generate(PasswordGenerator.Options(), using: &generator)
        XCTAssertEqual(password.count, 16)
        XCTAssertFalse(password.contains { "0Oo1lI".contains($0) })
        var digits = PasswordGenerator.Options(length: 8, lowercase: false, uppercase: false, digits: true, symbols: false, avoidsAmbiguous: false)
        XCTAssertTrue(PasswordGenerator.generate(digits, using: &generator).allSatisfy(\.isNumber))
        digits.digits = false
        // 文字の種類を1つも選んでいなければ、作らない
        XCTAssertEqual(PasswordGenerator.generate(digits, using: &generator), "")
        XCTAssertEqual(PasswordGenerator.alphabet(PasswordGenerator.Options()).count, 26 + 26 + 10 - 6)
    }
}

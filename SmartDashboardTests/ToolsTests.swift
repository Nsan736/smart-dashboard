import XCTest
@testable import SmartDashboard

/// 小ツール: 検索、お気に入り、式の評価器、JSONの読み込みと検証
final class ToolFrameworkTests: XCTestCase {
    // MARK: - 検索

    func testSearchAbsorbsNotationDifferences() {
        let all = BuiltinTools.withScripts
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
        // Swift の内蔵ツールは3つ(懐中電灯・世界時計・メトロノーム)。すべてが1回ずつ登録されていて、IDが重ならない
        XCTAssertEqual(BuiltinTool.allCases, [.flashlight, .worldClock, .metronome])
        XCTAssertEqual(BuiltinTools.all.count, BuiltinTool.allCases.count)
        let all = BuiltinTools.withScripts
        XCTAssertEqual(all.count, 24)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0.id.hasPrefix("builtin.") && !$0.name.isEmpty && !$0.keywords.isEmpty })
        // 並びは v0.9.32 までの内蔵ツールの並び
        XCTAssertEqual(all.map(\.id), BuiltinTools.order.map { "builtin." + $0 })
        // タイマーとストップウォッチは、小ツールの中の JavaScript 版
        XCTAssertTrue(all.contains { $0.id == "builtin.timer" && $0.isBundled && $0.category == .time })
        XCTAssertTrue(all.contains { $0.id == "builtin.stopwatch" && $0.isBundled })
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
        XCTAssertEqual(issues(#"{"format":1,"id":"a","name":"A","type":"program","code":"x"}"#), ["type"])
        // スクリプト型(v0.9.19)は、本体の script が必要
        XCTAssertEqual(issues(#"{"format":1,"id":"a","name":"A","type":"script","code":"x"}"#), ["script"])
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

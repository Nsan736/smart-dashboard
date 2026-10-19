import JavaScriptCore
import XCTest
@testable import SmartDashboard

/// v0.9.33: 消した Swift の版の内蔵ツールの保存データを、JavaScript 版に写す
final class LegacyToolMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var directory: URL!
    private let suite = "LegacyToolMigrationTests"

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func stored(_ file: String, _ key: String) throws -> [String: Any] {
        let storage = ScriptStorage(fileURL: ScriptStorage.storageURL(toolID: BuiltinScriptTools.idPrefix + file, directory: directory))
        let text = try XCTUnwrap(storage.get(key), "\(file).\(key)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Swift の版と同じ形(JSONEncoder の既定。日付は 2001年からの秒)で保存する
    private func setJSON(_ json: String, _ key: String) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    func testMovesSavedDataToJavaScriptVersions() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ref = now.timeIntervalSinceReferenceDate
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        setJSON("""
        [{"id":"\(a.uuidString)","label":"パスタ","duration":420,"endDate":\(ref + 120),"didAlert":false},
         {"id":"\(b.uuidString)","label":"5分","duration":300,"pausedRemaining":100.5,"didAlert":false},
         {"id":"\(c.uuidString)","label":"終わった","duration":60,"endDate":\(ref - 10),"didAlert":true},
         {"id":"\(d.uuidString)","label":"","duration":90,"didAlert":false}]
        """, LegacyToolMigration.Keys.timers)
        setJSON(#"{"startedAt":\#(ref - 30),"accumulated":12.5,"lapTotals":[5,10.25]}"#, LegacyToolMigration.Keys.stopwatch)
        defaults.set(true, forKey: LegacyToolMigration.Keys.timerKeepAwake)
        defaults.set("カレー\nうどん", forKey: LegacyToolMigration.Keys.rouletteItems)
        defaults.set("Aさん\nBさん\nCさん", forKey: LegacyToolMigration.Keys.members)
        defaults.set("当たり\nはずれ", forKey: LegacyToolMigration.Keys.amidaGoals)
        setJSON(#"[{"id":"\#(UUID().uuidString)","name":"来場者","value":12},{"id":"\#(UUID().uuidString)","name":"退場","value":-3}]"#,
                LegacyToolMigration.Keys.counters)
        setJSON(#"{"teams":[{"id":"\#(UUID().uuidString)","name":"赤","score":3,"sets":1},{"id":"\#(UUID().uuidString)","name":"白","score":5,"sets":0}]}"#,
                LegacyToolMigration.Keys.scoreboard)
        defaults.set("A\nB\nC", forKey: LegacyToolMigration.Keys.tournamentPlayers)
        // 3人(4枠)。A はシードで勝ち上がり、B が C に勝った
        setJSON(#"{"rounds":[[{"round":0,"index":0,"first":"A","winner":"A"},{"round":0,"index":1,"first":"B","second":"C","winner":"B"}],[{"round":1,"index":0,"first":"A","second":"B"}]]}"#,
                LegacyToolMigration.Keys.tournamentState)

        let outcome = LegacyToolMigration.migrate(defaults: defaults, directory: directory, now: now)
        XCTAssertEqual(Set(outcome.moved), ["timer", "stopwatch", "roulette", "teams", "order", "amida", "counter", "scoreboard", "tournament"])
        XCTAssertEqual(outcome.kept, [])
        XCTAssertEqual(outcome.dropped, ["timer.keepAwake"])

        // タイマー: 動いている・一時停止・終わった・止まっている
        let timers = try stored("timer", "timers")
        let list = try XCTUnwrap(timers["list"] as? [[String: Any]])
        XCTAssertEqual(list.map { $0["state"] as? String }, ["running", "paused", "done", "idle"])
        XCTAssertEqual(list[0]["endAt"] as? Double, (now.timeIntervalSince1970 + 120) * 1000)
        XCTAssertEqual(list[0]["label"] as? String, "パスタ")
        XCTAssertEqual(list[1]["left"] as? Double, 100.5)
        XCTAssertEqual(list[3]["total"] as? Double, 90)
        XCTAssertEqual(timers["nextID"] as? Int, 5)
        // Swift の版の通知は取り消し、動いているものだけを JavaScript 版の通知に予約し直す
        XCTAssertEqual(outcome.cancelNotifications, [a, b, c, d].map(\.uuidString))
        XCTAssertEqual(outcome.schedules, [LegacyToolMigration.Schedule(id: "t1", seconds: 120, title: "パスタが終わりました", body: "7:00 のタイマー")])

        let watch = try stored("stopwatch", "stopwatch")
        XCTAssertEqual(watch["startedAt"] as? Double, (now.timeIntervalSince1970 - 30) * 1000)
        XCTAssertEqual(watch["elapsed"] as? Double, 12_500)
        XCTAssertEqual(watch["laps"] as? [Double], [5000, 10250])

        XCTAssertEqual(try stored("roulette", "roulette")["itemsText"] as? String, "カレー\nうどん")
        XCTAssertEqual(try stored("teams", "teams")["namesText"] as? String, "Aさん\nBさん\nCさん")
        XCTAssertEqual(try stored("order", "order")["namesText"] as? String, "Aさん\nBさん\nCさん")
        let amida = try stored("amida", "amida")
        XCTAssertEqual(amida["prizesText"] as? String, "当たり\nはずれ")
        XCTAssertEqual(amida["namesText"] as? String, "Aさん\nBさん\nCさん")

        let counters = try XCTUnwrap(try stored("counter", "counter")["list"] as? [[String: Any]])
        XCTAssertEqual(counters.map { $0["name"] as? String }, ["来場者", "退場"])
        XCTAssertEqual(counters.map { $0["value"] as? Int }, [12, -3])

        let teams = try XCTUnwrap(try stored("scoreboard", "scoreboard")["teams"] as? [[String: Any]])
        XCTAssertEqual(teams.map { $0["name"] as? String }, ["赤", "白"])
        XCTAssertEqual(teams.map { $0["points"] as? Int }, [3, 5])
        XCTAssertEqual(teams.map { $0["sets"] as? Int }, [1, 0])

        // Swift の版の保存データは消え、2回目は何もしない
        for key in LegacyToolMigration.Keys.all { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertTrue(defaults.bool(forKey: LegacyToolMigration.doneKey))
    }

    func testTournamentBecomesPlayerNumbersThatJavaScriptCanContinue() throws {
        setJSON(#"{"rounds":[[{"round":0,"index":0,"first":"A","winner":"A"},{"round":0,"index":1,"first":"B","second":"C","winner":"B"}],[{"round":1,"index":0,"first":"A","second":"B"}]]}"#,
                LegacyToolMigration.Keys.tournamentState)
        _ = LegacyToolMigration.migrate(defaults: defaults, directory: directory, now: Date())
        let value = try stored("tournament", "tournament")
        let bracket = try XCTUnwrap(value["bracket"] as? [String: Any])
        XCTAssertEqual(bracket["names"] as? [String], ["A", "B", "C"])
        let data = try JSONSerialization.data(withJSONObject: bracket)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // JavaScript 版のトーナメントの関数で、続きから勝者を決められる
        let tool = try XCTUnwrap(BuiltinScriptTools.all.first { $0.file == "tournament" })
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(tool.tool.script?.script)
        context.evaluateScript("var t = \(json); Tournament.setWinner(t, 1, 0, 1);")
        let m = "t.rounds[0][0]"
        XCTAssertEqual(context.evaluateScript("JSON.stringify([\(m).a, \(m).b, \(m).winner, t.rounds[1][0].a, t.rounds[1][0].b, Tournament.champion(t)])")?.toString(),
                       "[0,null,0,0,1,1]")
        XCTAssertTrue(context.evaluateScript("Tournament.seeded(t, 0)")?.toBool() == true)
    }

    func testKeepsDataTheJavaScriptVersionAlreadyHas() throws {
        // v0.9.32 で JavaScript 版を使っていたら、そちらを残す
        let storage = ScriptStorage(fileURL: ScriptStorage.storageURL(toolID: BuiltinScriptTools.idPrefix + "roulette", directory: directory))
        XCTAssertNil(storage.set("roulette", #"{"itemsText":"新しい"}"#))
        storage.flush()
        defaults.set("古い", forKey: LegacyToolMigration.Keys.rouletteItems)
        let a = UUID()
        setJSON(#"[{"id":"\#(a.uuidString)","label":"x","duration":60,"endDate":\#(Date().timeIntervalSinceReferenceDate + 30),"didAlert":false}]"#,
                LegacyToolMigration.Keys.timers)
        let timer = ScriptStorage(fileURL: ScriptStorage.storageURL(toolID: BuiltinScriptTools.idPrefix + "timer", directory: directory))
        XCTAssertNil(timer.set("timers", #"{"list":[],"nextID":1}"#))
        timer.flush()
        let outcome = LegacyToolMigration.migrate(defaults: defaults, directory: directory, now: Date())
        XCTAssertEqual(Set(outcome.kept), ["roulette", "timer"])
        XCTAssertEqual(try stored("roulette", "roulette")["itemsText"] as? String, "新しい")
        // 写さなかったタイマーの通知は予約し直さないが、Swift の版の通知は取り消す
        XCTAssertEqual(outcome.schedules, [])
        XCTAssertEqual(outcome.cancelNotifications, [a.uuidString])
        XCTAssertNil(defaults.object(forKey: LegacyToolMigration.Keys.rouletteItems))
    }

    func testDropsWhatCannotBeMoved() throws {
        // 9個以上のカウンターは8個まで。形の合わないトーナメントの表は捨てて、参加者の名前だけを写す
        let counters = (1...10).map { #"{"id":"\#(UUID().uuidString)","name":"c\#($0)","value":\#($0)}"# }.joined(separator: ",")
        setJSON("[\(counters)]", LegacyToolMigration.Keys.counters)
        defaults.set("A\nB", forKey: LegacyToolMigration.Keys.tournamentPlayers)
        setJSON(#"{"rounds":[[{"first":"A","second":"B"},{"first":"C"},{"first":"D"}]]}"#, LegacyToolMigration.Keys.tournamentState)
        let outcome = LegacyToolMigration.migrate(defaults: defaults, directory: directory, now: Date())
        XCTAssertEqual(Set(outcome.dropped), ["counter(9個目から)", "tournament(途中の表)"])
        XCTAssertEqual((try stored("counter", "counter")["list"] as? [Any])?.count, 8)
        let tournament = try stored("tournament", "tournament")
        XCTAssertEqual(tournament["namesText"] as? String, "A\nB")
        XCTAssertTrue(tournament["bracket"] is NSNull)
        // 何も保存していなければ、何も書かない
        let empty = try XCTUnwrap(UserDefaults(suiteName: suite + ".empty"))
        empty.removePersistentDomain(forName: suite + ".empty")
        let other = directory.appendingPathComponent("empty", isDirectory: true)
        XCTAssertEqual(LegacyToolMigration.migrate(defaults: empty, directory: other, now: Date()), LegacyToolMigration.Outcome())
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        empty.removePersistentDomain(forName: suite + ".empty")
    }

    func testHomeTimerCardReadsJavaScriptStorage() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ms = now.timeIntervalSince1970 * 1000
        let json = #"{"list":[{"id":1,"label":"","state":"running","endAt":\#(ms + 90_000)},{"id":2,"label":"お茶","state":"running","endAt":\#(ms + 30_000)},{"id":3,"label":"x","state":"paused","left":5,"endAt":null},{"id":4,"label":"y","state":"running","endAt":\#(ms - 1000)}],"nextID":5}"#
        let running = BuiltinTimerState.runningTimers(json, now: now)
        XCTAssertEqual(running.map(\.label), ["お茶", "タイマー"])
        XCTAssertEqual(running.first?.endAt, now.addingTimeInterval(30))
        XCTAssertEqual(BuiltinTimerState.runningTimers(nil, now: now), [])
        XCTAssertEqual(BuiltinTimerState.runningTimers("broken", now: now), [])
        XCTAssertEqual(BuiltinTimerState.stopwatchOrigin(#"{"startedAt":\#(ms),"elapsed":5000,"laps":[]}"#), now.addingTimeInterval(-5))
        XCTAssertNil(BuiltinTimerState.stopwatchOrigin(#"{"startedAt":null,"elapsed":5000,"laps":[]}"#))
        XCTAssertEqual(BuiltinTimerState.text(65), "1:05")
        XCTAssertEqual(BuiltinTimerState.text(3725), "1:02:05")
        XCTAssertEqual(LegacyToolMigration.timerText(420), "7:00")
    }

    func testNotificationsShowUnlessTheToolIsOpen() {
        let presenter = ScriptNotificationPresenter()
        let id = ScriptNotificationRequest.identifier(toolID: "builtin-js.timer", id: "t1")
        XCTAssertTrue(presenter.shouldPresent(identifier: id))
        presenter.setOpen("builtin-js.timer", true)
        XCTAssertFalse(presenter.shouldPresent(identifier: id))
        XCTAssertTrue(presenter.shouldPresent(identifier: ScriptNotificationRequest.identifier(toolID: "custom-x", id: "a")))
        presenter.setOpen("builtin-js.timer", false)
        XCTAssertTrue(presenter.shouldPresent(identifier: id))
        // スクリプト以外の通知は、今までどおり出さない
        XCTAssertFalse(presenter.shouldPresent(identifier: "1A2B3C"))
    }
}

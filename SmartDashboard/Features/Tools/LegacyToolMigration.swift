import Foundation
import UserNotifications

/// v0.9.33: 消した Swift の版の内蔵ツールの保存データを、JavaScript 版の保存領域(script-storage/builtin-js.<名前>.json)に写す。
/// 起動したときに1回だけ。JavaScript 版にすでにデータがあるツール(v0.9.32 で使ったもの)は、そちらを残して写さない。
/// 写したあと、Swift の版の保存データ(UserDefaults)は消す。動いていたタイマーの通知は、JavaScript 版の通知に予約し直す。
enum LegacyToolMigration {
    static let doneKey = "tools.legacyMigrated"

    /// Swift の版が使っていた UserDefaults のキー
    enum Keys {
        static let timers = "timer.timers"
        static let stopwatch = "timer.stopwatch"
        static let timerKeepAwake = "timer.keepAwake"
        static let rouletteItems = "tools.roulette.items"
        static let members = "tools.members"
        static let counters = "tools.counters"
        static let scoreboard = "tools.scoreboard"
        static let tournamentPlayers = "tools.tournament.players"
        static let tournamentState = "tools.tournament.state"
        static let amidaGoals = "tools.amida.goals"
        static let all = [timers, stopwatch, timerKeepAwake, rouletteItems, members, counters, scoreboard, tournamentPlayers, tournamentState, amidaGoals]
    }

    /// 写したもの・写さなかったもの(報告と、設定の開発者向けの表示用)
    struct Outcome: Equatable {
        /// 写したツールのファイルの名前(timer など)
        var moved: [String] = []
        /// JavaScript 版にすでにデータがあったので写さなかったツール
        var kept: [String] = []
        /// 写せずに消したもの
        var dropped: [String] = []
        /// 取り消す Swift の版の通知の識別子
        var cancelNotifications: [String] = []
        /// 予約し直す通知(JavaScript 版のタイマーの id、残りの秒、題名、本文)
        var schedules: [Schedule] = []
    }

    struct Schedule: Equatable {
        var id: String
        var seconds: Double
        var title: String
        var body: String
    }

    // MARK: - Swift の版の保存の形(消した型と同じ形で読む)

    private struct OldTimer: Decodable {
        var id: UUID
        var label: String
        var duration: TimeInterval
        var endDate: Date?
        var pausedRemaining: TimeInterval?
    }

    private struct OldStopwatch: Decodable {
        var startedAt: Date?
        var accumulated: TimeInterval
        var lapTotals: [TimeInterval]
    }

    private struct OldCounter: Decodable {
        var name: String
        var value: Int
    }

    private struct OldScoreboard: Decodable {
        struct Team: Decodable {
            var name: String
            var score: Int
            var sets: Int
        }
        var teams: [Team]
    }

    private struct OldTournament: Decodable {
        struct Match: Decodable {
            var first: String?
            var second: String?
            var winner: String?
        }
        var rounds: [[Match]]
    }

    // MARK: - 写す

    /// 起動のたびに呼ぶ。1回写したら何もしない
    @MainActor
    static func runIfNeeded(defaults: UserDefaults = .standard, directory: URL, now: Date = Date()) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let outcome = migrate(defaults: defaults, directory: directory, now: now)
        let center = UNUserNotificationCenter.current()
        if !outcome.cancelNotifications.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: outcome.cancelNotifications)
        }
        for schedule in outcome.schedules {
            ScriptNotifications.apply(.schedule(id: schedule.id, seconds: schedule.seconds, title: schedule.title, body: schedule.body),
                                      toolID: BuiltinScriptTools.idPrefix + "timer", toolName: "タイマー")
        }
    }

    /// 写して、Swift の版の保存データを消す(テストから直接呼ぶ。通知は Outcome に入れるだけ)
    static func migrate(defaults: UserDefaults, directory: URL, now: Date) -> Outcome {
        var outcome = Outcome()
        let decoder = JSONDecoder()
        func storage(_ file: String) -> ScriptStorage {
            ScriptStorage(fileURL: ScriptStorage.storageURL(toolID: BuiltinScriptTools.idPrefix + file, directory: directory))
        }
        /// JavaScript 版にまだそのキーがなければ書く
        func put(_ file: String, _ key: String, _ value: Any) {
            let target = storage(file)
            guard target.get(key) == nil else {
                outcome.kept.append(file)
                return
            }
            guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8),
                  target.set(key, text) == nil else {
                outcome.dropped.append(file)
                return
            }
            target.flush()
            outcome.moved.append(file)
        }

        // タイマー
        if let data = defaults.data(forKey: Keys.timers), let timers = try? decoder.decode([OldTimer].self, from: data), !timers.isEmpty {
            outcome.cancelNotifications = timers.map(\.id.uuidString)
            let converted = convertTimers(timers, now: now)
            let alreadyThere = storage("timer").get("timers") != nil
            put("timer", "timers", ["list": converted.list, "nextID": converted.list.count + 1] as [String: Any])
            if !alreadyThere { outcome.schedules = converted.schedules }
        }
        if defaults.object(forKey: Keys.timerKeepAwake) != nil { outcome.dropped.append("timer.keepAwake") }

        // ストップウォッチ
        if let data = defaults.data(forKey: Keys.stopwatch), let watch = try? decoder.decode(OldStopwatch.self, from: data),
           watch.startedAt != nil || watch.accumulated > 0 || !watch.lapTotals.isEmpty {
            let started: Any = watch.startedAt.map { milliseconds($0) as Any } ?? NSNull()
            let value: [String: Any] = [
                "startedAt": started,
                "elapsed": (watch.accumulated * 1000).rounded(),
                "laps": Array(watch.lapTotals.prefix(100)).map { ($0 * 1000).rounded() },
            ]
            put("stopwatch", "stopwatch", value)
        }

        // ルーレット
        if let items = defaults.string(forKey: Keys.rouletteItems) {
            put("roulette", "roulette", ["itemsText": items, "history": [String](), "drawn": [Int](), "lottery": false] as [String: Any])
        }

        // チーム分け・順番決め・あみだくじは、メンバーの欄を共有していた
        let members = defaults.string(forKey: Keys.members)
        if let members, !members.isEmpty {
            put("teams", "teams", ["namesText": members, "teamCount": 2, "teams": [[String]]()] as [String: Any])
            put("order", "order", ["namesText": members, "order": [String](), "done": [Int]()] as [String: Any])
        }
        let goals = defaults.string(forKey: Keys.amidaGoals)
        if (members?.isEmpty == false) || goals != nil {
            var amida: [String: Any] = ["game": NSNull(), "traced": [Int]()]
            if let members, !members.isEmpty { amida["namesText"] = members }
            if let goals { amida["prizesText"] = goals }
            put("amida", "amida", amida)
        }

        // カウンター(JavaScript 版は8個まで)
        if let data = defaults.data(forKey: Keys.counters), let counters = try? decoder.decode([OldCounter].self, from: data), !counters.isEmpty {
            let list = counters.prefix(8).enumerated().map { index, counter -> [String: Any] in
                ["id": index + 1, "name": String(counter.name.prefix(20)), "value": min(max(counter.value, -999_999), 999_999)]
            }
            put("counter", "counter", ["list": list, "nextID": list.count + 1] as [String: Any])
            if counters.count > 8 { outcome.dropped.append("counter(9個目から)") }
        }

        // スコアボード(2〜4チーム)
        if let data = defaults.data(forKey: Keys.scoreboard), let board = try? decoder.decode(OldScoreboard.self, from: data),
           (2...4).contains(board.teams.count) {
            let teams = board.teams.map { ["name": String($0.name.prefix(12)), "points": min(max($0.score, 0), 999), "sets": max($0.sets, 0)] as [String: Any] }
            put("scoreboard", "scoreboard", ["teams": teams, "history": [[Int]]()] as [String: Any])
        }

        // トーナメント表(名前で持っていたのを、参加者の番号にする)
        let players = defaults.string(forKey: Keys.tournamentPlayers)
        let state = defaults.data(forKey: Keys.tournamentState).flatMap { try? decoder.decode(OldTournament.self, from: $0) }
        if players != nil || state != nil {
            var value: [String: Any] = ["shuffle": false, "bracket": NSNull()]
            if let players { value["namesText"] = players }
            if let state {
                if let bracket = convertTournament(state) { value["bracket"] = bracket } else { outcome.dropped.append("tournament(途中の表)") }
            }
            put("tournament", "tournament", value)
        }

        for key in Keys.all { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: doneKey)
        return outcome
    }

    // MARK: - 形の変換

    private static func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }

    private static func convertTimers(_ timers: [OldTimer], now: Date) -> (list: [[String: Any]], schedules: [Schedule]) {
        var list: [[String: Any]] = []
        var schedules: [Schedule] = []
        for (index, timer) in timers.enumerated() {
            let id = index + 1
            let total = max(1, timer.duration.rounded())
            let label = String(timer.label.prefix(20))
            var item: [String: Any] = ["id": id, "label": label, "total": total, "left": total, "state": "idle", "endAt": NSNull()]
            if let end = timer.endDate {
                if end > now {
                    item["state"] = "running"
                    item["endAt"] = milliseconds(end)
                    let seconds = end.timeIntervalSince(now).rounded(.up)
                    if seconds >= 1, seconds <= ScriptNotificationRequest.maxSeconds {
                        schedules.append(Schedule(id: "t\(id)", seconds: seconds, title: (label.isEmpty ? "タイマー" : label) + "が終わりました",
                                                  body: timerText(total) + " のタイマー"))
                    }
                } else {
                    item["state"] = "done"
                    item["left"] = 0
                }
            } else if let paused = timer.pausedRemaining {
                item["state"] = "paused"
                item["left"] = max(0, paused)
            }
            list.append(item)
        }
        return (list, schedules)
    }

    /// JavaScript 版の TimerLogic.text と同じ(1時間以上は 時:分:秒)
    static func timerText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 1回戦の枠の順に参加者を並べ、名前を番号にする。形が合わなければ nil
    private static func convertTournament(_ state: OldTournament) -> [String: Any]? {
        guard let first = state.rounds.first, !first.isEmpty, first.count & (first.count - 1) == 0 else { return nil }
        var names: [String] = []
        var index: [String: Int] = [:]
        for match in first {
            for name in [match.first, match.second].compactMap({ $0 }) where index[name] == nil {
                index[name] = names.count
                names.append(name)
            }
        }
        guard names.count >= 2 else { return nil }
        func number(_ name: String?) -> Any {
            if let name, let value = index[name] { return value }
            return NSNull()
        }
        var expected = first.count
        var rounds: [[[String: Any]]] = []
        for round in state.rounds {
            guard round.count == expected else { return nil }
            rounds.append(round.map { ["a": number($0.first), "b": number($0.second), "winner": number($0.winner)] })
            expected = max(1, expected / 2)
        }
        guard rounds.last?.count == 1 else { return nil }
        return ["names": names, "rounds": rounds]
    }
}

/// JavaScript 版のタイマーとストップウォッチの保存領域を読む(ホームのタイマーのカード用。書くのは JavaScript 版だけ)
enum BuiltinTimerState {
    struct Running: Equatable, Identifiable {
        var id: Int
        var label: String
        var endAt: Date
    }

    /// 動いているタイマー(終わる順)
    static func runningTimers(_ json: String?, now: Date) -> [Running] {
        guard let json, let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> Running? in
            guard item["state"] as? String == "running", let end = (item["endAt"] as? NSNumber)?.doubleValue else { return nil }
            let date = Date(timeIntervalSince1970: end / 1000)
            guard date > now else { return nil }
            let label = (item["label"] as? String) ?? ""
            return Running(id: (item["id"] as? NSNumber)?.intValue ?? 0, label: label.isEmpty ? "タイマー" : label, endAt: date)
        }
        .sorted { $0.endAt < $1.endAt }
    }

    /// 動いているストップウォッチの、経過の基準(始めた時刻 − それまでの経過)。止まっていれば nil
    static func stopwatchOrigin(_ json: String?) -> Date? {
        guard let json, let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let started = (root["startedAt"] as? NSNumber)?.doubleValue else { return nil }
        let elapsed = (root["elapsed"] as? NSNumber)?.doubleValue ?? 0
        return Date(timeIntervalSince1970: (started - elapsed) / 1000)
    }

    /// 「1:05:09」か「5:09」
    static func text(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

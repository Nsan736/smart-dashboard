import CoreGraphics
import Foundation

// MARK: - 時間計算

enum TimeCalc {
    /// 時間の長さを秒にする。「1:30」(時:分)、「1:30:15」(時:分:秒)、「1時間30分」「90分」「45秒」「1h30m」、数字だけなら分。読めなければ nil。
    static func parse(_ text: String) -> Int? {
        var body = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
            .lowercased()
            .filter { !$0.isWhitespace }
        guard !body.isEmpty else { return nil }
        var sign = 1
        if body.hasPrefix("-") || body.hasPrefix("−") {
            sign = -1
            body.removeFirst()
        } else if body.hasPrefix("+") {
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }
        if body.contains(":") {
            let parts = body.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            let values = parts.compactMap { $0 }
            let seconds = values[0] * 3600 + values[1] * 60 + (values.count == 3 ? values[2] : 0)
            return sign * seconds
        }
        if let minutes = Int(body) { return sign * minutes * 60 }
        // 単位つき
        let normalized = body
            .replacingOccurrences(of: "時間", with: "h")
            .replacingOccurrences(of: "分", with: "m")
            .replacingOccurrences(of: "秒", with: "s")
        var total = 0
        var digits = ""
        var found = false
        for character in normalized {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let value = Int(digits) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            digits = ""
            found = true
        }
        guard digits.isEmpty, found else { return nil }
        return sign * total
    }

    /// 「1:30:00」の形。負の値は先頭に「−」。
    static func format(_ seconds: Int) -> String {
        let value = abs(seconds)
        let text = String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
        return seconds < 0 ? "−" + text : text
    }

    /// 「1時間30分」の形(0の単位は出さない)
    static func japanese(_ seconds: Int) -> String {
        let value = abs(seconds)
        var text = ""
        if value >= 3600 { text += "\(value / 3600)時間" }
        if (value / 60) % 60 > 0 { text += "\((value / 60) % 60)分" }
        if value % 60 > 0 || text.isEmpty { text += "\(value % 60)秒" }
        return seconds < 0 ? "−" + text : text
    }

    /// 1行に1つの時間を足し合わせる(先頭が「-」の行は引く)。読めない行の番号(1始まり)も返す。
    static func sum(lines text: String) -> (total: Int, invalidLines: [Int]) {
        var total = 0
        var invalid: [Int] = []
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let value = parse(trimmed) { total += value } else { invalid.append(index + 1) }
        }
        return (total, invalid)
    }

    /// 開始の時刻から終了の時刻までの分。終了のほうが早いときは、翌日の時刻として数える。
    static func minutesBetween(startMinutes: Int, endMinutes: Int) -> Int {
        let difference = endMinutes - startMinutes
        return difference >= 0 ? difference : difference + 24 * 60
    }

    /// 時刻(0時からの分)に時間を足した結果。日をまたいだ数(−1=前日、1=翌日)と、その日の0時からの分。
    static func clock(adding seconds: Int, toMinutes start: Int) -> (dayOffset: Int, minutes: Int) {
        let total = start + Int((Double(seconds) / 60).rounded(.down))
        let day = Int((Double(total) / 1440).rounded(.down))
        return (day, total - day * 1440)
    }

    static func clockText(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
}

// MARK: - 世界時計

enum WorldClock {
    struct City: Equatable, Identifiable {
        var id: String
        var name: String
        var zone: String
    }

    /// タイムゾーンのデータは iOS のものを使う(夏時間も含む)。通信はしない。
    static let cities: [City] = [
        City(id: "tokyo", name: "東京", zone: "Asia/Tokyo"),
        City(id: "seoul", name: "ソウル", zone: "Asia/Seoul"),
        City(id: "beijing", name: "北京", zone: "Asia/Shanghai"),
        City(id: "taipei", name: "台北", zone: "Asia/Taipei"),
        City(id: "hongkong", name: "香港", zone: "Asia/Hong_Kong"),
        City(id: "bangkok", name: "バンコク", zone: "Asia/Bangkok"),
        City(id: "singapore", name: "シンガポール", zone: "Asia/Singapore"),
        City(id: "delhi", name: "デリー", zone: "Asia/Kolkata"),
        City(id: "dubai", name: "ドバイ", zone: "Asia/Dubai"),
        City(id: "istanbul", name: "イスタンブール", zone: "Europe/Istanbul"),
        City(id: "moscow", name: "モスクワ", zone: "Europe/Moscow"),
        City(id: "cairo", name: "カイロ", zone: "Africa/Cairo"),
        City(id: "paris", name: "パリ", zone: "Europe/Paris"),
        City(id: "berlin", name: "ベルリン", zone: "Europe/Berlin"),
        City(id: "rome", name: "ローマ", zone: "Europe/Rome"),
        City(id: "london", name: "ロンドン", zone: "Europe/London"),
        City(id: "utc", name: "協定世界時(UTC)", zone: "UTC"),
        City(id: "saopaulo", name: "サンパウロ", zone: "America/Sao_Paulo"),
        City(id: "newyork", name: "ニューヨーク", zone: "America/New_York"),
        City(id: "chicago", name: "シカゴ", zone: "America/Chicago"),
        City(id: "denver", name: "デンバー", zone: "America/Denver"),
        City(id: "losangeles", name: "ロサンゼルス", zone: "America/Los_Angeles"),
        City(id: "vancouver", name: "バンクーバー", zone: "America/Vancouver"),
        City(id: "honolulu", name: "ホノルル", zone: "Pacific/Honolulu"),
        City(id: "auckland", name: "オークランド", zone: "Pacific/Auckland"),
        City(id: "sydney", name: "シドニー", zone: "Australia/Sydney"),
    ]

    static let defaultIDs = ["london", "newyork", "losangeles", "sydney"]
    static let japan = TimeZone(identifier: "Asia/Tokyo") ?? .current

    /// 保存した文字列(カンマ区切りのID)を、都市の一覧にする。知らないIDは捨てる。
    static func decode(_ text: String) -> [City] {
        text.split(separator: ",").compactMap { id in cities.first { $0.id == id } }
    }

    static func encode(_ list: [City]) -> String { list.map(\.id).joined(separator: ",") }

    /// 日本との時差(秒)。その時点の夏時間を含む。
    static func offsetFromJapan(_ zone: TimeZone, at date: Date) -> Int {
        zone.secondsFromGMT(for: date) - japan.secondsFromGMT(for: date)
    }

    /// 「日本と同じ」「−14時間」「+3時間30分」
    static func offsetText(_ seconds: Int) -> String {
        guard seconds != 0 else { return "日本と同じ" }
        let minutes = abs(seconds) / 60
        var text = (seconds < 0 ? "−" : "+") + "\(minutes / 60)時間"
        if minutes % 60 != 0 { text += "\(minutes % 60)分" }
        return text
    }

    /// 日本の日付から見た、その都市の日付のずれ(−1=前日、0=同じ日、1=翌日)
    static func dayDifference(_ zone: TimeZone, at date: Date) -> Int {
        func dayNumber(_ zone: TimeZone) -> Int {
            Int((Double(Int(date.timeIntervalSince1970) + zone.secondsFromGMT(for: date)) / 86400).rounded(.down))
        }
        return dayNumber(zone) - dayNumber(japan)
    }

    static func dayText(_ difference: Int) -> String {
        switch difference {
        case 0: return "同じ日"
        case 1: return "翌日"
        case -1: return "前日"
        default: return difference > 0 ? "\(difference)日後" : "\(-difference)日前"
        }
    }

    static func timeText(_ zone: TimeZone, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = zone
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }
}

// MARK: - あみだくじ

struct Amida: Equatable {
    /// 縦線の数
    var columns: Int
    /// rungs[段][i] が true なら、縦線 i と i+1 の間に横線がある。同じ段で隣り合う横線はない。
    var rungs: [[Bool]]

    init(columns: Int, rungs: [[Bool]]) {
        self.columns = columns
        self.rungs = rungs
    }

    /// ランダムに作る。どの縦線の間にも、横線が1本以上入る。
    init<G: RandomNumberGenerator>(columns: Int, rows: Int, using generator: inout G) {
        let columns = max(columns, 2)
        let rows = max(rows, 2)
        var rungs = [[Bool]](repeating: [Bool](repeating: false, count: columns - 1), count: rows)
        for row in 0..<rows {
            for gap in 0..<(columns - 1) where !(gap > 0 && rungs[row][gap - 1]) {
                rungs[row][gap] = Int.random(in: 0..<100, using: &generator) < 40
            }
        }
        // 横線のない間がなくなるまで足す(隣を消したせいで空いた間も、次の回で埋める)
        for _ in 0..<100 {
            guard let gap = (0..<(columns - 1)).first(where: { gap in !rungs.contains { $0[gap] } }) else { break }
            // 両隣が空いている段に足す。なければ、隣を消して入れる
            let free = (0..<rows).filter { row in
                !(gap > 0 && rungs[row][gap - 1]) && !(gap + 1 < columns - 1 && rungs[row][gap + 1])
            }
            let row = free.randomElement(using: &generator) ?? Int.random(in: 0..<rows, using: &generator)
            if gap > 0 { rungs[row][gap - 1] = false }
            if gap + 1 < columns - 1 { rungs[row][gap + 1] = false }
            rungs[row][gap] = true
        }
        self.init(columns: columns, rungs: rungs)
    }

    /// 縦線ごとの位置の移り変わり。先頭が出発の縦線、以降は各段を通ったあとの縦線。
    func columnsVisited(from start: Int) -> [Int] {
        var column = start
        var visited = [start]
        for row in rungs {
            if column < columns - 1, row[column] {
                column += 1
            } else if column > 0, row[column - 1] {
                column -= 1
            }
            visited.append(column)
        }
        return visited
    }

    func result(from start: Int) -> Int { columnsVisited(from: start).last ?? start }

    /// たどる道の折れ点。x は縦線の番号、y は 0(上端)〜段数+1(下端)。横線は、段 r なら y = r + 1。
    func path(from start: Int) -> [CGPoint] {
        let visited = columnsVisited(from: start)
        var points = [CGPoint(x: Double(start), y: 0)]
        for row in rungs.indices where visited[row] != visited[row + 1] {
            points.append(CGPoint(x: Double(visited[row]), y: Double(row + 1)))
            points.append(CGPoint(x: Double(visited[row + 1]), y: Double(row + 1)))
        }
        points.append(CGPoint(x: Double(visited.last ?? start), y: Double(rungs.count + 1)))
        return points
    }
}

// MARK: - スコアボード

struct Scoreboard: Equatable, Codable {
    struct Team: Equatable, Codable, Identifiable {
        var id = UUID()
        var name: String
        var score = 0
        var sets = 0
    }

    var teams: [Team] = [Team(name: "チームA"), Team(name: "チームB")]

    static let maxTeams = 4

    mutating func add(_ amount: Int, to index: Int) {
        guard teams.indices.contains(index) else { return }
        teams[index].score = max(0, teams[index].score + amount)
    }

    /// 単独で点の一番高いチームがセットを取り、全員の点を0に戻す。同点のときは何もしないで false。
    @discardableResult
    mutating func finishSet() -> Bool {
        guard let top = teams.map(\.score).max(), teams.filter({ $0.score == top }).count == 1,
              let winner = teams.firstIndex(where: { $0.score == top }) else { return false }
        teams[winner].sets += 1
        for index in teams.indices { teams[index].score = 0 }
        return true
    }

    mutating func resetAll() {
        for index in teams.indices {
            teams[index].score = 0
            teams[index].sets = 0
        }
    }
}

// MARK: - メトロノーム

enum MetronomeLogic {
    static let bpmRange = 30...240

    static func clamped(_ bpm: Int) -> Int { min(max(bpm, bpmRange.lowerBound), bpmRange.upperBound) }

    /// 1拍のサンプル数
    static func framesPerBeat(bpm: Int, sampleRate: Double) -> Int {
        Int((sampleRate * 60 / Double(clamped(bpm))).rounded())
    }

    /// 開始からの経過時間 → 小節の中の拍(0始まり)
    static func beatIndex(elapsed: TimeInterval, bpm: Int, beatsPerBar: Int) -> Int {
        guard elapsed >= 0, beatsPerBar > 0 else { return 0 }
        return Int(elapsed / (60 / Double(clamped(bpm)))) % beatsPerBar
    }

    /// タップの時刻からテンポを求める。2秒以上空いたら、そこから数え直す。タップが2回未満なら nil。
    static func tapTempo(_ taps: [TimeInterval]) -> Int? {
        var recent: [TimeInterval] = []
        for time in taps {
            if let last = recent.last, time - last > 2 { recent = [] }
            recent.append(time)
        }
        let used = Array(recent.suffix(6))
        guard used.count >= 2, let first = used.first, let last = used.last, last > first else { return nil }
        return clamped(Int((60 * Double(used.count - 1) / (last - first)).rounded()))
    }

    /// 1小節ぶんの波形。各拍の先頭に短いクリック音(1拍目は高い音)。accent が false なら、全部同じ音。
    static func barSamples(bpm: Int, beatsPerBar: Int, accent: Bool, sampleRate: Double) -> [Float] {
        let perBeat = framesPerBeat(bpm: bpm, sampleRate: sampleRate)
        let beats = max(beatsPerBar, 1)
        var samples = [Float](repeating: 0, count: perBeat * beats)
        let clickFrames = min(Int(sampleRate * 0.03), perBeat)
        for beat in 0..<beats {
            let frequency = (accent && beat == 0) ? 1760.0 : 1100.0
            for frame in 0..<clickFrames {
                let time = Double(frame) / sampleRate
                let envelope = exp(-time * 120)
                samples[beat * perBeat + frame] = Float(sin(2 * .pi * frequency * time) * envelope * 0.8)
            }
        }
        return samples
    }
}

// MARK: - ルーレットの円盤

enum RouletteWheel {
    /// 針は真上。項目 i は、真上から時計回りに i×(360/数) 〜 (i+1)×(360/数) の扇形。
    /// 円盤を時計回りに rotation 度回したとき、針の下にくる項目。
    static func index(atRotation rotation: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let segment = 360 / Double(count)
        var angle = (-rotation).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        return min(Int(angle / segment), count - 1)
    }

    /// 項目 index の扇形の中(fraction: 0〜1 の位置)で止まる回転角。今の角度から、少なくとも turns 回転ぶん先。
    static func stopRotation(current: Double, index: Int, count: Int, turns: Int, fraction: Double) -> Double {
        guard count > 0 else { return current }
        let segment = 360 / Double(count)
        let inside = min(max(fraction, 0.1), 0.9)
        var target = (-(Double(index) + inside) * segment).truncatingRemainder(dividingBy: 360)
        if target < 0 { target += 360 }
        let minimum = current + Double(turns) * 360
        let base = (minimum / 360).rounded(.down) * 360 + target
        return base >= minimum ? base : base + 360
    }
}

// MARK: - サイコロの目

enum DicePips {
    /// 3×3 のます目の中の、点の位置(列, 行)。1〜6以外は空。
    static func positions(_ value: Int) -> [(column: Int, row: Int)] {
        switch value {
        case 1: return [(1, 1)]
        case 2: return [(0, 0), (2, 2)]
        case 3: return [(0, 0), (1, 1), (2, 2)]
        case 4: return [(0, 0), (2, 0), (0, 2), (2, 2)]
        case 5: return [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)]
        case 6: return [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)]
        default: return []
        }
    }
}

// MARK: - コインの回転

enum CoinFlip {
    /// 表は 0度、裏は 180度(360度ごとに同じ)。今の角度から、少なくとも turns×360度 先で、結果の面が手前になる角度。
    static func targetAngle(current: Double, heads: Bool, turns: Int) -> Double {
        let minimum = current + Double(turns) * 360
        let base = (minimum / 360).rounded(.down) * 360 + (heads ? 0 : 180)
        return base >= minimum ? base : base + 360
    }

    /// その角度で手前に見えているのが表か
    static func showsHeads(angle: Double) -> Bool { cos(angle * .pi / 180) >= 0 }
}

// MARK: - トーナメント表の配置

/// 山型のトーナメント表の配置。1回戦が左端、決勝が右端。描画とタップの判定の両方に使う。
struct TournamentLayout: Equatable {
    struct Metrics: Equatable {
        var boxWidth: CGFloat = 116
        var boxHeight: CGFloat = 44
        var columnGap: CGFloat = 28
        var rowGap: CGFloat = 12
        var championWidth: CGFloat = 132
        var padding: CGFloat = 12
        /// 名前の幅の上限(全角=2、半角=1)
        var nameUnits = 14
    }

    struct Slot: Equatable {
        var name: String?
        var shortName: String
        var rect: CGRect
        var isWinner: Bool
        var isLoser: Bool
        /// 1回戦が不戦勝で、この回戦から出る(線はつながない)
        var isSeeded: Bool
    }

    struct Box: Equatable {
        var round: Int
        var index: Int
        var rect: CGRect
        var first: Slot
        var second: Slot
        var canPlay: Bool
    }

    struct Connector: Equatable {
        /// 折れ線(前の試合の右 → 縦 → 次の試合の枠)
        var points: [CGPoint]
        /// 勝者が決まって、勝ち上がった線
        var isWon: Bool
    }

    var size: CGSize
    var boxes: [Box]
    var connectors: [Connector]
    var championRect: CGRect
    var champion: String?
    var roundTitles: [(title: String, x: CGFloat)]

    static func == (lhs: TournamentLayout, rhs: TournamentLayout) -> Bool {
        lhs.size == rhs.size && lhs.boxes == rhs.boxes && lhs.connectors == rhs.connectors
            && lhs.championRect == rhs.championRect && lhs.champion == rhs.champion
    }

    static let titleHeight: CGFloat = 22

    static func roundTitle(_ round: Int, total: Int) -> String {
        if round == total - 1 { return "決勝" }
        if round == total - 2 { return "準決勝" }
        return "\(round + 1)回戦"
    }

    /// 長い名前を、幅の上限で切って「…」を付ける
    static func shortName(_ name: String, units: Int) -> String {
        var used = 0
        var result = ""
        for character in name {
            let width = TextCount.isHalfWidth(character) ? 1 : 2
            if used + width > units {
                return result + "…"
            }
            used += width
            result.append(character)
        }
        return result
    }

    static func make(_ tournament: Tournament, metrics: Metrics = Metrics()) -> TournamentLayout {
        let rounds = tournament.rounds
        let unit = metrics.boxHeight + metrics.rowGap
        let top = metrics.padding + titleHeight
        // 各試合の中心の高さ。1回戦は等間隔、以降は前の2試合の中間。
        var centers: [[CGFloat]] = []
        for round in rounds.indices {
            if round == 0 {
                centers.append(rounds[0].indices.map { top + (CGFloat($0) + 0.5) * unit })
            } else {
                centers.append(rounds[round].indices.map { (centers[round - 1][$0 * 2] + centers[round - 1][$0 * 2 + 1]) / 2 })
            }
        }
        func x(_ round: Int) -> CGFloat { metrics.padding + CGFloat(round) * (metrics.boxWidth + metrics.columnGap) }

        var boxes: [Box] = []
        var connectors: [Connector] = []
        for round in rounds.indices {
            for match in rounds[round] {
                // 1回戦の不戦勝は枠を描かない
                if round == 0, match.isBye { continue }
                let rect = CGRect(x: x(round), y: centers[round][match.index] - metrics.boxHeight / 2,
                                  width: metrics.boxWidth, height: metrics.boxHeight)
                func slot(_ name: String?, upper: Bool) -> Slot {
                    let feeder = round == 1 ? rounds[0][match.index * 2 + (upper ? 0 : 1)] : nil
                    let half = CGRect(x: rect.minX, y: upper ? rect.minY : rect.midY, width: rect.width, height: rect.height / 2)
                    return Slot(name: name, shortName: name.map { shortName($0, units: metrics.nameUnits) } ?? "",
                                rect: half,
                                isWinner: name != nil && match.winner == name,
                                isLoser: name != nil && match.winner != nil && match.winner != name,
                                isSeeded: feeder?.isBye ?? false)
                }
                boxes.append(Box(round: round, index: match.index, rect: rect,
                                 first: slot(match.first, upper: true), second: slot(match.second, upper: false),
                                 canPlay: match.first != nil && match.second != nil))
                // 次の試合への線
                guard round + 1 < rounds.count else { continue }
                let upper = match.index % 2 == 0
                let targetCenter = centers[round + 1][match.index / 2]
                let targetY = targetCenter + (upper ? -1 : 1) * metrics.boxHeight / 4
                let middle = rect.maxX + metrics.columnGap / 2
                connectors.append(Connector(points: [
                    CGPoint(x: rect.maxX, y: rect.midY),
                    CGPoint(x: middle, y: rect.midY),
                    CGPoint(x: middle, y: targetY),
                    CGPoint(x: x(round + 1), y: targetY),
                ], isWon: match.winner != nil))
            }
        }
        // 決勝から優勝者へ
        let last = rounds.count - 1
        let finalCenter = centers[last][0]
        let championRect = CGRect(x: x(last) + metrics.boxWidth + metrics.columnGap, y: finalCenter - 32,
                                  width: metrics.championWidth, height: 64)
        connectors.append(Connector(points: [
            CGPoint(x: x(last) + metrics.boxWidth, y: finalCenter),
            CGPoint(x: championRect.minX, y: finalCenter),
        ], isWon: tournament.champion != nil))
        let height = top + CGFloat(rounds[0].count) * unit + metrics.padding
        let titles = rounds.indices.map { (title: roundTitle($0, total: rounds.count), x: x($0)) }
        return TournamentLayout(size: CGSize(width: championRect.maxX + metrics.padding, height: max(height, championRect.maxY + metrics.padding)),
                                boxes: boxes, connectors: connectors, championRect: championRect,
                                champion: tournament.champion, roundTitles: titles)
    }

    /// タップした位置の試合と、上下どちらの枠か
    func hit(at point: CGPoint) -> (box: Box, isFirst: Bool)? {
        guard let box = boxes.first(where: { $0.rect.insetBy(dx: -4, dy: -2).contains(point) }) else { return nil }
        return (box, point.y < box.rect.midY)
    }

    /// 表全体が入る縮尺(拡大はしない)
    static func fitScale(content: CGSize, viewport: CGSize) -> CGFloat {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / content.width, viewport.height / content.height, 1)
    }
}

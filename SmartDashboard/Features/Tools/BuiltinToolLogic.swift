import Foundation

// MARK: - 割り勘

enum SplitBill {
    enum Rounding: String, CaseIterable, Identifiable {
        case none
        case up10
        case up100
        case up500
        case up1000

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "1円単位"
            case .up10: return "10円単位に切り上げ"
            case .up100: return "100円単位に切り上げ"
            case .up500: return "500円単位に切り上げ"
            case .up1000: return "1000円単位に切り上げ"
            }
        }

        var unit: Int {
            switch self {
            case .none: return 1
            case .up10: return 10
            case .up100: return 100
            case .up500: return 500
            case .up1000: return 1000
            }
        }
    }

    struct Result: Equatable {
        /// 1人あたり
        var perPerson: Int
        /// 集まる合計と、おつり(集まる合計 − 会計)。切り上げなので 0 以上。
        var collected: Int
        var surplus: Int
    }

    /// 1人あたりを、選んだ単位に切り上げる(足りなくならないようにする)
    static func calculate(total: Int, people: Int, rounding: Rounding) -> Result? {
        guard total >= 0, people > 0 else { return nil }
        let unit = rounding.unit
        let exact = (total + people - 1) / people
        let perPerson = ((exact + unit - 1) / unit) * unit
        return Result(perPerson: perPerson, collected: perPerson * people, surplus: perPerson * people - total)
    }
}

// MARK: - パーセント・割引・消費税

enum PercentCalc {
    /// 2進数の誤差(699.9999… や 1000.0000001)で1円ずれないよう、先に小数第3位で丸めてから、円未満を処理する
    private static func settled(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    /// ◯%引きの値段(円未満は切り捨て)
    static func discounted(price: Double, percentOff: Double) -> Double { settled(price * (100 - percentOff) / 100).rounded(.down) }
    /// 税抜 → 税込(円未満は切り捨て)
    static func withTax(price: Double, rate: Double) -> Double { settled(price * (100 + rate) / 100).rounded(.down) }
    /// 税込 → 税抜(円未満は切り上げ。税込に戻したときに元の値段を下回らないように)
    static func withoutTax(price: Double, rate: Double) -> Double { settled(price * 100 / (100 + rate)).rounded(.up) }
    /// a は b の何%か
    static func ratio(_ a: Double, of b: Double) -> Double? { b == 0 ? nil : a / b * 100 }
}

// MARK: - 単位換算

enum UnitKind: String, CaseIterable, Identifiable {
    case length
    case weight
    case temperature
    case area
    case volume
    case speed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .length: return "長さ"
        case .weight: return "重さ"
        case .temperature: return "温度"
        case .area: return "面積"
        case .volume: return "体積"
        case .speed: return "速度"
        }
    }

    /// 単位の名前と、基準の単位への倍率(温度は別に計算する)
    var units: [(name: String, factor: Double)] {
        switch self {
        case .length: return [("mm", 0.001), ("cm", 0.01), ("m", 1), ("km", 1000), ("インチ", 0.0254), ("フィート", 0.3048), ("ヤード", 0.9144), ("マイル", 1609.344), ("尺", 10.0 / 33)]
        case .weight: return [("g", 0.001), ("kg", 1), ("t", 1000), ("オンス", 0.028349523125), ("ポンド", 0.45359237), ("匁", 0.00375)]
        case .temperature: return [("℃", 1), ("℉", 1), ("K", 1)]
        case .area: return [("cm²", 0.0001), ("m²", 1), ("km²", 1_000_000), ("a", 100), ("ha", 10_000), ("坪", 400.0 / 121), ("畳", 1.62), ("エーカー", 4046.8564224)]
        case .volume: return [("mL", 0.001), ("L", 1), ("m³", 1000), ("合", 0.18039), ("升", 1.8039), ("カップ(日本)", 0.2), ("ガロン(米)", 3.785411784)]
        case .speed: return [("m/s", 1), ("km/h", 1 / 3.6), ("mph", 0.44704), ("ノット", 1852.0 / 3600)]
        }
    }
}

enum UnitConverter {
    static func convert(_ value: Double, kind: UnitKind, from: Int, to: Int) -> Double? {
        let units = kind.units
        guard units.indices.contains(from), units.indices.contains(to) else { return nil }
        if kind == .temperature {
            let celsius: Double
            switch from {
            case 1: celsius = (value - 32) * 5 / 9
            case 2: celsius = value - 273.15
            default: celsius = value
            }
            switch to {
            case 1: return celsius * 9 / 5 + 32
            case 2: return celsius + 273.15
            default: return celsius
            }
        }
        return value * units[from].factor / units[to].factor
    }

    /// 有効数字をそろえて、余分な0を出さない
    static func text(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 7
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

// MARK: - 進数変換

enum BaseConverter {
    /// 2〜36進の文字列を、別の進数に変える。読めなければ nil。負の数にも対応。
    static func convert(_ text: String, from: Int, to: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
        guard (2...36).contains(from), (2...36).contains(to), !trimmed.isEmpty, let value = Int64(trimmed, radix: from) else { return nil }
        return String(value, radix: to, uppercase: true)
    }
}

// MARK: - 和暦・西暦・年齢

enum Wareki {
    struct Era: Equatable {
        var name: String
        var startYear: Int
        var startMonth: Int
        var startDay: Int
    }

    static let eras = [
        Era(name: "令和", startYear: 2019, startMonth: 5, startDay: 1),
        Era(name: "平成", startYear: 1989, startMonth: 1, startDay: 8),
        Era(name: "昭和", startYear: 1926, startMonth: 12, startDay: 25),
        Era(name: "大正", startYear: 1912, startMonth: 7, startDay: 30),
        Era(name: "明治", startYear: 1868, startMonth: 1, startDay: 25),
    ]

    /// 西暦の日付 → 「令和8年」(元年は「元年」)。明治より前は nil。
    static func text(year: Int, month: Int, day: Int) -> String? {
        let key = year * 10_000 + month * 100 + day
        guard let era = eras.first(where: { key >= $0.startYear * 10_000 + $0.startMonth * 100 + $0.startDay }) else { return nil }
        let eraYear = year - era.startYear + 1
        return era.name + (eraYear == 1 ? "元" : String(eraYear)) + "年"
    }

    /// 元号と年 → 西暦の年。知らない元号や、0以下の年は nil。
    static func westernYear(era: String, year: Int) -> Int? {
        guard year >= 1, let match = eras.first(where: { $0.name == era }) else { return nil }
        return match.startYear + year - 1
    }

    /// その年の年末までに迎える年齢ではなく、基準日の時点の満年齢
    static func age(birthYear: Int, birthMonth: Int, birthDay: Int, onYear: Int, month: Int, day: Int) -> Int {
        var age = onYear - birthYear
        if month < birthMonth || (month == birthMonth && day < birthDay) { age -= 1 }
        return age
    }

    static let zodiacNames = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]

    /// 干支(十二支)
    static func zodiac(year: Int) -> String {
        zodiacNames[((year - 4) % 12 + 12) % 12]
    }
}

// MARK: - 日付計算

enum DateCalc {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    /// 2つの日付の間の日数(to − from)。時刻は無視する。
    static func days(from: Date, to: Date) -> Int {
        let calendar = calendar
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    static func adding(days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
    }

    static func weekdayText(_ date: Date) -> String {
        ["日", "月", "火", "水", "木", "金", "土"][(calendar.component(.weekday, from: date) + 6) % 7] + "曜日"
    }
}

// MARK: - チーム分け・順番決め

enum Shuffler {
    /// メンバーを、人数がなるべく同じになるようにチームに分ける(順に1人ずつ配る)
    static func teams<G: RandomNumberGenerator>(_ members: [String], count: Int, using generator: inout G) -> [[String]] {
        guard count > 0 else { return [] }
        var teams = [[String]](repeating: [], count: min(count, max(members.count, 1)))
        for (index, member) in members.shuffled(using: &generator).enumerated() {
            teams[index % teams.count].append(member)
        }
        return teams
    }

    /// 入力欄のテキスト(改行か読点・カンマ区切り)を、名前の一覧にする
    static func names(from text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "、" || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - トーナメント

/// 勝ち抜きのトーナメント。参加者が2のべき乗でないときは、前にいる人(シード)から順に不戦勝にする。
struct Tournament: Equatable, Codable {
    struct Match: Equatable, Codable, Identifiable {
        var round: Int
        var index: Int
        var first: String?
        var second: String?
        var winner: String?
        var id: String { "\(round)-\(index)" }

        /// 相手がいない(不戦勝)
        var isBye: Bool { (first == nil) != (second == nil) }
    }

    /// rounds[0] が1回戦
    var rounds: [[Match]]

    /// 参加者の並び順がシード順(先頭が第1シード)。第1シードと第2シードが決勝まで当たらないように配置する。
    init?(players: [String]) {
        guard players.count >= 2, players.count <= 64 else { return nil }
        var size = 2
        while size < players.count { size *= 2 }
        let order = Self.seedOrder(size: size)
        let slots: [String?] = order.map { $0 <= players.count ? players[$0 - 1] : nil }
        var first: [Match] = []
        for index in 0..<(size / 2) {
            first.append(Match(round: 0, index: index, first: slots[index * 2], second: slots[index * 2 + 1], winner: nil))
        }
        rounds = [first]
        var count = size / 4
        var round = 1
        while count >= 1 {
            rounds.append((0..<count).map { Match(round: round, index: $0, first: nil, second: nil, winner: nil) })
            count /= 2
            round += 1
        }
        // 不戦勝は、最初から勝ち上がらせる
        for index in rounds[0].indices where rounds[0][index].isBye {
            let match = rounds[0][index]
            setWinner(round: 0, index: index, name: match.first ?? match.second)
        }
    }

    /// 1回戦の枠に入るシードの番号。size=8 なら [1,8,4,5,2,7,3,6]。
    static func seedOrder(size: Int) -> [Int] {
        var order = [1]
        while order.count < size {
            let total = order.count * 2 + 1
            order = order.flatMap { [$0, total - $0] }
        }
        return order
    }

    var champion: String? { rounds.last?.first?.winner }

    /// 勝者を決めて、次の試合に進める。すでに先の試合が進んでいたら、その先の結果は取り消す。
    mutating func setWinner(round: Int, index: Int, name: String?) {
        guard rounds.indices.contains(round), rounds[round].indices.contains(index) else { return }
        let match = rounds[round][index]
        guard name == nil || name == match.first || name == match.second else { return }
        rounds[round][index].winner = name
        guard round + 1 < rounds.count else { return }
        let nextIndex = index / 2
        let old = index % 2 == 0 ? rounds[round + 1][nextIndex].first : rounds[round + 1][nextIndex].second
        if index % 2 == 0 {
            rounds[round + 1][nextIndex].first = name
        } else {
            rounds[round + 1][nextIndex].second = name
        }
        // 進めていた勝者が変わったら、その先を取り消す
        if old != name, rounds[round + 1][nextIndex].winner != nil {
            setWinner(round: round + 1, index: nextIndex, name: nil)
        }
    }
}

// MARK: - 文字数カウント

enum TextCount {
    struct Result: Equatable {
        /// 見た目の文字数(絵文字や結合文字は1文字)
        var characters: Int
        var charactersWithoutSpaces: Int
        /// 全角を2、半角を1として数えた幅
        var halfWidthUnits: Int
        var lines: Int
        var utf8Bytes: Int
    }

    static func count(_ text: String, countsNewlines: Bool) -> Result {
        let target = countsNewlines ? text : String(text.filter { !$0.isNewline })
        let units = target.reduce(0) { total, character in
            total + (character.isNewline ? 1 : (isHalfWidth(character) ? 1 : 2))
        }
        return Result(characters: target.count,
                      charactersWithoutSpaces: target.filter { !$0.isWhitespace }.count,
                      halfWidthUnits: units,
                      lines: text.isEmpty ? 0 : text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count,
                      utf8Bytes: text.utf8.count)
    }

    /// ASCII と半角カタカナを半角とみなす
    static func isHalfWidth(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.value < 0x7F || (0xFF61...0xFF9F).contains($0.value) }
    }
}

// MARK: - 文字の変換

enum KanaConvert {
    static func hiragana(_ text: String) -> String { text.applyingTransform(.hiraganaToKatakana, reverse: true) ?? text }
    static func katakana(_ text: String) -> String { text.applyingTransform(.hiraganaToKatakana, reverse: false) ?? text }
    /// 全角 → 半角(英数字・記号・カタカナ)
    static func halfWidth(_ text: String) -> String { text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text }
    /// 半角 → 全角
    static func fullWidth(_ text: String) -> String { text.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? text }
}

// MARK: - パスワード・乱数

enum PasswordGenerator {
    struct Options: Equatable {
        var length = 16
        var lowercase = true
        var uppercase = true
        var digits = true
        var symbols = false
        /// 見間違えやすい文字(0 O o 1 l I)を除く
        var avoidsAmbiguous = true
    }

    static func alphabet(_ options: Options) -> [Character] {
        var characters = ""
        if options.lowercase { characters += "abcdefghijklmnopqrstuvwxyz" }
        if options.uppercase { characters += "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
        if options.digits { characters += "0123456789" }
        if options.symbols { characters += "!#$%&*+-=?@_" }
        if options.avoidsAmbiguous { characters.removeAll { "0Oo1lI".contains($0) } }
        return Array(characters)
    }

    /// 乱数は SystemRandomNumberGenerator(暗号論的に安全)を使う
    static func generate<G: RandomNumberGenerator>(_ options: Options, using generator: inout G) -> String {
        let alphabet = alphabet(options)
        guard !alphabet.isEmpty else { return "" }
        let length = min(max(options.length, 1), 128)
        return String((0..<length).compactMap { _ in alphabet.randomElement(using: &generator) })
    }
}

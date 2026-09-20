import Foundation
import Observation

enum ToolCategory: String, CaseIterable, Identifiable {
    case time
    case calc
    case play
    case text
    case measure
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .time: return "時間"
        case .calc: return "計算"
        case .play: return "決める・遊ぶ"
        case .text: return "文字"
        case .measure: return "測る"
        case .other: return "その他"
        }
    }
}

/// 内蔵ツールの種類。増やすときは、ここに足して、BuiltinTools.all に登録し、ToolScreen に画面を足す。
enum BuiltinTool: String, CaseIterable {
    case timer
    case stopwatch
    case dateCalc
    case wareki
    case splitBill
    case percent
    case unitConvert
    case baseConvert
    case roulette
    case dice
    case coin
    case teams
    case order
    case tournament
    case counter
    case textCount
    case kanaConvert
    case password
    case flashlight
}

/// 小ツールの1件(内蔵でも、JSONで読み込んだものでも、同じ形で扱う)
struct ToolDescriptor: Equatable, Identifiable {
    enum Source: Equatable {
        case builtin(BuiltinTool)
        case custom(CustomTool)
    }

    /// 内蔵は "builtin.◯◯"、読み込んだものは "custom.◯◯"
    var id: String
    var name: String
    var summary: String
    var symbol: String
    var category: ToolCategory
    var keywords: [String]
    var source: Source

    init(_ tool: BuiltinTool, name: String, summary: String, symbol: String, category: ToolCategory, keywords: [String]) {
        id = "builtin." + tool.rawValue
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.category = category
        self.keywords = keywords
        source = .builtin(tool)
    }

    init(_ tool: CustomTool) {
        id = "custom." + tool.id
        name = tool.name
        summary = tool.summary.isEmpty ? tool.kind.label : tool.summary
        symbol = tool.symbol
        category = tool.category
        keywords = tool.keywords
        source = .custom(tool)
    }

    var isCustom: Bool {
        if case .custom = source { return true }
        return false
    }
}

enum BuiltinTools {
    static let all: [ToolDescriptor] = [
        ToolDescriptor(.timer, name: "タイマー", summary: "複数のタイマー。終了時に通知と音", symbol: "timer", category: .time, keywords: ["timer", "カウントダウン", "アラーム"]),
        ToolDescriptor(.stopwatch, name: "ストップウォッチ", summary: "経過時間とラップ", symbol: "stopwatch", category: .time, keywords: ["stopwatch", "ラップ", "計測"]),
        ToolDescriptor(.dateCalc, name: "日付計算", summary: "日数の差、◯日後、曜日", symbol: "calendar", category: .time, keywords: ["date", "日数", "何日後", "曜日", "カレンダー"]),
        ToolDescriptor(.wareki, name: "和暦・西暦・年齢", summary: "令和・平成・昭和と西暦、年齢の変換", symbol: "calendar.badge.clock", category: .time, keywords: ["wareki", "元号", "令和", "平成", "昭和", "年齢", "干支"]),
        ToolDescriptor(.splitBill, name: "割り勘", summary: "人数で割り、端数の扱いを選べる", symbol: "person.2", category: .calc, keywords: ["warikan", "わりかん", "会計", "飲み会", "split"]),
        ToolDescriptor(.percent, name: "パーセント・割引・消費税", summary: "◯%引き、税込・税抜", symbol: "percent", category: .calc, keywords: ["percent", "割引", "消費税", "税込", "税抜", "セール", "ぜい"]),
        ToolDescriptor(.unitConvert, name: "単位換算", summary: "長さ・重さ・温度・面積・体積・速度", symbol: "arrow.left.arrow.right", category: .calc, keywords: ["unit", "換算", "インチ", "ポンド", "マイル", "華氏", "坪"]),
        ToolDescriptor(.baseConvert, name: "進数変換", summary: "2進・8進・10進・16進", symbol: "number", category: .calc, keywords: ["binary", "hex", "2進数", "16進数", "ビット"]),
        ToolDescriptor(.roulette, name: "ルーレット", summary: "登録した項目から1つ選ぶ。履歴つき", symbol: "arrow.triangle.2.circlepath.circle", category: .play, keywords: ["roulette", "抽選", "くじ", "ランダム", "選ぶ"]),
        ToolDescriptor(.dice, name: "サイコロ", summary: "個数と面の数を指定", symbol: "dice", category: .play, keywords: ["dice", "さいころ", "ダイス", "乱数"]),
        ToolDescriptor(.coin, name: "コイントス", summary: "表か裏か", symbol: "circle.lefthalf.filled", category: .play, keywords: ["coin", "こいん", "表裏", "おもてうら"]),
        ToolDescriptor(.teams, name: "チーム分け", summary: "メンバーをランダムにチームに分ける", symbol: "person.3", category: .play, keywords: ["team", "グループ分け", "班分け"]),
        ToolDescriptor(.order, name: "順番決め", summary: "メンバーをランダムな順に並べる", symbol: "list.number", category: .play, keywords: ["order", "シャッフル", "じゅんばん", "発表順"]),
        ToolDescriptor(.tournament, name: "トーナメント表", summary: "組み合わせを作り、勝者をタップで進める", symbol: "trophy", category: .play, keywords: ["tournament", "とーなめんと", "対戦表", "シード", "勝ち抜き"]),
        ToolDescriptor(.counter, name: "カウンター", summary: "複数の数を数える", symbol: "plusminus.circle", category: .play, keywords: ["counter", "かうんたー", "数取り", "カウント"]),
        ToolDescriptor(.textCount, name: "文字数カウント", summary: "全角・半角・改行の扱いを選べる", symbol: "textformat.123", category: .text, keywords: ["count", "もじすう", "文字数", "字数"]),
        ToolDescriptor(.kanaConvert, name: "文字の変換", summary: "全角・半角・ひらがな・カタカナ", symbol: "textformat.alt", category: .text, keywords: ["kana", "ぜんかく", "はんかく", "ひらがな", "カタカナ", "変換"]),
        ToolDescriptor(.password, name: "パスワード・乱数", summary: "文字の種類と長さを選んで作る", symbol: "key", category: .text, keywords: ["password", "ぱすわーど", "乱数", "ランダム", "random"]),
        ToolDescriptor(.flashlight, name: "懐中電灯", summary: "ライトを点け、明るさを調整", symbol: "flashlight.on.fill", category: .measure, keywords: ["light", "らいと", "ライト", "かいちゅうでんとう", "torch"]),
    ]
}

/// 検索。ひらがな・カタカナ・全角半角・大文字小文字の表記ゆれを吸収する。
enum ToolSearch {
    /// 比較用にそろえる: 小文字、全角英数字→半角、カタカナ→ひらがな、空白と長音・中点の除去
    static func normalize(_ text: String) -> String {
        var result = ""
        for scalar in text.lowercased().unicodeScalars {
            let value = scalar.value
            if (0x30A1...0x30F6).contains(value), let hiragana = Unicode.Scalar(value - 0x60) {
                result.unicodeScalars.append(hiragana)
            } else if (0xFF01...0xFF5E).contains(value), let half = Unicode.Scalar(value - 0xFEE0) {
                result.unicodeScalars.append(contentsOf: String(Character(half)).lowercased().unicodeScalars)
            } else if scalar.properties.isWhitespace || value == 0x30FC || value == 0x30FB || value == 0x3000 {
                continue
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func matches(_ tool: ToolDescriptor, query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "　" }).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return true }
        let haystack = ([tool.name, tool.summary, tool.category.label] + tool.keywords).map(normalize)
        // すべての語が、名前・説明・キーワードのどこかに含まれる
        return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
    }

    static func filter(_ tools: [ToolDescriptor], query: String) -> [ToolDescriptor] {
        tools.filter { matches($0, query: query) }
    }
}

/// お気に入り、最近使ったツール、読み込んだツールの保存
@MainActor
@Observable
final class ToolLibrary {
    private(set) var favorites: [String] = []
    private(set) var recents: [String] = []
    /// 読み込んだツールのJSON(そのまま保存する)
    private(set) var customSources: [String: String] = [:]
    private(set) var customTools: [CustomTool] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults

    static let maxRecents = 8
    private static let favoritesKey = "tools.favorites"
    private static let recentsKey = "tools.recents"

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        favorites = defaults.stringArray(forKey: Self.favoritesKey) ?? []
        recents = defaults.stringArray(forKey: Self.recentsKey) ?? []
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            customSources = saved
            rebuild()
        }
    }

    var all: [ToolDescriptor] { BuiltinTools.all + customTools.map { ToolDescriptor($0) } }

    func descriptor(id: String) -> ToolDescriptor? { all.first { $0.id == id } }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        favorites = Self.toggled(favorites, id)
        defaults.set(favorites, forKey: Self.favoritesKey)
    }

    func markUsed(_ id: String) {
        recents = Self.pushedRecent(recents, id)
        defaults.set(recents, forKey: Self.recentsKey)
    }

    nonisolated static func toggled(_ list: [String], _ id: String) -> [String] {
        list.contains(id) ? list.filter { $0 != id } : list + [id]
    }

    nonisolated static func pushedRecent(_ list: [String], _ id: String, limit: Int = 8) -> [String] {
        Array(([id] + list.filter { $0 != id }).prefix(limit))
    }

    /// 検証済みのツールを保存する(同じIDがあれば置き換える)
    func save(_ tool: CustomTool, json: String) {
        customSources[tool.id] = json
        persist()
        rebuild()
    }

    func delete(customID: String) {
        customSources[customID] = nil
        let descriptorID = "custom." + customID
        favorites.removeAll { $0 == descriptorID }
        recents.removeAll { $0 == descriptorID }
        defaults.set(favorites, forKey: Self.favoritesKey)
        defaults.set(recents, forKey: Self.recentsKey)
        defaults.removeObject(forKey: "tools.checklist." + customID)
        persist()
        rebuild()
    }

    private func rebuild() {
        customTools = customSources.values.compactMap { json -> CustomTool? in
            if case .success(let tool) = CustomToolParser.parse(json) { return tool }
            return nil
        }
        .sorted { $0.name < $1.name }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(customSources) { try? data.write(to: fileURL, options: .atomic) }
    }
}

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

/// Swift で作っている内蔵ツール(機器や iOS のデータ・正確な音が要るもの)。ほかの内蔵ツールは JavaScript 版(`BuiltinScriptTools`)。
/// 増やすときは、ここに足して、BuiltinTools.all に登録し、ToolScreen に画面を足す。
enum BuiltinTool: String, CaseIterable {
    case flashlight
    case worldClock
    case metronome
}

/// 小ツールの1件(内蔵でも、JSONで読み込んだものでも、同じ形で扱う)
struct ToolDescriptor: Equatable, Identifiable {
    enum Source: Equatable {
        case builtin(BuiltinTool)
        case custom(CustomTool)
        /// 組み込みのツールの JavaScript 版(v0.9.32。アプリに同梱。編集はできず、複製して編集する)
        case bundled(CustomTool)
    }

    /// 内蔵は "builtin.◯◯"(JavaScript 版も、Swift の版と同じ "builtin.timer" など。お気に入りと最近使ったを引き継ぐため)、
    /// 読み込んだものは "custom.◯◯"。以前の名前のない JavaScript 版(v0.9.32 だけ)は "bundled.◯◯" だった
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

    init(bundled: BuiltinScriptTool) {
        let tool = bundled.tool
        id = "builtin." + (bundled.legacy ?? bundled.file)
        name = tool.name
        summary = tool.summary
        symbol = tool.symbol
        category = tool.category
        keywords = tool.keywords
        source = .bundled(tool)
    }

    var isCustom: Bool {
        if case .custom = source { return true }
        return false
    }

    var isBundled: Bool {
        if case .bundled = source { return true }
        return false
    }

    var isScript: Bool {
        switch source {
        case .custom(let tool): return tool.kind == .script
        case .bundled: return true
        case .builtin: return false
        }
    }
}

enum BuiltinTools {
    static let all: [ToolDescriptor] = [
        ToolDescriptor(.flashlight, name: "懐中電灯", summary: "ライトを点け、明るさを調整", symbol: "flashlight.on.fill", category: .measure, keywords: ["light", "らいと", "ライト", "かいちゅうでんとう", "torch"]),
        ToolDescriptor(.worldClock, name: "世界時計", summary: "各地の時刻と、日本との時差", symbol: "globe", category: .time, keywords: ["world", "clock", "時差", "じさ", "タイムゾーン", "海外", "夏時間"]),
        ToolDescriptor(.metronome, name: "メトロノーム", summary: "テンポと拍子を決めて鳴らす", symbol: "metronome", category: .measure, keywords: ["metronome", "めとろのーむ", "テンポ", "BPM", "リズム", "拍子"]),
    ]

    /// 一覧の並び(v0.9.32 までの内蔵ツールの並び。ID の "builtin." の後ろ)。ないものは最後
    static let order = ["timer", "stopwatch", "dateCalc", "wareki", "splitBill", "percent", "unitConvert", "baseConvert", "roulette", "dice",
                        "coin", "teams", "order", "tournament", "counter", "textCount", "kanaConvert", "password", "flashlight", "timeCalc",
                        "worldClock", "amida", "scoreboard", "metronome"]

    /// Swift の内蔵ツールと、JavaScript 版の内蔵ツールを、決まった並びにする
    static let withScripts: [ToolDescriptor] = arranged(builtin: all, scripts: BuiltinScriptTools.all)

    static func arranged(builtin: [ToolDescriptor], scripts: [BuiltinScriptTool]) -> [ToolDescriptor] {
        let tools = builtin + scripts.map { ToolDescriptor(bundled: $0) }
        func rank(_ tool: ToolDescriptor) -> Int {
            order.firstIndex(of: String(tool.id.dropFirst("builtin.".count))) ?? order.count
        }
        return tools.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// 保存したお気に入り・最近使ったの ID を、今の ID に直す(v0.9.32 の JavaScript 版の "bundled.builtin-js.◯◯" → "builtin.◯◯")。
    /// 重なったら前のほうを残す
    static func migratedIDs(_ ids: [String], scripts: [BuiltinScriptTool] = BuiltinScriptTools.all) -> [String] {
        var result: [String] = []
        for id in ids {
            var next = id
            if id.hasPrefix("bundled."), let script = scripts.first(where: { "bundled." + $0.tool.id == id }) {
                next = ToolDescriptor(bundled: script).id
            }
            if !result.contains(next) { result.append(next) }
        }
        return result
    }
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

    /// 前回、スクリプト型のツールの実行中にアプリが止まった記録(起動したときに読む。利用者が選ぶまで残す)
    var crashedScript: ScriptRunRecord?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    /// 「実行中のツール」の記録(Application Support/script-running.json)
    @ObservationIgnored let runGuard: ScriptRunGuard
    /// ツールごとの保存領域(Application Support/script-storage/)
    @ObservationIgnored let scriptStorageDirectory: URL
    /// 読み込んだツールを削除したとき(データの許可の記録を消すのに使う)
    @ObservationIgnored var onDeleteCustom: ((String) -> Void)?

    static let maxRecents = 8
    private static let favoritesKey = "tools.favorites"
    private static let recentsKey = "tools.recents"

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        let base = fileURL.deletingLastPathComponent()
        runGuard = ScriptRunGuard(fileURL: base.appendingPathComponent("script-running.json"))
        scriptStorageDirectory = base.appendingPathComponent("script-storage", isDirectory: true)
        crashedScript = runGuard.load()
        let savedFavorites = defaults.stringArray(forKey: Self.favoritesKey) ?? []
        let savedRecents = defaults.stringArray(forKey: Self.recentsKey) ?? []
        favorites = BuiltinTools.migratedIDs(savedFavorites)
        recents = BuiltinTools.migratedIDs(savedRecents)
        if favorites != savedFavorites { defaults.set(favorites, forKey: Self.favoritesKey) }
        if recents != savedRecents { defaults.set(recents, forKey: Self.recentsKey) }
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            customSources = saved
            rebuild()
        }
    }

    var all: [ToolDescriptor] { BuiltinTools.withScripts + customTools.map { ToolDescriptor($0) } }

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
        onDeleteCustom?(customID)
        ScriptNotifications.cancelAll(toolID: customID)
        customSources[customID] = nil
        let descriptorID = "custom." + customID
        favorites.removeAll { $0 == descriptorID }
        recents.removeAll { $0 == descriptorID }
        defaults.set(favorites, forKey: Self.favoritesKey)
        defaults.set(recents, forKey: Self.recentsKey)
        defaults.removeObject(forKey: "tools.checklist." + customID)
        // スクリプト型の保存領域も消す
        try? FileManager.default.removeItem(at: ScriptStorage.storageURL(toolID: customID, directory: scriptStorageDirectory))
        persist()
        rebuild()
    }

    /// 前回止まったツールについて、利用者が選んだら記録を消す
    func resolveCrashedScript() {
        crashedScript = nil
        runGuard.end()
    }

    func customTool(id: String) -> CustomTool? { customTools.first { $0.id == id } }

    /// スクリプト型のツール(読み込んだものか、組み込みの JavaScript 版)
    func scriptTool(id: String) -> CustomTool? { customTool(id: id) ?? BuiltinScriptTools.tool(id: id)?.tool }

    /// 組み込みの JavaScript 版を、編集できる複製として保存する JSON(保存は確認の画面で利用者が押す)
    func copyJSON(of bundled: BuiltinScriptTool) -> String? {
        let identity = BuiltinScriptTools.copyIdentity(of: bundled, existing: Set(customSources.keys))
        return BuiltinScriptTools.copyJSON(bundled.json, newID: identity.id, name: identity.name)
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

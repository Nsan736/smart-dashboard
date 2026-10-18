import Foundation
import Observation

/// Claude API の設定(AppSettings.claude に JSON で保存する)。APIキーは Keychain に置き、ここには入れない。
struct ClaudeSettings: Codable, Equatable {
    static let defaultModel = "claude-haiku-5-5"
    static let defaultMonthlyLimit = 5.0
    static let currentPrivacyVersion = 2
    static let maxWebSearches = 10

    var model = ClaudeSettings.defaultModel
    var pricing = ClaudePricing()
    /// 月の上限額(ドル)。今月の使用額がこれに達したら、呼び出しを止める。
    var monthlyLimit = ClaudeSettings.defaultMonthlyLimit
    /// 機能ごとの思考(適応的思考)。初期値は、どちらもオン(正確さを優先)。
    var thinkingForTools = true
    var thinkingForCamera = true
    /// カメラの質問で一緒に送る情報。居場所が推測できるもの(地名・緯度経度・周りの地点)は、初期値で送らない(v0.9.20)。
    /// 撮ったときの方角と端末の上下の向き(居場所は分からない)
    var sendsHeading = true
    /// 現在地のおおよその地名(居場所が分かる)
    var sendsPlace = false
    /// 現在地の緯度経度(おおよそ。小数第3位まで。居場所が分かる)
    var sendsCoordinates = false
    /// 撮った方向にある登録した地点・周辺の施設・電車の名前と距離(居場所が推測できる)
    var sendsTargets = false
    /// カメラの質問で、Claude に Web 検索を使わせる(サーバー側の検索。1回ごとに料金がかかる)
    var webSearch = true
    /// 1回の質問で使う Web 検索の上限
    var webSearchMaxUses = 3
    /// 送る情報の初期値の版。2 から、居場所が推測できる情報を初期値で送らない(以前の版の設定も、読み込むときに合わせる)。
    var privacyVersion = ClaudeSettings.currentPrivacyVersion
    /// 送る画像の長い辺(px)。モバイル通信のときは smallerOnCellular なら cellularImageEdge。
    var imageEdge = 1024
    var smallerOnCellular = true
    var cellularImageEdge = 768

    init() {}

    /// 項目が足りない古い保存内容も、足りない項目を初期値にして読む
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ClaudeSettings()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? base.model
        pricing = try c.decodeIfPresent(ClaudePricing.self, forKey: .pricing) ?? base.pricing
        monthlyLimit = try c.decodeIfPresent(Double.self, forKey: .monthlyLimit) ?? base.monthlyLimit
        thinkingForTools = try c.decodeIfPresent(Bool.self, forKey: .thinkingForTools) ?? base.thinkingForTools
        thinkingForCamera = try c.decodeIfPresent(Bool.self, forKey: .thinkingForCamera) ?? base.thinkingForCamera
        sendsHeading = try c.decodeIfPresent(Bool.self, forKey: .sendsHeading) ?? base.sendsHeading
        sendsPlace = try c.decodeIfPresent(Bool.self, forKey: .sendsPlace) ?? base.sendsPlace
        sendsCoordinates = try c.decodeIfPresent(Bool.self, forKey: .sendsCoordinates) ?? base.sendsCoordinates
        sendsTargets = try c.decodeIfPresent(Bool.self, forKey: .sendsTargets) ?? base.sendsTargets
        imageEdge = try c.decodeIfPresent(Int.self, forKey: .imageEdge) ?? base.imageEdge
        smallerOnCellular = try c.decodeIfPresent(Bool.self, forKey: .smallerOnCellular) ?? base.smallerOnCellular
        cellularImageEdge = try c.decodeIfPresent(Int.self, forKey: .cellularImageEdge) ?? base.cellularImageEdge
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? base.webSearch
        webSearchMaxUses = min(max(try c.decodeIfPresent(Int.self, forKey: .webSearchMaxUses) ?? base.webSearchMaxUses, 1), Self.maxWebSearches)
        privacyVersion = try c.decodeIfPresent(Int.self, forKey: .privacyVersion) ?? 1
        if privacyVersion < 2 {
            // v0.9.19 までは、地名・緯度経度・周りの地点も初期値で送っていた。居場所が推測できるので、送らない設定に合わせる。
            sendsPlace = false
            sendsCoordinates = false
            sendsTargets = false
            privacyVersion = Self.currentPrivacyVersion
        }
    }

    /// 回線に合わせた、送る画像の長い辺
    func imageEdge(isExpensive: Bool) -> Int {
        isExpensive && smallerOnCellular ? min(imageEdge, cellularImageEdge) : imageEdge
    }
}

/// 1か月分の使用量と金額(呼び出したときの料金で計算した値を足していく)
struct ClaudeMonthUsage: Codable, Equatable {
    var usage = ClaudeUsage()
    var cost = 0.0
    var calls = 0
}

/// 月ごとの使用量(直近12か月を残す)
struct ClaudeLedger: Codable, Equatable {
    var months: [String: ClaudeMonthUsage] = [:]

    static let keptMonths = 12

    /// 「2026-10」(日本時間の月)
    static func monthKey(_ date: Date) -> String {
        let components = JapaneseHolidays.calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    func month(_ date: Date) -> ClaudeMonthUsage { months[Self.monthKey(date)] ?? ClaudeMonthUsage() }

    mutating func add(_ usage: ClaudeUsage, cost: Double, at date: Date) {
        let key = Self.monthKey(date)
        var month = months[key] ?? ClaudeMonthUsage()
        month.usage += usage
        month.cost += cost
        month.calls += 1
        months[key] = month
        // 古い月を消す(キーは「年-月」なので、文字の順が月の順)
        let sorted = months.keys.sorted()
        if sorted.count > Self.keptMonths {
            for old in sorted.prefix(sorted.count - Self.keptMonths) { months[old] = nil }
        }
    }
}

/// 呼び出す前の確認(APIキー、月の上限、回線)。純粋なロジック。
enum ClaudeGate {
    static func check(hasKey: Bool, spent: Double, limit: Double, isOnline: Bool) -> ClaudeError? {
        if !hasKey { return .missingKey }
        if spent >= limit { return .overBudget(spent: spent, limit: limit) }
        if !isOnline { return .offline }
        return nil
    }
}

/// 1回の呼び出しの結果(応答と、そのときの料金で計算した金額)
struct ClaudeCallResult: Equatable, Sendable {
    var response: ClaudeResponse
    var cost: Double
}

/// Claude API の呼び出しをまとめて受け持つ。APIキーの確認、月の上限、回線、使用量の記録。
@MainActor
@Observable
final class ClaudeService {
    private(set) var hasKey: Bool
    private(set) var ledger: ClaudeLedger

    @ObservationIgnored private let client: ClaudeClient
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let defaults: UserDefaults
    private static let ledgerKey = "claude.ledger"

    init(client: ClaudeClient, keychain: KeychainStore, settings: AppSettings, network: NetworkMonitor, defaults: UserDefaults = .standard) {
        self.client = client
        self.keychain = keychain
        self.settings = settings
        self.network = network
        self.defaults = defaults
        hasKey = !(keychain.string(for: KeychainAccount.claudeAPIKey) ?? "").isEmpty
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(ClaudeLedger.self, from: $0) } ?? ClaudeLedger()
    }

    /// 空文字を渡すと削除する。キーは Keychain だけに保存し、ログにも出さない。
    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keychain.set(trimmed, for: KeychainAccount.claudeAPIKey)
        hasKey = !trimmed.isEmpty
    }

    var thisMonth: ClaudeMonthUsage { ledger.month(Date()) }

    /// 今呼び出せないときの理由。呼び出せるなら nil。
    var blockReason: ClaudeError? {
        ClaudeGate.check(hasKey: hasKey, spent: thisMonth.cost, limit: settings.claude.monthlyLimit, isOnline: network.status.isOnline)
    }

    /// 呼び出して、使用量を記録する。取り消されたときは CancellationError。
    func call(_ request: ClaudeRequest) async throws -> ClaudeCallResult {
        if let reason = blockReason { throw reason }
        guard let key = keychain.string(for: KeychainAccount.claudeAPIKey), !key.isEmpty else { throw ClaudeError.missingKey }
        let response = try await client.send(request, apiKey: key)
        let cost = settings.claude.pricing.cost(response.usage)
        ledger.add(response.usage, cost: cost, at: Date())
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Self.ledgerKey) }
        return ClaudeCallResult(response: response, cost: cost)
    }
}

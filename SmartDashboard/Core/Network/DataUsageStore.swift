import Foundation
import Observation

/// 通信した回線
enum UsageLink: String, Codable, CaseIterable, Sendable {
    case wifi
    /// モバイル通信(テザリングなど従量制の回線を含む)
    case cellular
    /// 回線別の記録を始める前の記録
    case unknown

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "モバイル通信"
        case .unknown: return "回線不明(以前の記録)"
        }
    }
}

/// 通信した機能。通信先のホストから判定する。
enum UsageCategory: String, Codable, CaseIterable, Sendable {
    case weather
    case exchange
    case train
    case radar
    case mapTiles
    case other
    /// 機能別の記録を始める前の記録
    case legacy

    var label: String {
        switch self {
        case .weather: return "天気"
        case .exchange: return "為替"
        case .train: return "電車"
        case .radar: return "レーダー・雨の要約"
        case .mapTiles: return "地図タイル(地理院)"
        case .other: return "その他"
        case .legacy: return "以前の記録"
        }
    }

    static func from(host: String?) -> UsageCategory {
        guard let host = host?.lowercased() else { return .other }
        if host.hasSuffix("open-meteo.com") { return .weather }
        if host.hasSuffix("er-api.com") { return .exchange }
        if host.hasSuffix("odpt.org") { return .train }
        if host.hasSuffix("jma.go.jp") { return .radar }
        if host.hasSuffix("gsi.go.jp") { return .mapTiles }
        return .other
    }
}

/// 通信1回分の記録
struct UsageRecord: Sendable, Equatable {
    let bytes: Int64
    let link: UsageLink
    let category: UsageCategory
}

/// 1日分の記録。bytes[回線][機能] = バイト数
struct DayUsage: Codable, Equatable {
    var bytes: [String: [String: Int64]] = [:]
    /// 地名の取得(CLGeocoder)の回数。通信はiOSが行うためバイト数は計測できない。
    var geocodeRequests = 0

    func total(link: UsageLink?) -> Int64 {
        bytes.filter { link == nil || $0.key == link?.rawValue }
            .values.reduce(Int64(0)) { $0 + $1.values.reduce(Int64(0), +) }
    }

    func total(link: UsageLink, category: UsageCategory) -> Int64 {
        bytes[link.rawValue]?[category.rawValue] ?? 0
    }

    mutating func add(_ record: UsageRecord) {
        bytes[record.link.rawValue, default: [:]][record.category.rawValue, default: 0] += record.bytes
    }
}

/// 受信バイト数を、日別・回線別・機能別に記録する。キーは "yyyy-MM-dd"。
@MainActor
@Observable
final class DataUsageStore {
    private(set) var days: [String: DayUsage] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// 記録が変わったとき(モバイル通信量の上限の判定に使う)
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    /// legacyFileURL は回線別に分ける前の形式([日付: バイト数])。あれば「回線不明」として引き継ぐ。
    init(fileURL: URL, legacyFileURL: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: DayUsage].self, from: data) {
            days = decoded
        } else if let legacyFileURL, let data = try? Data(contentsOf: legacyFileURL) {
            days = Self.migrate(legacy: data)
            if !days.isEmpty { scheduleSave() }
        }
    }

    nonisolated static func migrate(legacy data: Data) -> [String: DayUsage] {
        guard let old = try? JSONDecoder().decode([String: Int64].self, from: data) else { return [:] }
        return old.mapValues { bytes in
            var day = DayUsage()
            day.add(UsageRecord(bytes: bytes, link: .unknown, category: .legacy))
            return day
        }
    }

    private var todayKey: String { Self.dayKey(now()) }
    private var monthPrefix: String { String(todayKey.prefix(7)) }
    private var monthDays: [DayUsage] { days.filter { $0.key.hasPrefix(monthPrefix) }.map(\.value) }

    func today(_ link: UsageLink? = nil) -> Int64 {
        days[todayKey]?.total(link: link) ?? 0
    }

    func thisMonth(_ link: UsageLink? = nil) -> Int64 {
        monthDays.reduce(Int64(0)) { $0 + $1.total(link: link) }
    }

    func thisMonth(_ link: UsageLink, _ category: UsageCategory) -> Int64 {
        monthDays.reduce(Int64(0)) { $0 + $1.total(link: link, category: category) }
    }

    var geocodeRequestsThisMonth: Int {
        monthDays.reduce(0) { $0 + $1.geocodeRequests }
    }

    func add(_ record: UsageRecord) {
        guard record.bytes > 0 else { return }
        days[todayKey, default: DayUsage()].add(record)
        changed()
    }

    func addGeocodeRequest() {
        days[todayKey, default: DayUsage()].geocodeRequests += 1
        changed()
    }

    func reset() {
        days = [:]
        changed()
    }

    private func changed() {
        prune()
        scheduleSave()
        onChange?()
    }

    /// 2か月より古い記録を捨てる
    private func prune() {
        guard days.count > 70,
              let limit = Calendar.current.date(byAdding: .day, value: -62, to: now()) else { return }
        let limitKey = Self.dayKey(limit)
        days = days.filter { $0.key >= limitKey }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = days
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    nonisolated static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

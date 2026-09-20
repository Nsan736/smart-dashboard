import Foundation

/// キャッシュするデータの種類と、最短の更新間隔
enum DataKind: String, CaseIterable, Codable {
    case weather
    case exchange
    case rainNowcast
    case warning
    case quake
    case pressureHistory
    case trainInfo
    case trainDelay
    case railwayCatalog

    var minimumInterval: TimeInterval {
        switch self {
        case .weather: return 30 * 60
        case .exchange: return 24 * 60 * 60
        case .rainNowcast: return 10 * 60
        case .warning: return 10 * 60
        case .quake: return 5 * 60
        case .pressureHistory: return 3 * 60 * 60
        case .trainInfo: return 5 * 60
        case .trainDelay: return 2 * 60
        case .railwayCatalog: return 30 * 24 * 60 * 60
        }
    }

    var label: String {
        switch self {
        case .weather: return "天気"
        case .exchange: return "為替"
        case .rainNowcast: return "雨のナウキャスト"
        case .warning: return "警報・注意報"
        case .quake: return "地震情報"
        case .pressureHistory: return "気圧の履歴・7日先の予報"
        case .trainInfo: return "運行情報"
        case .trainDelay: return "列車の遅れ"
        case .railwayCatalog: return "路線・駅の一覧"
        }
    }
}

enum RefreshDecision: Equatable {
    case refresh
    case fresh
    case offline
    case blockedByConstrained
    case blockedByWiFiOnly
    case blockedByCellularLimit
}

/// 自動更新してよいかどうかを決める純関数。手動更新はオンラインなら常に許可する。
/// モバイル通信(従量制の回線)でも、最短の更新間隔を守ったうえで自動更新する。
/// 止めるのは、省データモード、「Wi-Fi時のみ」の設定、今月のモバイル通信量が上限を超えたとき。
struct RefreshPolicy {
    var wifiOnly: Bool
    /// 今月のモバイル通信量が、設定した上限を超えているか(上限の設定がオフなら常にfalse)
    var cellularLimitReached = false

    func autoDecision(kind: DataKind, fetchedAt: Date?, now: Date, network: NetworkStatus) -> RefreshDecision {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < kind.minimumInterval, fetchedAt <= now {
            return .fresh
        }
        guard network.isOnline else { return .offline }
        if network.isConstrained { return .blockedByConstrained }
        // テザリングのように、Wi-Fiでも従量制の回線はモバイル通信として扱う
        let isMobile = network.isExpensive || !network.isWiFi
        if wifiOnly && isMobile { return .blockedByWiFiOnly }
        if cellularLimitReached && isMobile { return .blockedByCellularLimit }
        return .refresh
    }

    /// 列車の遅れの最短の取得間隔。Wi-Fiで2分、モバイル通信で5分。
    static func trainDelayInterval(network: NetworkStatus) -> TimeInterval {
        (network.isExpensive || !network.isWiFi) ? 5 * 60 : 2 * 60
    }

    func manualDecision(network: NetworkStatus) -> RefreshDecision {
        network.isOnline ? .refresh : .offline
    }
}

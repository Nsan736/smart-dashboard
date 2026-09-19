import Foundation

/// キャッシュするデータの種類と、最短の更新間隔
enum DataKind: String, CaseIterable, Codable {
    case weather
    case exchange
    case trainInfo
    case railwayCatalog

    var minimumInterval: TimeInterval {
        switch self {
        case .weather: return 30 * 60
        case .exchange: return 24 * 60 * 60
        case .trainInfo: return 5 * 60
        case .railwayCatalog: return 30 * 24 * 60 * 60
        }
    }

    var label: String {
        switch self {
        case .weather: return "天気"
        case .exchange: return "為替"
        case .trainInfo: return "運行情報"
        case .railwayCatalog: return "路線・駅の一覧"
        }
    }
}

enum RefreshDecision: Equatable {
    case refresh
    case fresh
    case offline
    case blockedByExpensive
    case blockedByConstrained
    case blockedByWiFiOnly
}

/// 自動更新してよいかどうかを決める純関数。手動更新はオンラインなら常に許可する。
struct RefreshPolicy {
    var wifiOnly: Bool

    func autoDecision(kind: DataKind, fetchedAt: Date?, now: Date, network: NetworkStatus) -> RefreshDecision {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < kind.minimumInterval, fetchedAt <= now {
            return .fresh
        }
        guard network.isOnline else { return .offline }
        if network.isConstrained { return .blockedByConstrained }
        if network.isExpensive { return .blockedByExpensive }
        if wifiOnly && !network.isWiFi { return .blockedByWiFiOnly }
        return .refresh
    }

    func manualDecision(network: NetworkStatus) -> RefreshDecision {
        network.isOnline ? .refresh : .offline
    }
}

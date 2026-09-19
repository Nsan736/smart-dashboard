import Foundation

enum ODPTEndpoint: String, Codable {
    /// トークン不要の公開エンドポイント
    case publicAPI
    /// トークン(acl:consumerKey)が必要なエンドポイント
    case authenticated

    var baseURL: URL {
        switch self {
        case .publicAPI: return URL(string: "https://api-public.odpt.org/api/v4/")!
        case .authenticated: return URL(string: "https://api.odpt.org/api/v4/")!
        }
    }

    var requiresToken: Bool { self == .authenticated }
}

struct TrainOperator: Identifiable, Equatable {
    /// ODPTの事業者ID (例: odpt.Operator:Toei)
    let id: String
    let name: String
    let endpoint: ODPTEndpoint
    /// odpt:TrainInformation を提供しているか
    var providesTrainInformation = true
    /// odpt:StationTimetable を提供しているか
    var providesStationTimetable = true
}

/// 事業者の定義。事業者を増やすときはここに1行追加するだけでよい。
/// 路線や駅はここには書かず、アプリの登録画面でAPIから選ぶ。
enum OperatorCatalog {
    static let all: [TrainOperator] = [
        TrainOperator(id: "odpt.Operator:Toei", name: "都営(東京都交通局)", endpoint: .publicAPI),
        TrainOperator(id: "odpt.Operator:TokyoMetro", name: "東京メトロ", endpoint: .authenticated),
    ]

    static func find(_ id: String) -> TrainOperator? {
        all.first { $0.id == id }
    }
}

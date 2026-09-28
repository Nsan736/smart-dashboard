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

/// 事業者・路線で使えるデータ。事業者の検出(OperatorDetection)で決める。
struct ODPTCapabilities: Codable, Equatable {
    /// 運行情報 (odpt:TrainInformation)
    var trainInformation = false
    /// 列車ごとの時刻表 (odpt:TrainTimetable)。列車の位置、駅に重ねる電車、経路の検索、乗車中の判定の照合に使う。
    var trainTimetable = false
    /// 駅の時刻表 (odpt:StationTimetable)
    var stationTimetable = false
    /// 駅の位置 (odpt:Station の geo:lat / geo:long)。地図と路線の線に使う。
    var stationLocation = false
    /// 列車ごとの遅れ (odpt:Train の odpt:delay)。nil は未確認(検出したときに走っている列車がなかった)。
    var delay: Bool? = nil

    /// 何か1つでも使えるデータがあるか(駅の位置だけでは、登録しても使える機能がない)
    var isUsable: Bool { trainInformation || trainTimetable || stationTimetable }

    /// 検出する前(予備の定義)は、すべて使えるものとして扱い、取得できなかったときにその旨を表示する
    static let assumed = ODPTCapabilities(trainInformation: true, trainTimetable: true, stationTimetable: true,
                                          stationLocation: true, delay: nil)

    /// 一覧に出す小さなラベル(運行情報/時刻表/遅れ/地図)。使えるものだけ。
    var labels: [String] {
        var list: [String] = []
        if trainInformation { list.append("運行情報") }
        if trainTimetable || stationTimetable { list.append("時刻表") }
        if delay == true { list.append("遅れ") }
        if stationLocation { list.append("地図") }
        return list
    }

    /// 路線をまとめた、事業者全体の値(どれかの路線で使えれば使える)
    static func union(_ list: [ODPTCapabilities]) -> ODPTCapabilities {
        var result = ODPTCapabilities()
        for item in list {
            result.trainInformation = result.trainInformation || item.trainInformation
            result.trainTimetable = result.trainTimetable || item.trainTimetable
            result.stationTimetable = result.stationTimetable || item.stationTimetable
            result.stationLocation = result.stationLocation || item.stationLocation
            switch (result.delay, item.delay) {
            case (true?, _), (_, true?): result.delay = true
            case (false?, _), (_, false?): result.delay = false
            default: break
            }
        }
        return result
    }
}

struct TrainOperator: Identifiable, Equatable {
    /// ODPTの事業者ID (例: odpt.Operator:Toei)
    let id: String
    let name: String
    let endpoint: ODPTEndpoint
    var capabilities: ODPTCapabilities = .assumed
    /// 検出した路線(予備の定義では空。登録の画面では、そのときに路線の一覧を取得する)
    var railways: [DetectedRailway] = []
    /// 検出できなかったときの予備の定義(OperatorCatalog.fallback)
    var isFallback = false
}

/// 事業者の定義。事業者は自動で検出する(OperatorDiscoveryStore)ので、ここに書き足す必要はない。
/// ここにあるのは、検出できなかったときの予備と、表示名・並び順・エンドポイントの上書き、使わない事業者だけ。
enum OperatorCatalog {
    struct Override {
        var id: String
        var name: String
        /// 公開エンドポイントでも取れる事業者は、トークンがなくても(無効でも)使えるように公開エンドポイントを使う
        var endpoint: ODPTEndpoint? = nil
    }

    /// 表示名とエンドポイントの上書き。並び順はこの順で、ほかの事業者は後ろに名前の順で並ぶ。
    static let overrides: [Override] = [
        Override(id: "odpt.Operator:Toei", name: "都営(東京都交通局)", endpoint: .publicAPI),
        Override(id: "odpt.Operator:TokyoMetro", name: "東京メトロ"),
    ]

    /// 検出できなかったとき(検出の前、通信できないときなど)の予備
    static let fallback: [TrainOperator] = [
        TrainOperator(id: "odpt.Operator:Toei", name: "都営(東京都交通局)", endpoint: .publicAPI, isFallback: true),
        TrainOperator(id: "odpt.Operator:TokyoMetro", name: "東京メトロ", endpoint: .authenticated, isFallback: true),
    ]

    /// 「公共交通オープンデータチャレンジ」限定ライセンスのデータを出している事業者。
    /// 利用条件がチャレンジへの応募作品に限られるので、検出の対象から外す(2026-09-28に ckan.odpt.org のデータセットのライセンスで確認)。
    /// ライセンスが変わったら、ここを直す。
    static let challengeOnly: [String: String] = [
        "odpt.Operator:JR-East": "JR東日本",
        "odpt.Operator:Keio": "京王電鉄",
        "odpt.Operator:Odakyu": "小田急電鉄",
        "odpt.Operator:Keikyu": "京急電鉄",
        "odpt.Operator:Sotetsu": "相模鉄道",
        "odpt.Operator:Tobu": "東武鉄道",
        "odpt.Operator:Seibu": "西武鉄道",
        "odpt.Operator:Tokyu": "東急電鉄",
    ]

    static let challengeOnlyReason = "公共交通オープンデータチャレンジ限定のライセンスのため使いません"

    static func override(_ id: String) -> Override? {
        overrides.first { $0.id == id }
    }

    /// 並び順(上書きにある事業者だけ)
    static func order(of id: String) -> Int? {
        overrides.firstIndex { $0.id == id }
    }

    /// 検出の結果の一覧を並べる(上書きにある事業者が先、ほかは名前の順)
    static func sorted(_ list: [TrainOperator]) -> [TrainOperator] {
        list.sorted { a, b in
            switch (order(of: a.id), order(of: b.id)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

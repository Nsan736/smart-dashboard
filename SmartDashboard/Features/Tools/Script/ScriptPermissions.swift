import Foundation

/// スクリプトが読めるアプリのデータの種類(ツールの JSON の permissions に書く)。
/// どれも、アプリがすでに取得・保存しているものの写しだけで、スクリプトから新しい通信は起きない。書き換える機能もない。
enum ScriptPermission: String, CaseIterable, Identifiable, Codable {
    case weather
    case quake
    case pressure
    case exchange
    case trains
    case places
    case locationCoarse = "location.coarse"
    case locationPrecise = "location.precise"
    case sensors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather: return "天気・雨の要約・警報"
        case .quake: return "地震情報"
        case .pressure: return "気圧の記録と予報"
        case .exchange: return "為替"
        case .trains: return "登録した路線の運行情報・次の電車・列車の位置"
        case .places: return "登録した地点の一覧と方角・距離"
        case .locationCoarse: return "おおよその地域(都道府県・市区町村まで)"
        case .locationPrecise: return "現在地の緯度経度・高度"
        case .sensors: return "センサー(歩数・速度・方位・気圧計・加速度)"
        }
    }

    var detail: String {
        switch self {
        case .weather: return "天気を取得した地点の、今の天気・1時間ごと・7日間・雨の要約・警報と注意報"
        case .quake: return "最近の地震(震源・規模・震度)"
        case .pressure: return "端末で記録した気圧と、予報の気圧、今後3時間の変化"
        case .exchange: return "保存している為替のレート"
        case .trains: return "運行情報、登録した駅の次の電車、時刻表から計算した列車の位置"
        case .places: return "地点の名前と、最後に分かった現在地からの方角・距離・高低差(緯度経度は「現在地の緯度経度」を許可したときだけ)"
        case .locationCoarse: return "最後に分かった現在地の、都道府県と市区町村の名前"
        case .locationPrecise: return "最後に分かった現在地の緯度経度・高度・精度。居場所がそのまま分かります"
        case .sensors: return "スクリプトが使い始めたときだけ動かし、ツールを閉じたら止めます。速度は位置情報を、気圧計と加速度はモーションのセンサーを使います"
        }
    }

    var symbol: String {
        switch self {
        case .weather: return "cloud.sun"
        case .quake: return "waveform.path.ecg"
        case .pressure: return "barometer"
        case .exchange: return "yensign.circle"
        case .trains: return "tram"
        case .places: return "mappin.and.ellipse"
        case .locationCoarse: return "map"
        case .locationPrecise: return "location.fill"
        case .sensors: return "sensor"
        }
    }

    /// 目立たせて表示する種類(居場所が分かる・センサーを動かす)
    var isSensitive: Bool { self == .locationPrecise || self == .sensors }

    /// 許可を求める画面で、初めから選んでおくか(目立たせる種類は、選んでおかない)
    var grantedByDefault: Bool { !isSensitive }

    /// JSON の permissions を読む。重複は1つにまとめ、並びは CaseIterable の順。
    static func parse(_ raw: Any?, issues: inout [ToolIssue]) -> [ScriptPermission] {
        guard let raw else { return [] }
        guard let list = raw as? [Any], list.count <= 20 else {
            issues.append(ToolIssue(path: "permissions", message: "データの種類の文字列の配列にしてください"))
            return []
        }
        var found = Set<ScriptPermission>()
        for (index, item) in list.enumerated() {
            guard let text = item as? String, let permission = ScriptPermission(rawValue: text) else {
                issues.append(ToolIssue(path: "permissions[\(index)]",
                                        message: allCases.map(\.rawValue).joined(separator: " / ") + " のどれかにしてください"))
                continue
            }
            found.insert(permission)
        }
        return allCases.filter { found.contains($0) }
    }
}

/// ツールごとの許可の状態。ツールの ID → 種類 → 許可したか。まだ聞いていない種類は入っていない。
struct ScriptPermissionGrants: Equatable, Codable {
    var tools: [String: [String: Bool]] = [:]

    /// まだ許可を聞いていない種類(JSON に書いてあるもののうち)
    func undecided(_ requested: [ScriptPermission], toolID: String) -> [ScriptPermission] {
        let decided = tools[toolID] ?? [:]
        return requested.filter { decided[$0.rawValue] == nil }
    }

    /// スクリプトに渡す種類。JSON に書いてあって、許可したものだけ(書いていない種類は、許可の記録があっても渡さない)。
    func granted(_ requested: [ScriptPermission], toolID: String) -> Set<ScriptPermission> {
        let decided = tools[toolID] ?? [:]
        return Set(requested.filter { decided[$0.rawValue] == true })
    }

    func isGranted(_ permission: ScriptPermission, toolID: String) -> Bool {
        tools[toolID]?[permission.rawValue] == true
    }

    mutating func set(_ permission: ScriptPermission, granted: Bool, toolID: String) {
        tools[toolID, default: [:]][permission.rawValue] = granted
    }

    /// 許可を求める画面で選んだ結果をまとめて記録する
    mutating func record(_ choices: [ScriptPermission: Bool], toolID: String) {
        for (permission, granted) in choices { set(permission, granted: granted, toolID: toolID) }
    }

    /// すべて取り消す(次に開いたときに、もう一度聞く)
    mutating func reset(toolID: String) {
        tools[toolID] = nil
    }
}

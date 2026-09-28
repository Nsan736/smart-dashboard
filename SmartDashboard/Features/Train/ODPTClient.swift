import Foundation

enum ODPTError: LocalizedError, Equatable {
    case tokenRequired(String)
    case unauthorized
    /// 200番台でない応答。url はトークンを除いたもの、body は応答の本文(エラーの内容。先頭だけ)。
    case requestFailed(name: String, status: Int, body: String, url: String)

    var errorDescription: String? {
        switch self {
        case .tokenRequired(let name): return "\(name)の取得にはODPTのアクセストークンが必要です。設定で入力してください。"
        case .unauthorized: return "ODPTのアクセストークンが無効か、期限が切れています。ODPTのサイトで確かめて、設定で入力し直してください。"
        case let .requestFailed(name, status, body, _):
            return "\(name)を取得できませんでした(HTTP \(status)\(body.isEmpty ? "" : ": " + body))"
        }
    }

    /// 失敗したリクエストのURL(トークンを除く)
    var requestURL: String? {
        if case let .requestFailed(_, _, _, url) = self { return url }
        return nil
    }
}

/// ODPT の問い合わせの組み立て
enum ODPTQuery {
    /// 1つの絞り込みに、カンマ区切りで並べられる値の数の上限。
    /// 11以上は HTTP 400「too many OR condition in ...」になる(2026-09-28に確認。トークンありのエンドポイントも同じ)。
    static let maxORValues = 10

    /// 値を上限ずつに分ける。空の値と重複は除く(空の絞り込みは 200 で空の配列が返り、失敗に気づけないため送らない)。
    static func chunks(_ values: [String], size: Int = maxORValues) -> [[String]] {
        var seen = Set<String>()
        let list = values.filter { !$0.isEmpty && seen.insert($0).inserted }
        return stride(from: 0, to: list.count, by: max(1, size)).map { Array(list[$0..<min($0 + max(1, size), list.count)]) }
    }
}

protocol ODPTAPI: Sendable {
    func railways(of op: TrainOperator) async throws -> [ODPTRailway]
    func stations(ofRailway railwayID: String, op: TrainOperator) async throws -> [ODPTStation]
    func stations(ids: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStation]
    /// 事業者のすべての駅(乗り換えの関係と緯度経度を含む)。経路の検索と駅の検索に使う。
    func stations(ofOperator op: TrainOperator) async throws -> [ODPTStation]
    /// 複数の事業者のすべての駅(事業者を10件ずつに分けて問い合わせる)。駅と路線の検索の一覧に使う。
    func stations(operatorIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStation]
    /// 運行情報の応答を、デコードせずにそのまま返す(遅延時のサンプル収集にも使うため)
    func trainInformationData(op: TrainOperator, railwayIDs: [String]) async throws -> Data
    func stationTimetables(stationID: String, directionID: String, op: TrainOperator) async throws -> [ODPTStationTimetable]
    func railDirections(endpoint: ODPTEndpoint) async throws -> [ODPTRailDirection]
    func trainTypes(of op: TrainOperator) async throws -> [ODPTTrainType]
    /// 列車ごとの時刻表。1回の応答は1000件で打ち切られるので、カレンダー(と必要なら方面)で分けて取得する。
    func trainTimetables(railwayID: String, calendarID: String, directionID: String?, op: TrainOperator) async throws -> [ODPTTrainTimetable]
    /// 列車のリアルタイム情報。登録した路線だけに絞る(カンマ区切りでOR指定。10件ずつに分ける)。
    func trains(op: TrainOperator, railwayIDs: [String]) async throws -> [ODPTTrain]

    // 事業者の検出(OperatorDiscoveryStore)。複数の事業者・IDはカンマ区切りで、10件ずつに分けて問い合わせる。
    func operators(endpoint: ODPTEndpoint) async throws -> [ODPTOperator]
    /// すべての路線(絞り込みなし。事業者を並べると上限を超えるため)
    func railways(endpoint: ODPTEndpoint) async throws -> [ODPTRailway]
    func trainInformation(operatorIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTTrainInformation]
    func trains(operatorIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTTrain]
    func stationTimetables(ids: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStationTimetable]
    func trainTimetables(trainIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTTrainTimetable]
}

struct ODPTClient: ODPTAPI {
    let http: HTTPClient
    /// Keychainからトークンを読む。コードには埋め込まない。
    let tokenProvider: @Sendable () -> String?

    var hasToken: Bool { !(tokenProvider() ?? "").isEmpty }

    func railways(of op: TrainOperator) async throws -> [ODPTRailway] {
        try await get("odpt:Railway", [("odpt:operator", op.id)], op.endpoint, op.name)
    }

    func stations(ofRailway railwayID: String, op: TrainOperator) async throws -> [ODPTStation] {
        try await get("odpt:Station", [("odpt:railway", railwayID)], op.endpoint, op.name)
    }

    func stations(ofOperator op: TrainOperator) async throws -> [ODPTStation] {
        try await get("odpt:Station", [("odpt:operator", op.id)], op.endpoint, op.name)
    }

    func stations(operatorIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStation] {
        try await getEach("odpt:Station", key: "odpt:operator", values: operatorIDs, endpoint, "駅の一覧")
    }

    func stations(ids: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStation] {
        try await getEach("odpt:Station", key: "owl:sameAs", values: ids, endpoint, "駅")
    }

    /// 登録した路線だけに絞って取得する(カンマ区切りでOR指定。10件ずつに分けたときは、応答の配列をつなぐ)
    func trainInformationData(op: TrainOperator, railwayIDs: [String]) async throws -> Data {
        let chunks = ODPTQuery.chunks(railwayIDs)
        guard chunks.count > 1 else {
            guard let chunk = chunks.first else { return Data("[]".utf8) }
            return try await getData("odpt:TrainInformation", [("odpt:railway", chunk.joined(separator: ","))], op.endpoint, op.name)
        }
        var merged: [Any] = []
        for chunk in chunks {
            let data = try await getData("odpt:TrainInformation", [("odpt:railway", chunk.joined(separator: ","))], op.endpoint, op.name)
            merged += (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
        }
        return try JSONSerialization.data(withJSONObject: merged)
    }

    func stationTimetables(stationID: String, directionID: String, op: TrainOperator) async throws -> [ODPTStationTimetable] {
        try await get("odpt:StationTimetable", [("odpt:station", stationID), ("odpt:railDirection", directionID)], op.endpoint, op.name)
    }

    func railDirections(endpoint: ODPTEndpoint) async throws -> [ODPTRailDirection] {
        try await get("odpt:RailDirection", [], endpoint, "方面")
    }

    func trainTypes(of op: TrainOperator) async throws -> [ODPTTrainType] {
        try await get("odpt:TrainType", [("odpt:operator", op.id)], op.endpoint, op.name)
    }

    func trainTimetables(railwayID: String, calendarID: String, directionID: String?, op: TrainOperator) async throws -> [ODPTTrainTimetable] {
        var query = [("odpt:railway", railwayID), ("odpt:calendar", calendarID)]
        if let directionID { query.append(("odpt:railDirection", directionID)) }
        return try await get("odpt:TrainTimetable", query, op.endpoint, op.name)
    }

    func trains(op: TrainOperator, railwayIDs: [String]) async throws -> [ODPTTrain] {
        try await getEach("odpt:Train", key: "odpt:railway", values: railwayIDs, op.endpoint, op.name)
    }

    func operators(endpoint: ODPTEndpoint) async throws -> [ODPTOperator] {
        try await get("odpt:Operator", [], endpoint, "事業者の一覧")
    }

    func railways(endpoint: ODPTEndpoint) async throws -> [ODPTRailway] {
        try await get("odpt:Railway", [], endpoint, "路線の一覧")
    }

    func trainInformation(operatorIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTTrainInformation] {
        try await getEach("odpt:TrainInformation", key: "odpt:operator", values: operatorIDs, endpoint, "運行情報")
    }

    func trains(operatorIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTTrain] {
        try await getEach("odpt:Train", key: "odpt:operator", values: operatorIDs, endpoint, "列車の情報")
    }

    func stationTimetables(ids: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStationTimetable] {
        try await getEach("odpt:StationTimetable", key: "owl:sameAs", values: ids, endpoint, "駅の時刻表")
    }

    func trainTimetables(trainIDs: [String], endpoint: ODPTEndpoint) async throws -> [ODPTTrainTimetable] {
        try await getEach("odpt:TrainTimetable", key: "odpt:train", values: trainIDs, endpoint, "列車の時刻表")
    }

    /// カンマ区切りの絞り込みを10件ずつに分けて問い合わせ、結果をつなぐ。値がなければ問い合わせない。
    private func getEach<T: Decodable>(_ type: String, key: String, values: [String], _ endpoint: ODPTEndpoint, _ name: String) async throws -> [T] {
        var result: [T] = []
        for chunk in ODPTQuery.chunks(values) {
            result += try await get(type, [(key, chunk.joined(separator: ","))], endpoint, name) as [T]
        }
        return result
    }

    private func get<T: Decodable>(_ type: String, _ query: [(String, String)], _ endpoint: ODPTEndpoint, _ name: String) async throws -> [T] {
        try Self.decode([T].self, from: try await getData(type, query, endpoint, name))
    }

    private func getData(_ type: String, _ query: [(String, String)], _ endpoint: ODPTEndpoint, _ name: String) async throws -> Data {
        let token = tokenProvider()
        if endpoint.requiresToken, (token ?? "").isEmpty { throw ODPTError.tokenRequired(name) }
        let url = Self.makeURL(type: type, query: query, endpoint: endpoint, token: token)
        let (data, status) = try await http.response(url)
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw ODPTError.unauthorized }
            throw ODPTError.requestFailed(name: name, status: status, body: Self.errorBody(data),
                                          url: Self.displayURL(type: type, query: query, endpoint: endpoint))
        }
        return data
    }

    /// エラーの応答の本文(先頭200文字、改行はつなぐ)
    static func errorBody(_ data: Data) -> String {
        let text = String(decoding: data.prefix(400), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(200))
    }

    /// 表示用のURL(トークンを含めない)
    static func displayURL(type: String, query: [(String, String)], endpoint: ODPTEndpoint) -> String {
        let url = makeURL(type: type, query: query, endpoint: endpoint, token: nil).absoluteString
        return url.removingPercentEncoding ?? url
    }

    static func makeURL(type: String, query: [(String, String)], endpoint: ODPTEndpoint, token: String?) -> URL {
        var c = URLComponents(url: endpoint.baseURL.appendingPathComponent(type), resolvingAgainstBaseURL: false)!
        var items = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        if endpoint.requiresToken, let token, !token.isEmpty {
            items.append(URLQueryItem(name: "acl:consumerKey", value: token))
        }
        c.queryItems = items.isEmpty ? nil : items
        return c.url!
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

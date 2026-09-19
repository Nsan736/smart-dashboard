import Foundation

enum ODPTError: LocalizedError, Equatable {
    case tokenRequired(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .tokenRequired(let name): return "\(name)の取得にはODPTのアクセストークンが必要です。設定で入力してください。"
        case .unauthorized: return "ODPTのアクセストークンが正しくないか、権限がありません。"
        }
    }
}

protocol ODPTAPI: Sendable {
    func railways(of op: TrainOperator) async throws -> [ODPTRailway]
    func stations(ofRailway railwayID: String, op: TrainOperator) async throws -> [ODPTStation]
    func stations(ids: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStation]
    /// 運行情報の応答を、デコードせずにそのまま返す(遅延時のサンプル収集にも使うため)
    func trainInformationData(op: TrainOperator, railwayIDs: [String]) async throws -> Data
    func stationTimetables(stationID: String, directionID: String, op: TrainOperator) async throws -> [ODPTStationTimetable]
    func railDirections(endpoint: ODPTEndpoint) async throws -> [ODPTRailDirection]
    func trainTypes(of op: TrainOperator) async throws -> [ODPTTrainType]
    /// 列車ごとの時刻表。1回の応答は1000件で打ち切られるので、カレンダー(と必要なら方面)で分けて取得する。
    func trainTimetables(railwayID: String, calendarID: String, directionID: String?, op: TrainOperator) async throws -> [ODPTTrainTimetable]
    /// 列車のリアルタイム情報。登録した路線だけに絞る(カンマ区切りでOR指定)。
    func trains(op: TrainOperator, railwayIDs: [String]) async throws -> [ODPTTrain]
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

    func stations(ids: [String], endpoint: ODPTEndpoint) async throws -> [ODPTStation] {
        guard !ids.isEmpty else { return [] }
        return try await get("odpt:Station", [("owl:sameAs", ids.joined(separator: ","))], endpoint, "駅名")
    }

    /// 登録した路線だけに絞って取得する(カンマ区切りでOR指定)
    func trainInformationData(op: TrainOperator, railwayIDs: [String]) async throws -> Data {
        guard !railwayIDs.isEmpty else { return Data("[]".utf8) }
        return try await getData("odpt:TrainInformation", [("odpt:railway", railwayIDs.joined(separator: ","))], op.endpoint, op.name)
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
        guard !railwayIDs.isEmpty else { return [] }
        return try await get("odpt:Train", [("odpt:railway", railwayIDs.joined(separator: ","))], op.endpoint, op.name)
    }

    private func get<T: Decodable>(_ type: String, _ query: [(String, String)], _ endpoint: ODPTEndpoint, _ name: String) async throws -> [T] {
        try Self.decode([T].self, from: try await getData(type, query, endpoint, name))
    }

    private func getData(_ type: String, _ query: [(String, String)], _ endpoint: ODPTEndpoint, _ name: String) async throws -> Data {
        let token = tokenProvider()
        if endpoint.requiresToken, (token ?? "").isEmpty { throw ODPTError.tokenRequired(name) }
        let url = Self.makeURL(type: type, query: query, endpoint: endpoint, token: token)
        do {
            return try await http.get(url)
        } catch HTTPError.badStatus(let code) where code == 401 || code == 403 {
            throw ODPTError.unauthorized
        }
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

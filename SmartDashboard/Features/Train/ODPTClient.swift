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
    func trainInformation(op: TrainOperator, railwayIDs: [String]) async throws -> [ODPTTrainInformation]
    func stationTimetables(stationID: String, directionID: String, op: TrainOperator) async throws -> [ODPTStationTimetable]
    func railDirections(endpoint: ODPTEndpoint) async throws -> [ODPTRailDirection]
    func trainTypes(of op: TrainOperator) async throws -> [ODPTTrainType]
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
    func trainInformation(op: TrainOperator, railwayIDs: [String]) async throws -> [ODPTTrainInformation] {
        guard !railwayIDs.isEmpty else { return [] }
        return try await get("odpt:TrainInformation", [("odpt:railway", railwayIDs.joined(separator: ","))], op.endpoint, op.name)
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

    private func get<T: Decodable>(_ type: String, _ query: [(String, String)], _ endpoint: ODPTEndpoint, _ name: String) async throws -> [T] {
        let token = tokenProvider()
        if endpoint.requiresToken, (token ?? "").isEmpty { throw ODPTError.tokenRequired(name) }
        let url = Self.makeURL(type: type, query: query, endpoint: endpoint, token: token)
        do {
            return try Self.decode([T].self, from: try await http.get(url))
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

import Foundation

/// Claude API の1回(または合計)の使用量。応答の usage から作る。
/// 思考のトークンは出力に含まれていて、出力の料金で計算される(thinking はその内訳)。
struct ClaudeUsage: Codable, Equatable, Sendable {
    /// キャッシュの読み書きでない入力(input_tokens)
    var input = 0
    /// 出力(output_tokens。思考を含む)
    var output = 0
    /// キャッシュの書き込み(cache_creation_input_tokens)
    var cacheWrite = 0
    /// キャッシュの読み込み(cache_read_input_tokens)
    var cacheRead = 0
    /// 出力のうち思考に使った分(output_tokens_details.thinking_tokens)
    var thinking = 0

    /// 入力の合計(キャッシュの読み書きを含む)
    var totalInput: Int { input + cacheWrite + cacheRead }
    var total: Int { totalInput + output }

    static func + (a: ClaudeUsage, b: ClaudeUsage) -> ClaudeUsage {
        ClaudeUsage(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
                    cacheRead: a.cacheRead + b.cacheRead, thinking: a.thinking + b.thinking)
    }

    static func += (a: inout ClaudeUsage, b: ClaudeUsage) { a = a + b }

    /// 「入力 1,234(キャッシュ読込 1,100・書込 0)・出力 456(うち思考 300)」
    var summary: String {
        var text = "入力 \(Self.number(totalInput))"
        if cacheRead > 0 || cacheWrite > 0 {
            text += "(キャッシュ読込 \(Self.number(cacheRead))・書込 \(Self.number(cacheWrite)))"
        }
        text += "・出力 \(Self.number(output))"
        if thinking > 0 { text += "(うち思考 \(Self.number(thinking)))" }
        return text
    }

    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// 100万トークンあたりの料金(ドル)。初期値は Claude Haiku 5.5(プロンプトが10万トークン以下のとき)。
struct ClaudePricing: Codable, Equatable, Sendable {
    var input = 0.10
    var output = 0.50
    /// キャッシュの書き込み(5分)
    var cacheWrite = 0.125
    /// キャッシュの読み込み
    var cacheRead = 0.01

    /// おおよその金額(ドル)。思考は出力に含まれているので、出力の料金で数える。
    func cost(_ usage: ClaudeUsage) -> Double {
        (Double(usage.input) * input + Double(usage.output) * output
            + Double(usage.cacheWrite) * cacheWrite + Double(usage.cacheRead) * cacheRead) / 1_000_000
    }

    /// 「約0.0012ドル」
    static func text(_ dollars: Double) -> String {
        if dollars == 0 { return "0ドル" }
        if dollars < 0.0001 { return "0.0001ドル未満" }
        if dollars < 0.01 { return "約" + String(format: "%.4f", dollars) + "ドル" }
        return "約" + String(format: "%.2f", dollars) + "ドル"
    }
}

/// メッセージの中身
enum ClaudeContent: Equatable, Sendable {
    /// cached: ここまでをプロンプトキャッシュに入れる(cache_control の目印)
    case text(String, cached: Bool = false)
    case jpeg(Data)
}

struct ClaudeMessage: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    var role: Role
    var content: [ClaudeContent]

    static func user(_ text: String) -> ClaudeMessage { ClaudeMessage(role: .user, content: [.text(text)]) }
    static func assistant(_ text: String) -> ClaudeMessage { ClaudeMessage(role: .assistant, content: [.text(text)]) }
}

/// Messages API(POST /v1/messages)の1回分の依頼
struct ClaudeRequest: Equatable, Sendable {
    var model: String
    var system: String
    /// system prompt をプロンプトキャッシュに入れる(毎回同じ長い説明のとき)
    var cachesSystem = false
    var messages: [ClaudeMessage]
    var maxTokens: Int
    /// true: 適応的思考(thinking.type = adaptive)。false: 思考なし(thinking.type = disabled)。
    var thinking: Bool
    /// 応答を待つ時間(秒)。ストリーミングを使わないので、出力が終わるまで何も届かない。
    var timeout: TimeInterval = HTTPClaudeClient.timeout

    /// 送る JSON。思考の文章は画面に出さないので、display は指定しない(初期値の omitted)。
    var jsonObject: [String: Any] {
        var systemBlock: [String: Any] = ["type": "text", "text": system]
        if cachesSystem { systemBlock["cache_control"] = ["type": "ephemeral"] }
        let messageObjects: [[String: Any]] = messages.map { message in
            let blocks: [[String: Any]] = message.content.map { content in
                switch content {
                case .text(let text, let cached):
                    var block: [String: Any] = ["type": "text", "text": text]
                    if cached { block["cache_control"] = ["type": "ephemeral"] }
                    return block
                case .jpeg(let data):
                    return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
                }
            }
            return ["role": message.role.rawValue, "content": blocks]
        }
        return [
            "model": model,
            "max_tokens": maxTokens,
            "system": [systemBlock],
            "messages": messageObjects,
            "thinking": ["type": thinking ? "adaptive" : "disabled"],
        ]
    }

    func body() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject)
    }
}

/// 応答。文章(text の部分をつなげたもの)と使用量。思考の部分(thinking)は使わない。
struct ClaudeResponse: Equatable, Sendable {
    var text: String
    var usage: ClaudeUsage
    var stopReason: String?
    var model: String?

    static func parse(_ data: Data) throws -> ClaudeResponse {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClaudeError.invalidResponse }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
        let blocks = root["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        let usageObject = root["usage"] as? [String: Any] ?? [:]
        let details = usageObject["output_tokens_details"] as? [String: Any] ?? [:]
        let usage = ClaudeUsage(input: int(usageObject["input_tokens"]), output: int(usageObject["output_tokens"]),
                                cacheWrite: int(usageObject["cache_creation_input_tokens"]),
                                cacheRead: int(usageObject["cache_read_input_tokens"]),
                                thinking: int(details["thinking_tokens"]))
        return ClaudeResponse(text: text, usage: usage, stopReason: root["stop_reason"] as? String, model: root["model"] as? String)
    }
}

/// 呼び出しの失敗。どれも画面に理由を出して、ほかの機能には影響させない。
enum ClaudeError: LocalizedError, Equatable {
    case missingKey
    case overBudget(spent: Double, limit: Double)
    case offline
    case unauthorized
    case forbidden(String)
    case badRequest(String)
    case billing(String)
    case rateLimited(String)
    case overloaded
    case server(Int, String)
    case network(String)
    case invalidResponse
    case refused
    case emptyAnswer(stopReason: String?)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Claude の APIキーが設定されていません。設定の「Claude API」で入力してください。"
        case .overBudget(let spent, let limit):
            return "今月の使用額(\(ClaudePricing.text(spent)))が上限(\(String(format: "%.2f", limit))ドル)に達したため、呼び出しを止めています。設定の「Claude API」で上限を変えられます。"
        case .offline:
            return "オフラインのため、Claude に送れません。"
        case .unauthorized:
            return "APIキーが無効です(HTTP 401)。設定の「Claude API」でキーを確かめてください。"
        case .forbidden(let message):
            return "このAPIキーでは使えません(HTTP 403)。" + message
        case .badRequest(let message):
            return "依頼の内容が受け付けられませんでした(HTTP 400)。" + message
        case .billing(let message):
            return "支払いの設定に問題があります(HTTP 402)。" + message
        case .rateLimited(let message):
            return "呼び出しの回数や利用額の上限に達しました(HTTP 429)。少し待ってからもう一度試してください。" + message
        case .overloaded:
            return "Claude が混み合っています(HTTP 529)。少し待ってからもう一度試してください。"
        case .server(let status, let message):
            return "Claude の側でエラーが起きました(HTTP \(status))。" + message
        case .network(let message):
            return "通信に失敗しました: " + message
        case .invalidResponse:
            return "応答を読めませんでした。"
        case .refused:
            return "この内容には答えられないとの応答でした。"
        case .emptyAnswer(let stopReason):
            return stopReason == "max_tokens" ? "答えが長すぎて途中で止まりました。" : "答えが空でした。"
        }
    }

    /// 200番台でない応答から。本文は {"type":"error","error":{"type":...,"message":...}}。
    static func from(status: Int, data: Data) -> ClaudeError {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let message = (error?["message"] as? String).map { "(\($0))" } ?? ""
        switch status {
        case 400, 413: return .badRequest(message)
        case 401: return .unauthorized
        case 402: return .billing(message)
        case 403: return .forbidden(message)
        case 429: return .rateLimited(message)
        case 529: return .overloaded
        default: return .server(status, message)
        }
    }
}

/// Claude API を呼ぶ部分。テストでは決まった応答を返すものに差し替える。
protocol ClaudeClient: Sendable {
    func send(_ request: ClaudeRequest, apiKey: String) async throws -> ClaudeResponse
}

/// 本番の呼び出し。通信は HTTPClient(MeteredHTTPClient)を通すので、通信量の記録に入る。
struct HTTPClaudeClient: ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2023-06-01"
    /// 思考に時間がかかることがあるので、待つ時間を長めにする
    static let timeout: TimeInterval = 180

    let http: HTTPClient

    static func urlRequest(_ request: ClaudeRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(version, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = try request.body()
        return urlRequest
    }

    func send(_ request: ClaudeRequest, apiKey: String) async throws -> ClaudeResponse {
        let urlRequest = try Self.urlRequest(request, apiKey: apiKey)
        let result: (data: Data, status: Int)
        do {
            result = try await http.send(urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw ClaudeError.offline
        } catch {
            throw ClaudeError.network(error.localizedDescription)
        }
        return try Self.decode(data: result.data, status: result.status)
    }

    static func decode(data: Data, status: Int) throws -> ClaudeResponse {
        guard (200..<300).contains(status) else { throw ClaudeError.from(status: status, data: data) }
        let response = try ClaudeResponse.parse(data)
        if response.stopReason == "refusal" { throw ClaudeError.refused }
        return response
    }
}

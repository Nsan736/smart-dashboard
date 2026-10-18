import Foundation

/// ストリーミング(stream: true)で受け取っている間の出来事(進み具合の表示に使う)
enum ClaudeStreamEvent: Equatable, Sendable {
    /// 応答が始まった
    case started
    /// 考えている(思考のブロック)
    case thinking
    /// Web 検索を始めた(何回目か、検索の言葉が分かれば)
    case searching(count: Int, query: String?)
    /// 検索の結果を受け取った
    case searched(count: Int)
    /// 文章を受け取っている(これまでの文字数と、JSON の "kind" の数=受け取った形の数)
    case writing(characters: Int, shapes: Int)
}

/// サーバーから届く SSE の data の行(JSON)を順に読み、ClaudeResponse にまとめる。純粋なロジックとしてテストする。
/// pause_turn の続きで送り返すため、内容のブロック(文章・思考・検索の呼び出しと結果)を組み立て直して rawContent に入れる。
struct ClaudeStreamAccumulator {
    private struct Block {
        var object: [String: Any]
        var text = ""
        var thinking = ""
        var signature = ""
        var partialJSON = ""
        var citations: [[String: Any]] = []
    }

    private var blocks: [Int: Block] = [:]
    private var order: [Int] = []
    private var usageStart: [String: Any] = [:]
    private var usageEnd: [String: Any] = [:]
    private(set) var stopReason: String?
    private(set) var model: String?
    private(set) var searchCount = 0
    private(set) var textLength = 0
    /// 文章の中の "kind" の数(オブジェクトの形の数の目安)。区切りをまたいでも数えられるよう、最後の数文字を持つ
    private(set) var kindCount = 0
    private var tail = ""
    static let kindToken = "\"kind\""
    private(set) var error: ClaudeError?

    /// data の行(先頭の "data: " を除いたもの)を1つ読む。進み具合が変わったら返す
    mutating func consume(_ json: String) -> ClaudeStreamEvent? {
        guard let data = json.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        switch type {
        case "message_start":
            let message = event["message"] as? [String: Any] ?? [:]
            model = message["model"] as? String
            usageStart = message["usage"] as? [String: Any] ?? [:]
            return .started
        case "content_block_start":
            guard let index = (event["index"] as? NSNumber)?.intValue, let block = event["content_block"] as? [String: Any] else { return nil }
            blocks[index] = Block(object: block)
            order.append(index)
            switch block["type"] as? String {
            case "thinking", "redacted_thinking": return .thinking
            case "server_tool_use":
                searchCount += 1
                return .searching(count: searchCount, query: nil)
            case "web_search_tool_result": return .searched(count: searchCount)
            default: return nil
            }
        case "content_block_delta":
            guard let index = (event["index"] as? NSNumber)?.intValue, var block = blocks[index],
                  let delta = event["delta"] as? [String: Any] else { return nil }
            var result: ClaudeStreamEvent?
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                block.text += text
                textLength += text.count
                let joined = tail + text
                kindCount += joined.components(separatedBy: Self.kindToken).count - 1
                tail = String(joined.suffix(Self.kindToken.count - 1))
                result = .writing(characters: textLength, shapes: kindCount)
            case "thinking_delta":
                block.thinking += delta["thinking"] as? String ?? ""
            case "signature_delta":
                block.signature += delta["signature"] as? String ?? ""
            case "input_json_delta":
                block.partialJSON += delta["partial_json"] as? String ?? ""
                if let query = Self.query(block.partialJSON) { result = .searching(count: searchCount, query: query) }
            case "citations_delta":
                if let citation = delta["citation"] as? [String: Any] { block.citations.append(citation) }
            default:
                break
            }
            blocks[index] = block
            return result
        case "message_delta":
            let delta = event["delta"] as? [String: Any] ?? [:]
            if let reason = delta["stop_reason"] as? String { stopReason = reason }
            usageEnd = event["usage"] as? [String: Any] ?? usageEnd
            return nil
        case "error":
            let body = (try? JSONSerialization.data(withJSONObject: ["error": event["error"] ?? [:]])) ?? Data()
            let errorType = (event["error"] as? [String: Any])?["type"] as? String
            error = errorType == "overloaded_error" ? .overloaded : ClaudeError.from(status: 500, data: body)
            return nil
        default:
            return nil
        }
    }

    /// 検索の言葉(入力の JSON が読めるところまで来ていれば)
    static func query(_ partialJSON: String) -> String? {
        guard let data = partialJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["query"] as? String
    }

    /// 受け取り終わった応答(返事の形は、ストリーミングでないときと同じ)
    func response() throws -> ClaudeResponse {
        if let error { throw error }
        var content: [[String: Any]] = []
        for index in order {
            guard let block = blocks[index] else { continue }
            var object = block.object
            switch object["type"] as? String {
            case "text":
                object["text"] = block.text
                if !block.citations.isEmpty { object["citations"] = block.citations }
            case "thinking":
                object["thinking"] = block.thinking
                object["signature"] = block.signature
            case "server_tool_use":
                if !block.partialJSON.isEmpty,
                   let input = (try? JSONSerialization.jsonObject(with: Data(block.partialJSON.utf8))) as? [String: Any] {
                    object["input"] = input
                }
            default:
                break
            }
            content.append(object)
        }
        // 使用量は、最初(message_start)の値に、最後(message_delta)の値を重ねる(最後の値は累計)
        var usage = usageStart
        for (key, value) in usageEnd { usage[key] = value }
        var root: [String: Any] = ["content": content, "usage": usage]
        if let stopReason { root["stop_reason"] = stopReason }
        if let model { root["model"] = model }
        let data = try JSONSerialization.data(withJSONObject: root)
        let response = try ClaudeResponse.parse(data)
        if response.stopReason == "refusal" { throw ClaudeError.refused }
        return response
    }
}

extension HTTPClaudeClient {
    /// ストリーミングで呼ぶ。進み具合を onEvent で知らせ、最後にまとめた応答を返す
    func stream(_ request: ClaudeRequest, apiKey: String, onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ClaudeResponse {
        var urlRequest = try Self.urlRequest(request, apiKey: apiKey)
        var object = request.jsonObject
        object["stream"] = true
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: object)
        let box = AccumulatorBox()
        let result: (status: Int, errorBody: Data)
        do {
            result = try await http.stream(urlRequest) { line in
                guard line.hasPrefix("data:") else { return }
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let event = box.consume(json) { onEvent(event) }
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw ClaudeError.offline
        } catch {
            throw ClaudeError.network(error.localizedDescription)
        }
        guard (200..<300).contains(result.status) else { throw ClaudeError.from(status: result.status, data: result.errorBody) }
        return try box.response()
    }

    /// 行を受け取るスレッドからも使えるように、鍵をかけて持つ
    private final class AccumulatorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var accumulator = ClaudeStreamAccumulator()

        func consume(_ json: String) -> ClaudeStreamEvent? {
            lock.withLock { accumulator.consume(json) }
        }

        func response() throws -> ClaudeResponse {
            try lock.withLock { try accumulator.response() }
        }
    }
}

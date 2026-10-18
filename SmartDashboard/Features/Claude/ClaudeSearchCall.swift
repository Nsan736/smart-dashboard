import Foundation

/// Web 検索を付けて Claude を呼ぶ共通の流れ(「撮って聞く」とオブジェクトの作成で使う)。
/// - pause_turn(検索の途中で区切られた)なら、受け取った内容のブロックをそのまま assistant として送り返し、続きを頼む(上限 maxContinuations 回)
/// - Web 検索を付けた依頼が HTTP 400 になったら(このモデルや組織で使えないなど)、検索を外して1回だけ呼び直し、searchFallback を立てる
enum ClaudeSearchCall {
    struct Result: Equatable {
        var response: ClaudeResponse
        var cost: Double
        var searchFallback = false
    }

    /// withoutSearch: 検索を外して呼び直すときに、依頼を直す(system prompt を検索なしの文にする、など)。webSearchMaxUses は外してから渡す。
    static func run(_ request: ClaudeRequest, maxContinuations: Int = 3, withoutSearch: (ClaudeRequest) -> ClaudeRequest = { $0 },
                    call: (ClaudeRequest) async throws -> ClaudeCallResult) async throws -> Result {
        do {
            return try await continueTurns(request, maxContinuations: maxContinuations, call: call)
        } catch let error as ClaudeError {
            guard case .badRequest = error, request.webSearchMaxUses != nil else { throw error }
            var plain = request
            plain.webSearchMaxUses = nil
            plain = withoutSearch(plain)
            var result = try await continueTurns(plain, maxContinuations: maxContinuations, call: call)
            result.searchFallback = true
            return result
        }
    }

    static func continueTurns(_ request: ClaudeRequest, maxContinuations: Int,
                              call: (ClaudeRequest) async throws -> ClaudeCallResult) async throws -> Result {
        var current = request
        let first = try await call(current)
        var response = first.response
        var cost = first.cost
        var last = first.response
        var continuations = 0
        while last.stopReason == "pause_turn", continuations < maxContinuations {
            continuations += 1
            current.messages.append(ClaudeMessage(role: .assistant, content: last.rawContent.map { .raw($0) }))
            let next = try await call(current)
            response = response.appending(next.response)
            cost += next.cost
            last = next.response
        }
        return Result(response: response, cost: cost)
    }
}

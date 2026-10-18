import Foundation

/// 小ツールの JSON を、文章から Claude に作ってもらう(新しく作る・今のツールを直す)。
/// 返ってきた JSON は既存の検証(CustomToolParser)にかけ、誤りがあれば、誤りを添えて1回だけ作り直しを頼む。
struct ToolGeneration: Equatable {
    enum Outcome: Equatable {
        /// 検証を通った(確認の画面に渡す)
        case valid(json: String, tool: CustomTool)
        /// 2回とも誤りがあった
        case invalid(json: String, issues: [ToolIssue])
    }

    var outcome: Outcome
    /// 作り直しを含めた合計
    var usage: ClaudeUsage
    var cost: Double
    /// 呼び出した回数(1か2)
    var attempts: Int
}

enum ToolGenerator {
    /// スクリプト型は長くなりやすいので、出力の上限を大きくとる(思考を含む)
    static let maxTokens = 32_000
    /// 出力が長いと時間がかかるので、待つ時間も長くする
    static let timeout: TimeInterval = 360
    /// 依頼文の長さの上限(文字)
    static let maxInstruction = 2_000

    /// 形式の説明(docs/tools-format.md と同じものをアプリに同梱。check_local.py で一致を確かめる)
    static let formatDocument: String = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "tools-format", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    private final class BundleToken {}

    /// system prompt。毎回同じなので、プロンプトキャッシュに入れる。
    static func systemPrompt(format: String) -> String {
        """
        あなたは、iOS アプリ「スマートダッシュボード」の小ツールを作る係です。利用者の依頼に合う小ツールを、下の形式の説明に厳密に従った JSON で作ります。

        守ること:
        - 返すのは JSON だけです。説明の文章、前置き、コードブロックの記号(```)は付けないでください。
        - 形式の説明にない項目は使わないでください。型は calc / list / table / checklist / script のどれかです。
        - 計算・選ぶ・表・チェックで足りるときは、その型を使ってください。動き・描画・タップへの反応・ゲーム・模様の生成などが必要なときだけ script を使ってください。
        - script では、形式の説明にある API だけを使ってください(fetch、XMLHttpRequest、setTimeout、document、window、require などは使えません)。毎コマ全体を描き直し、iPhone SE(第2世代)でも軽く動くように、1コマの描画の命令や計算を少なめにしてください。script の文字列の中の改行や引用符は、JSON として正しくエスケープしてください。
        - script でアプリのデータ(app.weather など)を使うときは、使う種類だけを permissions に書いてください。使わない種類は書かないでください。location.precise と sensors は、居場所が分かる・センサーを動かすので、依頼にどうしても必要なときだけにしてください。おおよその地域で足りるときは location.coarse にしてください。
        - アプリのデータは、許可されていない・まだ取得していないときに null になります。null のときにも、エラーにならずに、分かりやすい表示をしてください。データは setup と onData(kind) で変数に入れて使い、毎コマ app.* を読まないでください。センサーは app.sensors.start で使い始め、onStop で止めてください。
        - format は 1 にしてください。id は形式の説明にある文字(半角の英数字と . _ -)だけで、内容に合う名前にしてください。
        - 名前・説明・ラベル・項目は日本語にしてください。
        - 計算式は、説明にある演算子と関数だけを使い、入力欄の id を正しく参照してください。
        - 依頼があいまいなときは、よく使われる妥当な内容で補ってください。
        - 今の JSON を直す依頼のときは、頼まれたところだけを直し、ほかの部分(id を含む)はそのまま残してください。

        形式の説明:
        \(format)
        """
    }

    /// 新しく作る依頼
    static func createMessages(description: String) -> [ClaudeMessage] {
        [.user("次の小ツールを作ってください。\n\n" + String(description.prefix(maxInstruction)))]
    }

    /// 今のツールを直す依頼(今の JSON と依頼文を送る)
    static func reviseMessages(currentJSON: String, instruction: String) -> [ClaudeMessage] {
        [.user("今の小ツールの JSON:\n" + currentJSON + "\n\nこの小ツールを、次のように直してください。直したあとの JSON 全体を返してください。\n\n"
               + String(instruction.prefix(maxInstruction)))]
    }

    /// 検証の誤りを添えて、作り直しを頼む文
    static func retryMessage(issues: [ToolIssue]) -> String {
        let lines = issues.prefix(20).map { "- \($0.path): \($0.message)" }.joined(separator: "\n")
        return "この JSON には、次の誤りがありました。誤りを直した JSON 全体を、JSON だけで返してください。\n\n" + lines
    }

    /// 応答の文章から JSON の部分を取り出す(コードブロックの記号や前後の文章が付いていても読めるように)
    static func extractJSON(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = body.range(of: "```") {
            let afterFence = body[fenceStart.upperBound...]
            // 「```json」の言語名を飛ばす
            let contentStart = afterFence.firstIndex(of: "\n").map { afterFence.index(after: $0) } ?? afterFence.startIndex
            if let fenceEnd = body[contentStart...].range(of: "```") {
                body = String(body[contentStart..<fenceEnd.lowerBound])
            }
        }
        if let first = body.firstIndex(of: "{"), let last = body.lastIndex(of: "}"), first < last {
            return String(body[first...last])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func request(messages: [ClaudeMessage], model: String, thinking: Bool, format: String) -> ClaudeRequest {
        ClaudeRequest(model: model, system: systemPrompt(format: format), cachesSystem: true, messages: messages,
                      maxTokens: maxTokens, thinking: thinking, timeout: timeout)
    }

    /// 作る(直す)流れ。call は Claude を呼ぶ部分(本番は ClaudeService.call、テストでは決まった応答)。
    /// validate: 形式の検証を通ったあとの確かめ(スクリプト型は、構文と、試しに動かしたときのエラー)。問題がなければ空。
    static func run(messages first: [ClaudeMessage], model: String, thinking: Bool, format: String,
                    validate: (CustomTool) async -> [ToolIssue] = { _ in [] },
                    call: (ClaudeRequest) async throws -> ClaudeCallResult) async throws -> ToolGeneration {
        var messages = first
        var usage = ClaudeUsage()
        var cost = 0.0
        var attempts = 0
        var lastJSON = ""
        var lastIssues: [ToolIssue] = []
        while attempts < 2 {
            let result = try await call(request(messages: messages, model: model, thinking: thinking, format: format))
            attempts += 1
            usage += result.response.usage
            cost += result.cost
            let answer = result.response.text
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClaudeError.emptyAnswer(stopReason: result.response.stopReason)
            }
            lastJSON = extractJSON(answer)
            let issues: [ToolIssue]
            switch CustomToolParser.parse(lastJSON) {
            case .success(let tool):
                let problems = await validate(tool)
                guard !problems.isEmpty else {
                    return ToolGeneration(outcome: .valid(json: lastJSON, tool: tool), usage: usage, cost: cost, attempts: attempts)
                }
                issues = problems
            case .failure(let found):
                issues = found
            }
            lastIssues = issues
            // 誤りを添えて、もう1回だけ頼む(思考の部分は送り返さない。ツールを使わない会話では不要)
            messages.append(.assistant(answer))
            messages.append(.user(retryMessage(issues: issues)))
        }
        return ToolGeneration(outcome: .invalid(json: lastJSON, issues: lastIssues), usage: usage, cost: cost, attempts: attempts)
    }
}

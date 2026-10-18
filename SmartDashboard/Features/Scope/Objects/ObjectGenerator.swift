import SwiftUI

/// 文章からオブジェクトの JSON を Claude に作ってもらう。返ってきた JSON は ObjectCodec で検証し、誤りがあれば1回だけ作り直しを頼む。
enum ObjectGenerator {
    static let maxTokens = 8_000
    static let timeout: TimeInterval = 180
    static let maxInstruction = 1_000

    struct Outcome {
        var object: ScopeObject?
        var json: String
        var issues: [ToolIssue]
        var usage: ClaudeUsage
        var cost: Double
        var attempts: Int
    }

    /// system prompt(毎回同じなので、プロンプトキャッシュに入れる)
    static let systemPrompt = """
    あなたは、iOS アプリ「スマートダッシュボード」のスコープに置く、簡単な3Dのオブジェクトを作る係です。利用者の依頼に合うオブジェクトを、下の形式の JSON だけで返します。説明の文章やコードブロックの記号(```)は付けないでください。

    形式:
    {"format": 1, "type": "scope-object", "name": "名前(日本語、40文字まで)", "shapes": [形, ...]}
    形: {"kind": 種類, "width": 幅, "depth": 奥行き, "height": 高さ, "x": 左右, "y": 前後, "z": 上下, "yaw": 向き, "pitch": 前後の傾き, "roll": 左右の傾き, "color": "#RRGGBB", "opacity": 不透明度}
    - kind: "box"(箱)、"cylinder"(円柱)、"cone"(円錐、頂点が上)、"sphere"(球。幅・奥行き・高さが違えば楕円体)、"pyramid"(四角錐、頂点が上)、"plane"(縦の板。幅×高さで、正面が前。奥行きは使わない)
    - 大きさ(width・depth・height)は m(0.01〜2000)。x は右が正、y は前が正、z は上が正で、形の底面の中心の位置(m、−2000〜2000)。地面は z = 0
    - 回転は度。yaw は上から見て時計回り、pitch は前が上がる向き、roll は右が下がる向き。形の中心のまわりに、roll → pitch → yaw の順に回す
    - color は "#RRGGBB"。opacity は 0.05〜1(依頼に指定がなければ 0.4 の半透明)。色の指定がなければ赤 "#FF0000"
    - 形は64個まで。iPhone SE でも軽く描けるように、必要な形だけを少なめに使ってください(多くても20個程度)
    - 実際の大きさに近くしてください(例: 2階建ての家は高さ7m前後、電柱は高さ12m前後)。依頼に数値があれば、それに合わせてください
    """

    static func messages(description: String) -> [ClaudeMessage] {
        [.user("次のオブジェクトを作ってください。\n\n" + String(description.prefix(maxInstruction)))]
    }

    static func request(messages: [ClaudeMessage], model: String, thinking: Bool) -> ClaudeRequest {
        ClaudeRequest(model: model, system: systemPrompt, cachesSystem: true, messages: messages,
                      maxTokens: maxTokens, thinking: thinking, timeout: timeout)
    }

    /// 作る流れ。call は Claude を呼ぶ部分(本番は ClaudeService.call、テストでは決まった応答)
    static func run(description: String, model: String, thinking: Bool,
                    call: (ClaudeRequest) async throws -> ClaudeCallResult) async throws -> Outcome {
        var messages = messages(description: description)
        var outcome = Outcome(object: nil, json: "", issues: [], usage: ClaudeUsage(), cost: 0, attempts: 0)
        while outcome.attempts < 2 {
            let result = try await call(request(messages: messages, model: model, thinking: thinking))
            outcome.attempts += 1
            outcome.usage += result.response.usage
            outcome.cost += result.cost
            let answer = result.response.text
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClaudeError.emptyAnswer(stopReason: result.response.stopReason)
            }
            outcome.json = ToolGenerator.extractJSON(answer)
            switch ObjectCodec.parse(outcome.json) {
            case .success(let object):
                outcome.object = object
                outcome.issues = []
                return outcome
            case .failure(let issues):
                outcome.issues = issues
                messages.append(.assistant(answer))
                messages.append(.user(ToolGenerator.retryMessage(issues: issues)))
            }
        }
        return outcome
    }
}

/// 文章からオブジェクトを作る画面。できたものはプレビューで確かめてから保存する
struct ObjectComposeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""
    @State private var task: Task<Void, Never>?
    @State private var outcome: ObjectGenerator.Outcome?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $instruction)
                        .frame(minHeight: 110)
                        .disabled(task != nil)
                } header: {
                    Text("作りたいオブジェクト")
                } footer: {
                    Text("例: 「高さ30mの赤い塔」「2階建ての家」「青い半透明の球(直径10m)」。この文を Claude に送ります。")
                }
                Section {
                    if task != nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("考え中…").foregroundStyle(.secondary)
                            Spacer()
                            Button("取り消し", role: .cancel) { task?.cancel() }.buttonStyle(.bordered)
                        }
                    } else {
                        Button("作ってもらう") { start() }
                            .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let reason = env.claude.blockReason {
                        Label(reason.localizedDescription, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                }
                if let outcome {
                    if let object = outcome.object {
                        ObjectConfirmSection(object: object)
                        Section {
                            Button("保存する") {
                                env.objects.save(object)
                                dismiss()
                            }
                        } footer: {
                            Text("呼び出し\(outcome.attempts)回: " + outcome.usage.summary + "・" + ClaudePricing.text(outcome.cost))
                        }
                    } else {
                        Section("形式の誤りが残りました(\(outcome.issues.count)件)") {
                            ForEach(outcome.issues.prefix(10)) { issue in
                                Text("\(issue.path): \(issue.message)").font(.footnote).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .keyboardDismissable()
            .navigationTitle("文章から作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private func start() {
        guard task == nil else { return }
        errorText = nil
        outcome = nil
        if let reason = env.claude.blockReason {
            errorText = reason.localizedDescription
            return
        }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = env.settings.claude
        let service = env.claude
        task = Task {
            do {
                outcome = try await ObjectGenerator.run(description: text, model: settings.model, thinking: settings.thinkingForTools) { request in
                    try await service.call(request)
                }
            } catch is CancellationError {
                errorText = "取り消しました"
            } catch {
                errorText = error.localizedDescription
            }
            task = nil
        }
    }
}

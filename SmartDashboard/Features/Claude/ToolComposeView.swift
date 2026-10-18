import SwiftUI

/// 小ツールを文章から作る・文章で直す。できた JSON は、保存する前に既存の確認の画面(ToolImportView)で見てもらう。
struct ToolComposeView: View {
    enum Mode {
        case create
        /// 今のツールを直す(今の JSON と、もとのツールの ID)
        case revise(json: String, id: String)
    }

    /// 確認の画面に渡す JSON
    private struct Draft: Identifiable {
        let id = UUID()
        var json: String
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var instruction = ""
    @State private var task: Task<Void, Never>?
    @State private var generation: ToolGeneration?
    @State private var errorText: String?
    @State private var draft: Draft?

    private var isWorking: Bool { task != nil }

    private var isRevising: Bool {
        if case .revise = mode { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $instruction)
                        .frame(minHeight: 140)
                        .disabled(isWorking)
                } header: {
                    Text(isRevising ? "どう直すか" : "作りたいツール")
                } footer: {
                    Text(isRevising
                         ? "例: 「入力欄に燃料の単価を足して、1kmあたりの費用も出して」。今の JSON と、この文を Claude に送ります。"
                         : "例: 「車の燃費と、1kmあたりのガソリン代を計算するツール」「今日の夕飯を決めるルーレット(和食・中華・洋食・麺類)」「出てくる的をタップするゲーム」。動きや描画が必要なものは、スクリプト型(JavaScript)で作ります。この文を Claude に送ります。")
                }
                Section {
                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("考え中…").foregroundStyle(.secondary)
                            Spacer()
                            Button("取り消し", role: .cancel) { task?.cancel() }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Button(isRevising ? "直してもらう" : "作ってもらう") { start() }
                            .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let reason = env.claude.blockReason {
                        Label(reason.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text("Claude(\(env.settings.claude.model)、思考\(env.settings.claude.thinkingForTools ? "あり" : "なし"))が、小ツールの形式に沿った JSON を作ります。返ってきた JSON はアプリで検証し(スクリプト型は、構文と、試しに数秒動かしたときのエラーも)、誤りがあれば誤りを添えて1回だけ作り直してもらいます。スクリプト型は長くなるので、数分かかることがあります。保存する前に、内容を確認する画面が出ます。")
                }
                if let generation { resultSections(generation) }
            }
            .keyboardDismissable()
            .navigationTitle(isRevising ? "文章で直す" : "文章から作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .sheet(item: $draft, onDismiss: closeIfSaved) { draft in
                ToolImportView(json: draft.json, editingID: editingID)
            }
            .onDisappear { task?.cancel() }
        }
    }

    private var editingID: String? {
        if case .revise(_, let id) = mode { return id }
        return nil
    }

    @ViewBuilder
    private func resultSections(_ generation: ToolGeneration) -> some View {
        Section {
            switch generation.outcome {
            case .valid(let json, let tool):
                Label("「\(tool.name)」ができました(\(tool.kind.label))", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Button("内容を確認して保存する") { draft = Draft(json: json) }
            case .invalid(let json, let issues):
                Label("2回作ってもらいましたが、形式の誤りが残りました(\(issues.count)件)", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(issues.prefix(10)) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(issue.message).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("JSONを開いて手で直す") { draft = Draft(json: json) }
            }
        } header: {
            Text("結果")
        } footer: {
            Text("呼び出し\(generation.attempts)回: " + generation.usage.summary + "・" + ClaudePricing.text(generation.cost))
        }
    }

    private func start() {
        guard !isWorking else { return }
        errorText = nil
        generation = nil
        if let reason = env.claude.blockReason {
            errorText = reason.localizedDescription
            return
        }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let messages: [ClaudeMessage]
        switch mode {
        case .create: messages = ToolGenerator.createMessages(description: text)
        case .revise(let json, _): messages = ToolGenerator.reviseMessages(currentJSON: json, instruction: text)
        }
        let settings = env.settings.claude
        let service = env.claude
        task = Task {
            do {
                // スクリプト型は、構文と、試しに数秒動かしたときのエラーも確かめる
                generation = try await ToolGenerator.run(messages: messages, model: settings.model, thinking: settings.thinkingForTools,
                                                         format: ToolGenerator.formatDocument,
                                                         validate: { await ScriptTrial.issues(for: $0) }) { request in
                    try await service.call(request)
                }
            } catch is CancellationError {
                errorText = "取り消しました(Claude 側で処理が進んでいた分は、料金がかかることがあります)"
            } catch {
                errorText = error.localizedDescription
            }
            task = nil
        }
    }

    /// 確認の画面で保存したら、この画面も閉じる
    private func closeIfSaved() {
        guard let generation, case .valid(let json, let tool) = generation.outcome else { return }
        if env.tools.customSources[tool.id] == json { dismiss() }
    }
}

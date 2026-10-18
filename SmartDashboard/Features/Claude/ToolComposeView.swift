import SwiftUI

/// 小ツールを文章から作る・文章で直す。できた JSON は、保存する前に既存の確認の画面(ToolImportView)で見てもらう。
/// 作る作業は `ToolComposeJob`(アプリ全体で1つ)が持つので、閉じても作るのは続き、結果は「最近作ったもの」に残る
struct ToolComposeView: View {
    typealias Mode = ToolComposeMode

    /// 確認の画面に渡す JSON
    private struct Draft: Identifiable {
        let id = UUID()
        var json: String
        var editingID: String?
        var recordID: UUID
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// nil なら、今の作業のまま(帯から開いたとき)
    let mode: Mode?
    @State private var draft: Draft?
    @State private var recordToDelete: ToolComposeRecord?

    init(mode: Mode? = nil) {
        self.mode = mode
    }

    var body: some View {
        let job = env.toolCompose
        @Bindable var bindable = job
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $bindable.instruction)
                        .frame(minHeight: 140)
                        .disabled(job.isRunning)
                } header: {
                    Text(job.isRevising ? "どう直すか" : "作りたいツール")
                } footer: {
                    Text(job.isRevising
                         ? "例: 「入力欄に燃料の単価を足して、1kmあたりの費用も出して」。今の JSON と、この文を Claude に送ります。"
                         : "例: 「車の燃費と、1kmあたりのガソリン代を計算するツール」「今日の夕飯を決めるルーレット(和食・中華・洋食・麺類)」「出てくる的をタップするゲーム」。動きや描画が必要なものは、スクリプト型(JavaScript)で作ります。この文を Claude に送ります。")
                }
                Section {
                    if job.isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("考え中…").foregroundStyle(.secondary)
                            Spacer()
                            Button("中止", role: .destructive) { job.cancel() }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Button(job.isRevising ? "直してもらう" : "作ってもらう") { start() }
                            .disabled(job.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let reason = env.claude.blockReason {
                        Label(reason.localizedDescription, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let errorText = job.errorText, !job.isRunning {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text("Claude(\(env.settings.claude.model)、思考\(env.settings.claude.thinkingForTools ? "あり" : "なし"))が、小ツールの形式に沿った JSON を作ります。返ってきた JSON はアプリで検証し(スクリプト型は、構文と、試しに数秒動かしたときのエラーも)、誤りがあれば誤りを添えて1回だけ作り直してもらいます。スクリプト型は長くなるので、数分かかることがあります。画面を閉じても作るのは続き、小ツールの一覧の上の帯から戻れます。保存する前に、内容を確認する画面が出ます。")
                }
                if let record = job.recents.entry(job.viewingID) { resultSections(record) }
                recentsSection(job)
            }
            .keyboardDismissable()
            .navigationTitle(job.isRevising ? "文章で直す" : "文章から作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 閉じても、作るのはやめない
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $draft, onDismiss: markIfSaved) { draft in
                ToolImportView(json: draft.json, editingID: draft.editingID)
            }
            .confirmationDialog("この結果を捨てますか?", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("捨てる", role: .destructive) {
                    if let recordToDelete { job.discard(recordToDelete.id) }
                    recordToDelete = nil
                }
            } message: {
                Text("最近作ったものの一覧からも消えます。")
            }
            .onAppear {
                if let mode { job.prepare(mode) }
                job.isShowing = true
            }
            .onDisappear { job.isShowing = false }
        }
    }

    @ViewBuilder
    private func resultSections(_ record: ToolComposeRecord) -> some View {
        Section {
            if record.isValid {
                Label("「\(record.toolName ?? "ツール")」ができました(\(record.kindLabel ?? ""))", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                if let savedAt = record.savedAt {
                    Text("保存しました(\(ClaudeRecentList.dateText(savedAt)))").font(.footnote).foregroundStyle(.secondary)
                }
                Button("内容を確認して保存する") { draft = Draft(json: record.json, editingID: record.reviseID, recordID: record.id) }
            } else {
                Label("2回作ってもらいましたが、形式の誤りが残りました(\(record.issues.count)件)", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(record.issues.prefix(10)) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(issue.message).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("JSONを開いて手で直す") { draft = Draft(json: record.json, editingID: record.reviseID, recordID: record.id) }
            }
            Button("同じ文で作り直す") {
                env.toolCompose.restoreInput(from: record)
                start()
            }
            .disabled(env.toolCompose.isRunning)
            Button("捨てる", role: .destructive) { recordToDelete = record }
        } header: {
            Text("結果(\(ClaudeRecentList.dateText(record.createdAt)))")
        } footer: {
            Text("呼び出し\(record.attempts)回: " + record.usage.summary + "・" + ClaudePricing.text(record.cost))
        }
    }

    private func recentsSection(_ job: ToolComposeJob) -> some View {
        Section {
            if job.recents.entries.isEmpty {
                Text("まだありません").foregroundStyle(.secondary)
            }
            ForEach(job.recents.entries) { record in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        job.open(record.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.instruction).font(.subheadline).foregroundStyle(Color.primary).lineLimit(2)
                            Text(recentCaption(record)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    if record.id == job.viewingID {
                        Image(systemName: "eye").foregroundStyle(Color.accentColor)
                    }
                    Button(role: .destructive) {
                        recordToDelete = record
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("一覧から消す")
                }
            }
        } header: {
            Text("最近作ったもの(\(ClaudeRecentList.limit)件まで)")
        } footer: {
            Text("作った結果は、捨てるか一覧から消すまで残ります。タップすると開き直して、保存・作り直しができます。")
        }
    }

    private func recentCaption(_ record: ToolComposeRecord) -> String {
        var parts = [ClaudeRecentList.dateText(record.createdAt), record.reviseID == nil ? "作成" : "修正", ClaudePricing.text(record.cost)]
        if let name = record.toolName { parts.insert(name, at: 1) }
        if !record.isValid { parts.append("誤りあり") }
        parts.append(record.savedAt == nil ? "未保存" : "保存済み")
        return parts.joined(separator: "・")
    }

    private func start() {
        let job = env.toolCompose
        if let reason = env.claude.blockReason {
            job.reportBlocked(reason.localizedDescription)
            return
        }
        let settings = env.settings.claude
        let service = env.claude
        // スクリプト型は、構文と、試しに数秒動かしたときのエラーも確かめる
        job.start(model: settings.model, thinking: settings.thinkingForTools,
                  validate: { await ScriptTrial.issues(for: $0) },
                  call: { try await service.call($0) })
    }

    /// 確認の画面で保存したら、保存済みにする
    private func markIfSaved() {
        guard let recordID = draft?.recordID ?? lastDraftRecordID, let record = env.toolCompose.recents.entry(recordID),
              let tool = record.tool else { return }
        if env.tools.customSources[tool.id] == record.json {
            env.toolCompose.markSaved(recordID)
            dismiss()
        }
    }

    /// onDismiss の時点では draft が nil になっているので、開いた結果は viewingID から引く
    private var lastDraftRecordID: UUID? { env.toolCompose.viewingID }
}

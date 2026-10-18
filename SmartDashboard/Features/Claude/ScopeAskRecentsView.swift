import SwiftUI

/// 「撮って聞く」の最近聞いたこと(最新10件)。タップで会話を開き直す
struct ScopeAskRecentsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// 会話を開くと決めたとき(この画面を閉じたあとに、聞く画面を出す)
    let onOpen: () -> Void
    @State private var recordToDelete: ScopeAskRecord?

    var body: some View {
        let job = env.scopeAsk
        NavigationStack {
            List {
                if job.recents.entries.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(job.recents.entries) { record in
                    HStack(spacing: 10) {
                        Button {
                            job.open(record)
                            onOpen()
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                if let image = ScopeAskRecord.image(record.thumbnail) {
                                    Image(decorative: image, scale: 1)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.firstQuestion).font(.subheadline).foregroundStyle(Color.primary).lineLimit(2)
                                    Text(caption(record)).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(job.isThinking && job.live?.recordID != record.id)
                        Button(role: .destructive) {
                            recordToDelete = record
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("一覧から消す")
                    }
                }
            }
            .navigationTitle("最近聞いたこと")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .confirmationDialog("この会話を消しますか?", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("消す", role: .destructive) {
                    if let recordToDelete { job.remove(recordToDelete.id) }
                    recordToDelete = nil
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("最新\(ClaudeRecentList.limit)件まで残します。画像は縮めたもの(長い辺\(ScopeAskRecord.thumbnailEdge)px)だけを端末に保存します。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
        }
    }

    private func caption(_ record: ScopeAskRecord) -> String {
        "\(ClaudeRecentList.dateText(record.createdAt))・質問\(record.exchanges.count)回・\(ClaudePricing.text(record.cost))"
    }
}

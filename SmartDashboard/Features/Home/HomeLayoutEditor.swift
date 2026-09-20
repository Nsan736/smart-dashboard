import SwiftUI

/// ホームのカードの並べ替えと、表示・非表示の切り替え
struct HomeLayoutEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(env.settings.homeLayout.order) { kind in
                        row(kind)
                    }
                    .onMove { source, destination in
                        env.settings.homeLayout.order.move(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text("右端のつまみをドラッグして並べ替えます。非表示にしたカードのデータは取得せず、センサーも動かしません(各タブを開いたときは、そのタブが取得します)。")
                }
                Section {
                    Button("初期状態に戻す", role: .destructive) { confirmReset = true }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("ホームの編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .confirmationDialog("並び順と表示を初期状態に戻しますか", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("初期状態に戻す", role: .destructive) { env.settings.homeLayout = .initial }
            }
        }
    }

    private func row(_ kind: HomeCardKind) -> some View {
        Toggle(isOn: Binding(
            get: { env.settings.homeLayout.shows(kind) },
            set: { isOn in
                if isOn { env.settings.homeLayout.hidden.remove(kind) } else { env.settings.homeLayout.hidden.insert(kind) }
            })) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    if let detail = kind.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: kind.symbol)
            }
        }
    }
}

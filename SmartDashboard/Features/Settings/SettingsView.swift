import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var odptToken = ""
    @State private var tokenSaved = false
    @State private var confirmClearCache = false

    var body: some View {
        @Bindable var settings = env.settings
        NavigationStack {
            Form {
                Section {
                    Toggle("Wi-Fi時のみ自動更新", isOn: $settings.wifiOnlyAutoRefresh)
                    LabeledContent("現在の回線", value: env.network.summary)
                } header: {
                    Text("自動更新")
                } footer: {
                    Text("従量制の回線や省データモードの間は自動更新を止めます。手動更新はいつでも使えます。")
                }

                Section {
                    LabeledContent("今日", value: Formatters.bytes(env.usage.today))
                    LabeledContent("今月", value: Formatters.bytes(env.usage.thisMonth))
                } header: {
                    Text("受信データ量")
                } footer: {
                    Text("このアプリが受信したヘッダーと本文の合計です。")
                }

                Section("最終更新") {
                    ForEach(DataKind.allCases, id: \.self) { kind in
                        LabeledContent(kind.label, value: lastFetchedText(kind))
                    }
                }

                Section {
                    SecureField("ODPTアクセストークン", text: $odptToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("トークンを保存") {
                        let trimmed = odptToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        tokenSaved = env.keychain.set(trimmed, for: KeychainAccount.odptToken)
                    }
                    if tokenSaved {
                        Text(odptToken.isEmpty ? "削除しました" : "Keychainに保存しました")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("APIトークン")
                } footer: {
                    Text("トークンはこの端末のKeychainだけに保存します。空にして保存すると削除します。")
                }

                Section("キャッシュ") {
                    LabeledContent("使用量", value: Formatters.bytes(env.cacheSize))
                    Button("キャッシュを削除", role: .destructive) { confirmClearCache = true }
                }
            }
            .navigationTitle("設定")
            .task {
                odptToken = env.keychain.string(for: KeychainAccount.odptToken) ?? ""
                await env.updateCacheSize()
            }
            .confirmationDialog("キャッシュを削除しますか", isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    Task { await env.clearCache() }
                }
            } message: {
                Text("次回の表示時に再取得します。保存した時刻表と設定は消えません。")
            }
        }
    }

    private func lastFetchedText(_ kind: DataKind) -> String {
        guard let date = env.lastFetched[kind] else { return "未取得" }
        return "\(Formatters.dateTime.string(from: date)) (\(Formatters.age(of: date)))"
    }
}

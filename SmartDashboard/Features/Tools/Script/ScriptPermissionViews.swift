import SwiftUI

/// データの種類の1行(名前と説明。居場所が分かる・センサーを動かす種類は目立たせる)
struct ScriptPermissionRow: View {
    let permission: ScriptPermission

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.symbol)
                .foregroundStyle(permission.isSensitive ? Color.orange : Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.subheadline.weight(permission.isSensitive ? .bold : .regular))
                        .fixedSize(horizontal: false, vertical: true)
                    if permission.isSensitive {
                        Text("注意")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                    }
                }
                Text(permission.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(permission.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 読み込む前の確認の画面に出す、使うデータの一覧
struct ScriptPermissionSummarySection: View {
    let permissions: [ScriptPermission]

    var body: some View {
        Section {
            if permissions.isEmpty {
                Text("アプリのデータは使いません")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(permissions) { ScriptPermissionRow(permission: $0) }
                if permissions.contains(where: \.isSensitive) {
                    Label("居場所が分かるデータか、センサーを使います。必要なときだけ許可してください。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("使うアプリのデータ(\(permissions.count))")
        } footer: {
            Text("アプリがすでに取得・保存しているデータの写しを読むだけで、スクリプトから通信したり、データを書き換えたりはできません。初めてツールを開いたときに、種類ごとに許可を求めます。許可しなかった種類は、スクリプトからは空(null)に見えます。保存する前の「動かしてみる」では、実際のデータではなく仮のデータを渡します。")
        }
    }
}

/// 初めてツールを開いたときに、使うデータの許可を求める画面
struct ScriptPermissionRequestView: View {
    let toolName: String
    let requested: [ScriptPermission]
    let onDone: ([ScriptPermission: Bool]) -> Void
    @State private var choices: [ScriptPermission: Bool]

    init(toolName: String, requested: [ScriptPermission], current: [ScriptPermission: Bool], onDone: @escaping ([ScriptPermission: Bool]) -> Void) {
        self.toolName = toolName
        self.requested = requested
        self.onDone = onDone
        var initial: [ScriptPermission: Bool] = [:]
        for permission in requested { initial[permission] = current[permission] ?? permission.grantedByDefault }
        _choices = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                Label("「\(toolName)」がアプリのデータを読もうとしています", systemImage: "hand.raised")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("許可した種類だけを、スクリプトに渡します。読むのは、アプリがすでに取得・保存しているデータの写しだけで、このツールから通信したり、データを書き換えたりはできません。許可しなかった種類は、ツールからは空に見えます(ツールは止まりません)。")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(requested) { permission in
                    Toggle(isOn: Binding(get: { choices[permission] ?? false }, set: { choices[permission] = $0 })) {
                        ScriptPermissionRow(permission: permission)
                    }
                }
            } header: {
                Text("使うデータ")
            } footer: {
                Text("あとで、ツールの画面の「その他」→「データの許可」で変えられます。")
            }
            Section {
                Button {
                    onDone(choices)
                } label: {
                    Text("選んだものを許可して開く").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    onDone(Dictionary(uniqueKeysWithValues: requested.map { ($0, false) }))
                } label: {
                    Text("すべて許可しないで開く").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .listRowBackground(Color.clear)
        }
    }
}

/// ツールごとのデータの許可の変更・取り消し(ツールの画面の「その他」から開く)
struct ScriptPermissionSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let toolID: String
    let toolName: String
    let requested: [ScriptPermission]

    var body: some View {
        NavigationStack {
            Form {
                if requested.isEmpty {
                    Section {
                        Text("このツールは、アプリのデータを使いません。").foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(requested) { permission in
                            Toggle(isOn: Binding(
                                get: { env.settings.scriptPermissions.isGranted(permission, toolID: toolID) },
                                set: { env.settings.scriptPermissions.set(permission, granted: $0, toolID: toolID) }
                            )) {
                                ScriptPermissionRow(permission: permission)
                            }
                        }
                    } header: {
                        Text("「\(toolName)」に渡すデータ")
                    } footer: {
                        Text("変えると、ツールを最初から動かし直します。オフにした種類は、ツールからは空(null)に見えます。センサーはツールを開いている間だけ動き、閉じると止まります。")
                    }
                    Section {
                        Button("すべて取り消す(次に開いたときに、もう一度聞く)", role: .destructive) {
                            env.settings.scriptPermissions.reset(toolID: toolID)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("データの許可")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

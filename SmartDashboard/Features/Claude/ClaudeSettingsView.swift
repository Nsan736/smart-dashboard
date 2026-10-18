import SwiftUI

/// 設定の「Claude API」。APIキー(Keychain)、モデル、料金、今月の使用量、上限、思考、カメラの質問で送る情報。
struct ClaudeSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var keyText = ""
    @State private var keyMessage: String?

    var body: some View {
        @Bindable var settings = env.settings
        let claude = env.claude
        let month = claude.thisMonth
        Form {
            Section {
                LabeledContent("状態", value: claude.hasKey ? "保存済み" : "未設定")
                SecureField("sk-ant-…", text: $keyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("保存") {
                        claude.setAPIKey(keyText)
                        keyText = ""
                        keyMessage = claude.hasKey ? "保存しました" : "空のため、削除しました"
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("削除", role: .destructive) {
                        claude.setAPIKey("")
                        keyMessage = "削除しました"
                    }
                    .disabled(!claude.hasKey)
                }
                .buttonStyle(.borderless)
                if let keyMessage { Text(keyMessage).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("APIキー")
            } footer: {
                Text("APIキーは各自で Claude Console(platform.claude.com)で作って、ここに入力してください。キーは端末の Keychain だけに保存し、画面にもログにも出しません。料金は、そのキーのアカウントに請求されます。")
            }

            Section {
                TextField("モデル", text: $settings.claude.model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("初期値(\(ClaudeSettings.defaultModel))に戻す") { settings.claude.model = ClaudeSettings.defaultModel }
                    .disabled(settings.claude.model == ClaudeSettings.defaultModel)
                Toggle("小ツールを作るときに思考する", isOn: $settings.claude.thinkingForTools)
                Toggle("カメラの質問で思考する", isOn: $settings.claude.thinkingForCamera)
            } header: {
                Text("モデルと思考")
            } footer: {
                Text("思考は適応的思考(どれだけ考えるかをモデルが決める)で、正確さが上がるかわりに時間と出力のトークンが増えます。思考のトークンは出力の料金で計算され、使用量に含めます。思考をオフにできないモデル(Claude Opus 5.5 など)では、オフにするとエラーになります。")
            }

            Section {
                priceField("入力", value: $settings.claude.pricing.input)
                priceField("出力(思考を含む)", value: $settings.claude.pricing.output)
                priceField("キャッシュの書き込み", value: $settings.claude.pricing.cacheWrite)
                priceField("キャッシュの読み込み", value: $settings.claude.pricing.cacheRead)
                Button("初期値(Claude Haiku 5.5)に戻す") { settings.claude.pricing = ClaudePricing() }
                    .disabled(settings.claude.pricing == ClaudePricing())
            } header: {
                Text("料金(100万トークンあたりのドル)")
            } footer: {
                Text("おおよその金額の計算に使います。初期値は Claude Haiku 5.5 の料金(プロンプトが10万トークン以下のとき。2026-10-18 に公式の料金表で確認)。モデルを変えたら、ここも合わせてください。実際の請求額は Claude Console で確かめてください。")
            }

            Section {
                LabeledContent("呼び出し", value: "\(month.calls)回")
                LabeledContent("入力", value: ClaudeUsage.number(month.usage.totalInput) + "トークン")
                LabeledContent("うちキャッシュ(読込/書込)", value: ClaudeUsage.number(month.usage.cacheRead) + " / " + ClaudeUsage.number(month.usage.cacheWrite))
                LabeledContent("出力", value: ClaudeUsage.number(month.usage.output) + "トークン")
                LabeledContent("うち思考", value: ClaudeUsage.number(month.usage.thinking) + "トークン")
                LabeledContent("おおよその金額", value: ClaudePricing.text(month.cost))
                HStack {
                    Text("月の上限額")
                    Spacer()
                    TextField("5", value: $settings.claude.monthlyLimit, format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                    Text("ドル")
                }
                if case .overBudget? = claude.blockReason {
                    Label("上限に達したため、呼び出しを止めています", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("今月の使用量")
            } footer: {
                Text("この端末から呼び出した分だけを、応答の usage(キャッシュの読み書きと思考の内訳を含む)から数えています(日本時間の月ごと)。上限に達すると、次の呼び出しから止めます(1回の呼び出しの途中では止まらないので、少し超えることがあります)。")
            }

            Section {
                Toggle("撮ったときの方角と端末の上下の向き", isOn: $settings.claude.sendsHeading)
                Toggle("現在地のおおよその地名", isOn: $settings.claude.sendsPlace)
                Toggle("緯度経度も送る(小数第3位まで)", isOn: $settings.claude.sendsCoordinates)
                    .disabled(!settings.claude.sendsPlace)
                Toggle("撮った方向にある地点・施設・電車の名前と距離", isOn: $settings.claude.sendsTargets)
                Stepper(value: $settings.claude.imageEdge, in: 512...1568, step: 128) {
                    Text("画像の長い辺: \(settings.claude.imageEdge)px")
                }
                Toggle("モバイル通信のときは小さくする(\(settings.claude.cellularImageEdge)px)", isOn: $settings.claude.smallerOnCellular)
            } header: {
                Text("カメラの質問で一緒に送るもの")
            } footer: {
                Text("「撮って聞く」を押したときだけ、止めた画像(JPEG)と、ここで選んだ情報を Claude に送ります。画像は端末に保存しません。長い辺1024pxの画像は、入力で約800〜1,300トークンです(28×28ピクセルごとに1トークン。縦横比で変わります)。")
            }
        }
        .keyboardDismissable()
        .navigationTitle("Claude API")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func priceField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number.precision(.fractionLength(0...4)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
        }
    }
}

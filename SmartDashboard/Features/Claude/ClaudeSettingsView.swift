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
                priceField("Web 検索(1,000回あたり)", value: $settings.claude.pricing.webSearchPer1000)
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
                LabeledContent("Web 検索", value: "\(month.usage.webSearches)回")
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
                sendRow("画像と質問の文", detail: "止めた画像(囲んだときはその部分)と、質問の文。画像は JPEG で、位置などのメタデータ(EXIF)は含みません。写っている景色から、場所が分かることはあります。", privacy: "常に送る")
                Toggle(isOn: $settings.claude.sendsHeading) {
                    sendLabel("撮ったときの方角と端末の上下の向き", detail: "例: 北東(45°)、水平より10°上向き。", privacy: "居場所は分からない")
                }
                Toggle(isOn: $settings.claude.sendsPlace) {
                    sendLabel("現在地のおおよその地名", detail: "例: 東京都千代田区。", privacy: "居場所が分かる")
                }
                Toggle(isOn: $settings.claude.sendsCoordinates) {
                    sendLabel("緯度経度も送る", detail: "小数第3位まで(約100m)。地名を送るときだけ。", privacy: "居場所が分かる")
                }
                .disabled(!settings.claude.sendsPlace)
                Toggle(isOn: $settings.claude.sendsTargets) {
                    sendLabel("撮った方向にある地点・施設・電車の名前と距離", detail: "スコープで計算している、画面に写る範囲のもの。", privacy: "居場所が推測できる")
                }
                Stepper(value: $settings.claude.imageEdge, in: 512...1568, step: 128) {
                    Text("画像の長い辺: \(settings.claude.imageEdge)px")
                }
                Toggle("モバイル通信のときは小さくする(\(settings.claude.cellularImageEdge)px)", isOn: $settings.claude.smallerOnCellular)
            } header: {
                Text("カメラの質問で一緒に送るもの")
            } footer: {
                Text("「撮って聞く」は、カメラに写っているものから見つけることを基本にしています。居場所が分かる・推測できる情報は、初期値で送りません(v0.9.19 までに変えた設定も、送らない設定に戻しました)。送ったものは、答えの下に「画像・質問・方角と向きを送信」のように出ます。画像は端末に保存しません。長い辺1024pxの画像は、入力で約800〜1,300トークンです。")
            }

            Section {
                Toggle("カメラの質問で Web 検索を使う", isOn: $settings.claude.webSearch)
                Stepper(value: $settings.claude.webSearchMaxUses, in: 1...ClaudeSettings.maxWebSearches) {
                    Text("1回の質問で、検索は\(settings.claude.webSearchMaxUses)回まで")
                }
                .disabled(!settings.claude.webSearch)
            } header: {
                Text("Web 検索")
            } footer: {
                Text("Claude API のサーバー側の Web 検索を、Claude が必要なときだけ使います。検索1回ごとに料金がかかり(初期値 1,000回あたり10ドル)、使用量と月の上限に含めます。検索の言葉には、写っているものの特徴だけを使い、現在地や地名を入れないよう指示しています。答えに使った出典は、答えの下に出ます。このモデルや組織で使えないときは、検索なしで答えます。")
            }
        }
        .keyboardDismissable()
        .navigationTitle("Claude API")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendLabel(_ title: String, detail: String, privacy: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail + " " + privacy).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sendRow(_ title: String, detail: String, privacy: String) -> some View {
        HStack {
            sendLabel(title, detail: detail, privacy: "")
            Spacer(minLength: 8)
            Text(privacy).font(.caption).foregroundStyle(.secondary)
        }
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

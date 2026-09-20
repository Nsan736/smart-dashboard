import SwiftUI
import UIKit

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
                    Text("モバイル通信でも、最短の更新間隔(天気30分、雨の要約10分、運行情報5分、為替1日)を守って自動更新します。iOSの省データモードの間は自動更新を止めます。手動更新はいつでも使えます。地図タイルの自動保存はWi-Fi時だけです。")
                }

                Section {
                    UsageSummaryRow(title: "今日", wifi: env.usage.today(.wifi), cellular: env.usage.today(.cellular),
                                    unknown: env.usage.today(.unknown))
                    UsageSummaryRow(title: "今月", wifi: env.usage.thisMonth(.wifi), cellular: env.usage.thisMonth(.cellular),
                                    unknown: env.usage.thisMonth(.unknown))
                    NavigationLink("機能別の内訳(今月)") { UsageBreakdownView() }
                } header: {
                    Text("受信データ量")
                } footer: {
                    Text("このアプリが受信したヘッダーと本文の合計を、通信1回ごとに回線を判定して記録しています。テザリングなど従量制の回線はモバイル通信に含めます。Apple Maps の地図と地名の取得はiOSが通信するため、ここには含まれません。")
                }

                Section {
                    Toggle("今月のモバイル通信量が上限を超えたら自動更新を止める", isOn: $settings.cellularLimitEnabled)
                    if settings.cellularLimitEnabled {
                        Stepper(value: $settings.cellularLimitMB, in: 10...5000, step: 10) {
                            Text("上限 \(settings.cellularLimitMB) MB")
                        }
                        if settings.cellularLimitReached {
                            Label("上限を超えています。手動更新は使えます。", systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("モバイル通信量の上限")
                } footer: {
                    Text("上限を超えると、モバイル通信での自動更新を止めます。手動更新と、Wi-Fi時の自動更新はそのままです。")
                }

                Section("登録内容") {
                    NavigationLink("タブの並び順") { TabOrderEditor() }
                    NavigationLink("天気の地点") { PlacesEditorView() }
                    NavigationLink("地図(表示と保存)") { MapSettingsView() }
                    NavigationLink("電車の路線・駅") { TrainRegistrationListView() }
                    NavigationLink("為替の通貨") {
                        CurrencyPickerView(available: env.exchange.cached?.value.availableCodes ?? AppSettings.defaultExchangeCodes)
                    }
                }

                Group {
                AlertSettingsSections()
                Section {
                    Toggle("センサー画面の表示中は画面を消さない", isOn: $settings.sensorsKeepAwake)
                } header: {
                    Text("センサー")
                } footer: {
                    Text("速度は高精度のGPSを使うため、表示中は電池を多く使います。画面を離れると測位を止めます。ホームの速度のカードは、ホームの「編集」で非表示にできます(非表示の間はGPSを動かしません)。")
                }
                }


                Section {
                    Toggle("年末年始(12/30〜1/3)は休日ダイヤ", isOn: $settings.yearEndHolidayTimetable)
                } header: {
                    Text("電車のダイヤ")
                } footer: {
                    Text("今日だけ切り替えたいときは、電車の画面の「今日のダイヤ」を使ってください。")
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
                        tokenSaved = env.setODPTToken(trimmed)
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

                Section {
                    NavigationLink("運行情報の直近のレスポンス") { TrainInfoCaptureView() }
                    LabeledContent("カメラの起動時間") {
                        Text(env.camera.lastTiming?.text ?? "未計測(「カメラで見る」を開くと計測します)")
                            .font(.footnote)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("開発者向け")
                } footer: {
                    Text("遅延などが起きたときの応答を確認・コピーできます。保存するのは直近の1件だけで、追加の通信はしません。")
                }

                Section("キャッシュ") {
                    LabeledContent("使用量", value: Formatters.bytes(env.cacheSize))
                    Button("キャッシュを削除", role: .destructive) { confirmClearCache = true }
                }
            }
            .keyboardDismissable()
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
        guard let date = env.fetchLog.lastFetched[kind] else { return "未取得" }
        return "\(Formatters.dateTime.string(from: date)) (\(Formatters.age(of: date)))"
    }
}

/// 登録した路線・駅の一覧と削除
struct TrainRegistrationListView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.trains
        List {
            Section("運行情報の路線") {
                if store.lines.isEmpty { Text("まだありません").foregroundStyle(.secondary) }
                ForEach(store.lines) { line in
                    Text(line.railwayName)
                }
                .onDelete { store.removeLines(at: $0) }
            }
            Section("時刻表の駅") {
                if store.stations.isEmpty { Text("まだありません").foregroundStyle(.secondary) }
                ForEach(store.stations) { station in
                    VStack(alignment: .leading) {
                        Text(station.stationName)
                        Text("\(station.railwayName)・\(station.directionName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { store.removeStations(at: $0) }
            }
            Section {
                NavigationLink {
                    OperatorPickerView()
                } label: {
                    Label("路線・駅を登録", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("路線・駅")
        .toolbar { EditButton() }
    }
}

/// 「今日」「今月」の受信量を、Wi-Fiとモバイル通信に分けて表示する
struct UsageSummaryRow: View {
    let title: String
    let wifi: Int64
    let cellular: Int64
    let unknown: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack {
                Label(Formatters.bytes(wifi), systemImage: "wifi")
                Spacer(minLength: 8)
                Label(Formatters.bytes(cellular), systemImage: "antenna.radiowaves.left.and.right")
            }
            .font(.body.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if unknown > 0 {
                Text("回線不明(以前の記録): \(Formatters.bytes(unknown))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 機能別の内訳(今月)
struct UsageBreakdownView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(UsageCategory.allCases, id: \.self) { category in
                    let wifi = env.usage.thisMonth(.wifi, category)
                    let cellular = env.usage.thisMonth(.cellular, category)
                    let unknown = env.usage.thisMonth(.unknown, category)
                    if category != .legacy || unknown > 0 {
                        UsageSummaryRow(title: category.label, wifi: wifi, cellular: cellular, unknown: unknown)
                    }
                }
            } header: {
                Text("今月")
            } footer: {
                Text("左がWi-Fi、右がモバイル通信です。")
            }
            Section {
                LabeledContent("地名の取得", value: "\(env.usage.geocodeRequestsThisMonth) 回")
            } footer: {
                Text("地名(CLGeocoder)と Apple Maps の通信はiOSが行うため、アプリからは受信量を計測できません。地名は500m以上移動したときだけ取得するので、回数だけを記録しています。")
            }
        }
        .navigationTitle("機能別の内訳")
    }
}

/// 開発者向け: 運行情報の直近の応答(生のJSON)を表示・コピーする
struct TrainInfoCaptureView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var copied = false

    var body: some View {
        List {
            if let capture = env.trains.lastCapture {
                Section {
                    LabeledContent("取得時刻", value: Formatters.dateTime.string(from: capture.fetchedAt))
                    LabeledContent("事業者", value: capture.value.operatorName)
                    LabeledContent("サイズ", value: Formatters.bytes(Int64(capture.value.body.utf8.count)))
                    Button {
                        UIPasteboard.general.string = capture.value.body
                        copied = true
                    } label: {
                        Label(copied ? "コピーしました" : "JSONをコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: capture.value.body) {
                        Label("共有", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("アクセストークンは応答の本文には含まれません。")
                }
                Section("JSON") {
                    Text(capture.value.body)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                ContentUnavailableView("まだありません", systemImage: "doc.text",
                                       description: Text("電車の画面で運行情報を更新すると、その応答がここに保存されます。"))
            }
        }
        .navigationTitle("直近のレスポンス")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.trains.loadIfNeeded() }
    }
}

/// 地震・気圧の設定と、バックグラウンドでの気圧の記録
struct AlertSettingsSections: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmBackgroundPressure = false

    var body: some View {
        @Bindable var settings = env.settings
        Section {
            Picker("ホームに出す地震", selection: $settings.quakeMinimumScale) {
                ForEach(SeismicScale.choices, id: \.self) { scale in
                    Text("震度\(SeismicScale.label(scale))以上").tag(scale)
                }
            }
            Stepper(value: $settings.pressureAlertDrop, in: 1...10, step: 0.5) {
                Text("気圧の低下を目立たせる：3時間で−\(String(format: "%.1f", settings.pressureAlertDrop))hPa以上")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("ウェイポイントで、向いている方角を表示", isOn: $settings.waypointShowsHeading)
        } header: {
            Text("地震・気圧・ウェイポイント")
        }

        Section {
            Toggle("バックグラウンドで気圧を記録", isOn: Binding(
                get: { settings.backgroundPressureEnabled },
                set: { isOn in
                    if isOn { confirmBackgroundPressure = true } else {
                        settings.backgroundPressureEnabled = false
                        env.keeper.evaluate()
                    }
                }))
            if settings.backgroundPressureEnabled {
                LabeledContent("状態", value: env.keeper.statusText)
                switch env.keeper.lastCheck {
                case .recorded:
                    Text("前回アプリを閉じていた間も、記録が続いていました。").font(.footnote).foregroundStyle(.secondary)
                case .notRecorded:
                    Text("この環境ではバックグラウンドで記録できないようです").font(.footnote).foregroundStyle(.orange)
                default:
                    Text("アプリを15分以上閉じてから開き直すと、その間も記録できていたかを判定します。").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("気圧の記録")
        } footer: {
            Text("無音のオーディオを再生してアプリを動かしたままにし、閉じている間も5分に1回気圧を記録します。ほかのアプリの音は止めません。電池残量が20%未満のときと、低電力モードのときは自動で止まります。")
        }
        .confirmationDialog("バックグラウンドで気圧を記録しますか", isPresented: $confirmBackgroundPressure, titleVisibility: .visible) {
            Button("オンにする") {
                settings.backgroundPressureEnabled = true
                env.keeper.evaluate()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("アプリを閉じている間も動き続けるため、電池の消費が増えます。")
        }
    }
}

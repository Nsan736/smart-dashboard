import SwiftUI

/// 文章からオブジェクトの JSON を Claude に作ってもらう。細かさ(形の数・出力の上限)を選べ、Web 検索(1回の依頼で2回まで)で
/// 実在の物の高さ・形・色を調べてから作れる。返ってきた JSON は ObjectCodec で検証し、誤りがあれば1回だけ(検索なしで)作り直しを頼む。
/// 送るのは利用者が入力した文章だけ(現在地などは送らない)。
enum ObjectGenerator {
    /// ストリーミングで受け取るので、この時間は「何も届かない時間」の上限
    static let timeout: TimeInterval = 600
    static let maxInstruction = 1_000
    static let maxSearches = 2

    struct Outcome {
        var object: ScopeObject?
        var json: String
        var issues: [ToolIssue]
        var usage: ClaudeUsage
        var cost: Double
        var attempts: Int
        var detail: ObjectDetail
        /// Web 検索を使う依頼が受け付けられず、検索なしで作り直した
        var searchFallback = false
        /// 参考にしたページ
        var citations: [ClaudeCitation] = []
        /// 検索の失敗(error_code)
        var searchErrors: [String] = []

        var searches: Int { usage.webSearches }
    }

    static let basePrompt = """
    あなたは、iOS アプリ「スマートダッシュボード」のスコープに置く、3Dのオブジェクトを作る係です。利用者の依頼に合うオブジェクトを、下の形式の JSON だけで返します。説明の文章やコードブロックの記号(```)は付けないでください。

    形式:
    {"format":1,"type":"scope-object","name":"名前(日本語、40文字まで)","shapes":[形,...]}
    形: {"kind":種類,"width":幅,"depth":奥行き,"height":高さ,"x":左右,"y":前後,"z":上下,"yaw":向き,"pitch":前後の傾き,"roll":左右の傾き,"color":"#RRGGBB","opacity":不透明度}
    - kind: "box"(箱)、"cylinder"(円柱)、"cone"(円錐、頂点が上)、"sphere"(球。幅・奥行き・高さが違えば楕円体)、"pyramid"(四角錐、頂点が上)、"plane"(縦の板。幅×高さで、正面が前。奥行きは使わない)
    - 大きさ(width・depth・height)は m(0.01〜2000)。x は右が正、y は前が正、z は上が正で、形の底面の中心の位置(m、−2000〜2000)。地面は z=0
    - 回転は度。yaw は上から見て時計回り、pitch は前が上がる向き、roll は右が下がる向き。形の中心のまわりに、roll → pitch → yaw の順に回す
    - color は "#RRGGBB"。opacity は 0.05〜1(依頼に指定がなければ 0.4 の半透明)。色の指定がなければ赤 "#FF0000"
    - 出力を短くするため、値が初期値の項目(x・y・z・yaw・pitch・roll が 0、opacity が 0.4)は書かないでください。空白や改行は入れないでください
    - 形の数は、依頼の文に書いた上限を超えないでください

    細かく作るときのコツ:
    - 実物の高さ・幅・比率を守る(全体の高さを先に決め、部分の大きさはその比で決める)
    - 目立つ部分(展望台、アンテナ、屋根、窓の並び、柱、手すり、看板など)を優先して形を使う。見えない内側は作らない
    - くり返す部分(鉄骨の段、窓の列、階段、柵など)は、同じ形を少しずつ位置・大きさを変えて並べる(上に行くほど細くなる塔なら、段ごとに幅を少し小さくする)
    - 色は部分ごとに分ける(屋根・壁・窓・柱など)。実物の色が分かれば、その色にする
    - 細い部材(鉄骨、アンテナ)は、細長い箱や円柱で表す。斜めの部材は pitch・roll で傾ける
    - 地面から浮かないように、いちばん下の形の z は 0 にする
    """

    static let searchPrompt = """

    Web 検索:
    - 実在の建物や物の依頼なら、作る前に web_search で、高さ・形・色・特徴を調べてください(2回まで)。架空の物や一般的な物(「2階建ての家」など)では、検索しなくてかまいません
    - 検索の言葉には、建物や物の名前と知りたいこと(高さ、構造など)だけを使ってください
    - 調べた結果は、大きさや色に反映し、JSON だけを返してください
    """

    static func systemPrompt(webSearch: Bool) -> String {
        webSearch ? basePrompt + searchPrompt : basePrompt
    }

    static func messages(description: String, detail: ObjectDetail) -> [ClaudeMessage] {
        [.user("次のオブジェクトを作ってください。細かさ: \(detail.label)(形は\(detail.maxShapes)個まで。上限に近いほど細かく作ってください)\n\n"
               + String(description.prefix(maxInstruction)))]
    }

    static func request(messages: [ClaudeMessage], model: String, thinking: Bool, detail: ObjectDetail, webSearch: Bool) -> ClaudeRequest {
        ClaudeRequest(model: model, system: systemPrompt(webSearch: webSearch), cachesSystem: true, messages: messages,
                      maxTokens: detail.maxTokens, thinking: thinking, timeout: timeout,
                      webSearchMaxUses: webSearch ? maxSearches : nil)
    }

    /// 誤りを添えて作り直しを頼む文(長すぎて切れたときは、形を減らすように頼む)
    static func retryMessage(issues: [ToolIssue], stopReason: String?, detail: ObjectDetail) -> String {
        var text = ToolGenerator.retryMessage(issues: issues)
        if stopReason == "max_tokens" {
            text += "\n\n答えが長すぎて途中で切れました。形を\(max(10, detail.maxShapes * 2 / 3))個までに減らして、省略できる項目は書かずに、JSON 全体を返してください。"
        }
        return text
    }

    /// 作る流れ。call は Claude を呼ぶ部分(本番はストリーミングの ClaudeService.callStreaming、テストでは決まった応答)
    static func run(description: String, detail: ObjectDetail, webSearch: Bool, model: String, thinking: Bool,
                    call: (ClaudeRequest) async throws -> ClaudeCallResult) async throws -> Outcome {
        var outcome = Outcome(object: nil, json: "", issues: [], usage: ClaudeUsage(), cost: 0, attempts: 0, detail: detail)
        var messages = messages(description: description, detail: detail)
        var usesSearch = webSearch
        while outcome.attempts < 2 {
            let request = request(messages: messages, model: model, thinking: thinking, detail: detail, webSearch: usesSearch)
            let result = try await ClaudeSearchCall.run(request, withoutSearch: { plain in
                var plain = plain
                plain.system = systemPrompt(webSearch: false)
                return plain
            }, call: call)
            outcome.attempts += 1
            outcome.usage += result.response.usage
            outcome.cost += result.cost
            if result.searchFallback { outcome.searchFallback = true }
            outcome.citations += result.response.citations.filter { citation in !outcome.citations.contains { $0.url == citation.url } }
            outcome.searchErrors += result.response.searchErrors
            let answer = result.response.text
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClaudeError.emptyAnswer(stopReason: result.response.stopReason)
            }
            outcome.json = ToolGenerator.extractJSON(answer)
            switch ObjectCodec.parse(outcome.json, maxShapes: detail.maxShapes) {
            case .success(let object):
                outcome.object = object
                outcome.issues = []
                return outcome
            case .failure(let issues):
                outcome.issues = issues
                // 作り直しは検索なしで(調べた結果は、1回目の答えに入っている)
                usesSearch = false
                messages.append(.assistant(answer))
                messages.append(.user(retryMessage(issues: issues, stopReason: result.response.stopReason, detail: detail)))
            }
        }
        return outcome
    }

    /// 料金の目安(ドル)。形1つ約50トークン、思考は形の分と同じくらい、検索1回で結果の入力が約1万5千トークン(Claude Haiku 5.5 の料金で計算)
    static func estimatedCost(detail: ObjectDetail, webSearch: Bool, pricing: ClaudePricing = ClaudePricing()) -> Double {
        let output = Double(detail.maxShapes) * 50 * 2 + 1_000
        var usage = ClaudeUsage(input: 2_500, output: Int(output))
        if webSearch {
            usage.input += 30_000
            usage.webSearches = maxSearches
        }
        return pricing.cost(usage)
    }
}

/// 作っている間の進み具合
struct ObjectGenerationProgress: Equatable {
    var stage = "送信中…"
    var searches = 0
    var query: String?
    var characters = 0
    var shapes = 0
    var startedAt = Date()

    /// 受け取った出来事で、表示を変える
    mutating func apply(_ event: ClaudeStreamEvent) {
        switch event {
        case .started:
            stage = "作り始めました"
        case .thinking:
            stage = "考えています"
        case .searching(let count, let query):
            searches = max(searches, count)
            if let query { self.query = query }
            stage = "Web で調べています(\(searches)回目)"
        case .searched(let count):
            stage = "調べた結果を読んでいます(\(count)回目)"
        case .writing(let characters, let shapes):
            self.characters = characters
            self.shapes = shapes
            stage = shapes > 0 ? "形を受け取っています(\(shapes)個)" : "答えを受け取っています"
        }
    }
}

/// 文章からオブジェクトを作る画面。細かさと Web 検索を選び、進み具合を見ながら待ち、確認の画面でプレビューしてから保存する
struct ObjectComposeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @AppStorage("objects.composeDetail") private var detailRaw = ObjectDetail.initial.rawValue
    @AppStorage("objects.composeSearch") private var webSearch = true
    @State private var instruction = ""
    @State private var task: Task<Void, Never>?
    @State private var outcome: ObjectGenerator.Outcome?
    @State private var errorText: String?
    @State private var progress = ObjectGenerationProgress()
    @State private var safariURL: ScopeAskURL?

    private var detail: ObjectDetail { ObjectDetail(rawValue: detailRaw) ?? .initial }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $instruction)
                        .frame(minHeight: 100)
                        .disabled(task != nil)
                } header: {
                    Text("作りたいオブジェクト")
                } footer: {
                    Text("例: 「東京タワー」「高さ30mの赤い塔」「2階建ての家」「青い半透明の球(直径10m)」。送るのはこの文だけで、今いる場所などは送りません。")
                }
                Section {
                    Picker("細かさ", selection: $detailRaw) {
                        ForEach(ObjectDetail.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Web で調べる(2回まで)", isOn: $webSearch)
                } footer: {
                    Text("形は\(detail.maxShapes)個まで。料金の目安は1回あたり約\(ClaudePricing.text(ObjectGenerator.estimatedCost(detail: detail, webSearch: webSearch)))"
                         + (webSearch ? "(検索1回 約0.01ドルを含む)" : "") + "。細かいほど時間がかかります(とても細かいときは数分)。Web で調べると、実在の建物などの高さ・形・色を調べてから作ります。")
                }
                .disabled(task != nil)
                Section {
                    if task != nil {
                        progressView
                    } else {
                        Button("作ってもらう") { start() }
                            .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let reason = env.claude.blockReason {
                        Label(reason.localizedDescription, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    if let errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let outcome { resultSections(outcome) }
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
            .sheet(item: $safariURL) { ScopeAskSafariView(url: $0.url).ignoresSafeArea() }
            .onDisappear { task?.cancel() }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                Text(progress.stage).font(.subheadline.weight(.semibold))
                Spacer()
                Button("取り消し", role: .cancel) { task?.cancel() }.buttonStyle(.bordered)
            }
            if let query = progress.query {
                Text("検索: \(query)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(Int(context.date.timeIntervalSince(progress.startedAt)))秒・受け取った文字 \(progress.characters)・形 \(progress.shapes) / \(detail.maxShapes)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ outcome: ObjectGenerator.Outcome) -> some View {
        if let object = outcome.object {
            ObjectConfirmSection(object: object)
            Section {
                LabeledContent("形の数", value: "\(object.shapes.count) / \(outcome.detail.maxShapes)")
                LabeledContent("面の数(カメラ表示で近くのとき)", value: "\(ObjectGeometry.faces(of: object).count)")
                LabeledContent("料金(概算)", value: ClaudePricing.text(outcome.cost))
                LabeledContent("Web 検索", value: outcome.searchFallback ? "使えませんでした" : "\(outcome.searches)回")
                if outcome.searchFallback {
                    Text("このモデルか組織では Web 検索を使えなかったため、検索なしで作りました。")
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !outcome.searchErrors.isEmpty {
                    Text("検索でエラーがありました(\(outcome.searchErrors.joined(separator: "、")))。分かる範囲で作っています。")
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Button("保存する") {
                    env.objects.save(object)
                    dismiss()
                }
            } footer: {
                Text("呼び出し\(outcome.attempts)回: " + outcome.usage.summary)
            }
            if !outcome.citations.isEmpty {
                Section("参考にしたページ") {
                    ForEach(outcome.citations) { citation in
                        Button {
                            if let url = URL(string: citation.url) { safariURL = ScopeAskURL(url: url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(citation.title).font(.subheadline).foregroundStyle(Color.primary).lineLimit(2)
                                Text(citation.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        } else {
            Section("形式の誤りが残りました(\(outcome.issues.count)件)") {
                ForEach(outcome.issues.prefix(10)) { issue in
                    Text("\(issue.path): \(issue.message)").font(.footnote).foregroundStyle(.red)
                }
                LabeledContent("料金(概算)", value: ClaudePricing.text(outcome.cost))
            }
        }
    }

    private func start() {
        guard task == nil else { return }
        errorText = nil
        outcome = nil
        progress = ObjectGenerationProgress()
        if let reason = env.claude.blockReason {
            errorText = reason.localizedDescription
            return
        }
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = env.settings.claude
        let service = env.claude
        let detail = detail
        let webSearch = webSearch
        task = Task {
            do {
                outcome = try await ObjectGenerator.run(description: text, detail: detail, webSearch: webSearch, model: settings.model,
                                                        thinking: settings.thinkingForTools) { request in
                    try await service.callStreaming(request) { event in
                        Task { @MainActor in progress.apply(event) }
                    }
                }
            } catch is CancellationError {
                errorText = "取り消しました(Claude 側で処理が進んでいた分は、料金がかかることがあります)"
            } catch {
                errorText = error.localizedDescription
            }
            task = nil
        }
    }
}

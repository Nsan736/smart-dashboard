import SwiftUI

/// 文章からオブジェクトの JSON を Claude に作ってもらう。細かさ(形の数・出力の上限)を選べ、Web 検索(1回の依頼で2回まで)で
/// 実在の物の高さ・各部の寸法・色を調べてから作れる(調べた寸法の一覧を JSON の前に書かせ、確認の画面に出す)。
/// 返ってきた JSON は ObjectCodec で検証し、誤りがあれば1回だけ(検索なしで)作り直しを頼む。ほかの形の中に隠れる形は、確認の画面で除ける。
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
        /// 調べた寸法の一覧(Web 検索のとき、答えの <dimensions> の中)
        var dimensions: [ObjectDimension] = []
        /// ほかの形の中に完全に入っている形の番号(確認の画面で除ける)
        var hiddenShapes: [Int] = []

        var searches: Int { usage.webSearches }
    }

    static let basePrompt = """
    あなたは、iOS アプリ「スマートダッシュボード」のスコープに置く、3Dのオブジェクトを作る係です。このオブジェクトは、スコープのカメラ表示で実際の景色に重ねて、外から(多くは離れた所から)見るためのものです。利用者の依頼に合うオブジェクトを、下の形式の JSON だけで返します。説明の文章やコードブロックの記号(```)は付けないでください。

    形式:
    {"format":1,"type":"scope-object","name":"名前(日本語、40文字まで)","shapes":[形,...]}
    形: {"kind":種類,"width":幅,"depth":奥行き,"height":高さ,"x":左右,"y":前後,"z":上下,"yaw":向き,"pitch":前後の傾き,"roll":左右の傾き,"color":"#RRGGBB","opacity":不透明度}
    - kind: "box"(箱)、"cylinder"(円柱)、"cone"(円錐、頂点が上)、"sphere"(球。幅・奥行き・高さが違えば楕円体)、"pyramid"(四角錐、頂点が上)、"plane"(縦の板。幅×高さで、正面が前。奥行きは使わない)
    - 大きさ(width・depth・height)は m(0.01〜2000)。width は左右(x の向き)、depth は前後(y の向き)、height は上下(z の向き)の大きさ
    - x・y・z は、形の底面の中心の位置(m、−2000〜2000)。地面は z=0
    - 回転は度。yaw は上から見て時計回り、pitch は前が上がる向き、roll は右が下がる向き。形の中心のまわりに、roll → pitch → yaw の順に回す
    - color は "#RRGGBB"。opacity は 0.05〜1(依頼に指定がなければ 0.4 の半透明)。色の指定がなければ赤 "#FF0000"
    - 出力を短くするため、値が初期値の項目(x・y・z・yaw・pitch・roll が 0、opacity が 0.4)は書かないでください。空白や改行は入れないでください
    - 形の数は、依頼の文に書いた上限を超えないでください

    軸と正面の決まり(必ず守ってください):
    - +y がオブジェクトの正面の向きです(建物なら正面の入口・正面の外壁がある側、乗り物なら先頭・進む向き、人や動物なら顔の向き)。地図に置いたとき、向き0°なら +y は北を、向き90°なら東を向きます
    - +x はオブジェクトの右です(正面と同じ向きに立ったときの右手の側。正面から向かい合って見ると、見る人の左の側)。+z は上です
    - 正面が長い辺でない物も、正面を +y に合わせてください。例: 電車や車は、長さを depth(y)、幅を width(x)にして、先頭を +y に置く
    - 板(plane)の表と裏は ±y を向きます。左右の側面(±x の側)に板を貼るときは yaw を 90 にします

    外から見える形だけを作ってください:
    - 作るのは、外から見える形(全体の輪郭、外壁、屋根、目立つ部品)だけです。内装・部屋・床・階段・中の設備・中の柱は作らないでください
    - ほかの形の中に完全に隠れる形は作らないでください(外から見えないため)
    - 形の数は、まず全体の輪郭(全体の高さと幅、くびれ、段・展望台・屋根の位置と大きさ)に割り当ててください。窓の並び・手すり・看板などの飾りは、輪郭ができてから、余った数で作ってください
    - 細かさが「とても細かい」のときは特に、増えた形の数を外形の正確さに使ってください(輪郭の段を増やして曲線や傾きをなめらかにする、各部の高さ・幅を実物に合わせる)。数を埋めるための形や、見えない所の形は作らないでください

    細かく作るときのコツ:
    - 実物の高さ・幅・比率を守る(全体の高さを先に決め、部分の大きさはその比で決める)
    - 上に行くほど細くなる・形が変わる物は、段ごとに幅を少しずつ変えた形を積んで、輪郭をなめらかにする
    - くり返す部分(鉄骨の段、窓の列、柵など)は、同じ形を少しずつ位置・大きさを変えて並べる
    - 色は部分ごとに分ける(屋根・壁・窓・柱など)。実物の色が分かれば、その色にする
    - 細い部材(鉄骨、アンテナ)は、細長い箱や円柱で表す。斜めの部材は pitch・roll で傾ける
    - 地面から浮かないように、いちばん下の形の z は 0 にする
    """

    static let searchPrompt = """

    Web 検索:
    - 実在の建物や物の依頼なら、作る前に web_search で調べてください(2回まで)。架空の物や一般的な物(「2階建ての家」など)では、検索しなくてかまいません
    - 調べるのは、外から見た形を作るための値だけです: 全体の高さ、各部の高さ(展望台・屋根・段の位置など)、幅や直径、断面の形、外壁や屋根の色。館内の案内・展示・歴史・営業時間などは調べず、検索の結果にあっても使わないでください
    - 検索の言葉には、建物や物の名前と、知りたいこと(高さ、直径、断面、色など)だけを使ってください
    - 調べたあとは、JSON の前に、作るときに使う寸法の短い一覧を <dimensions> と </dimensions> の間に、1行に1つ「項目: 値」の形で書いてください(20行まで。分からない値は書かない)。そのあと、この一覧の値に合わせて形を作り、JSON を返してください。一覧のほかに説明の文章は書かないでください
    - 一覧の書き方の例(東京スカイツリーの場合。ほかの物では、その物の値を書く):
    <dimensions>
    全高: 634m
    第1展望台の高さ: 350m
    第2展望台の高さ: 450m
    足元の断面: 三角形(1辺 約68m)
    </dimensions>
    """

    static func systemPrompt(webSearch: Bool) -> String {
        webSearch ? basePrompt + searchPrompt : basePrompt
    }

    static func messages(description: String, detail: ObjectDetail) -> [ClaudeMessage] {
        [.user("次のオブジェクトを作ってください。細かさ: \(detail.label)(形は\(detail.maxShapes)個まで。外から見える形を細かくするために使い、数を埋めるための形は作らないでください)\n\n"
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
            // 寸法の一覧は、作り直したときも1回目のものを使う(作り直しは検索しないので、一覧を書かないことがある)
            let dimensions = ObjectDimensions.parse(answer)
            if !dimensions.isEmpty { outcome.dimensions = dimensions }
            outcome.json = ToolGenerator.extractJSON(ObjectDimensions.removing(answer))
            switch ObjectCodec.parse(outcome.json, maxShapes: detail.maxShapes) {
            case .success(let object):
                outcome.object = object
                outcome.issues = []
                outcome.hiddenShapes = ObjectGeometry.hiddenShapeIndices(of: object)
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

/// 調べた寸法の一覧の1行(「全高: 634m」)
struct ObjectDimension: Codable, Equatable, Identifiable {
    var id: Int
    var label: String
    var value: String
}

/// Claude の答えの、JSON の前に書かせた寸法の一覧(<dimensions> と </dimensions> の間)を読む
enum ObjectDimensions {
    static let open = "<dimensions>"
    static let close = "</dimensions>"
    static let maxItems = 20
    static let maxLength = 80

    /// 一覧の部分の範囲(閉じる印がなければ、その後の最初の「{」の前まで)
    private static func range(in answer: String) -> (whole: Range<String.Index>, content: Range<String.Index>)? {
        guard let start = answer.range(of: open) else { return nil }
        if let end = answer.range(of: close, range: start.upperBound..<answer.endIndex) {
            return (start.lowerBound..<end.upperBound, start.upperBound..<end.lowerBound)
        }
        let stop = answer[start.upperBound...].firstIndex(of: "{") ?? answer.endIndex
        return (start.lowerBound..<stop, start.upperBound..<stop)
    }

    /// 一覧の行。行の頭の「-」「・」などは除き、最初の「:」(全角も)で項目と値に分ける。区切りがなければ、行全体を項目にする
    static func parse(_ answer: String) -> [ObjectDimension] {
        guard let found = range(in: answer) else { return [] }
        var items: [ObjectDimension] = []
        for raw in answer[found.content].split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "-・*•".contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard !line.isEmpty else { continue }
            let label: String
            let value: String
            if let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                label = line[..<colon].trimmingCharacters(in: .whitespaces)
                value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                label = line
                value = ""
            }
            guard !label.isEmpty else { continue }
            items.append(ObjectDimension(id: items.count, label: String(label.prefix(maxLength)), value: String(value.prefix(maxLength))))
            if items.count >= maxItems { break }
        }
        return items
    }

    /// 一覧の部分を除いた答え(JSON を取り出す前に除く。一覧に「{」があっても、JSON を取り違えないように)
    static func removing(_ answer: String) -> String {
        guard let found = range(in: answer) else { return answer }
        var text = answer
        text.removeSubrange(found.whole)
        return text
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

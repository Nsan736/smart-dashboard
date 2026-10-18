import CoreGraphics
import Foundation

/// 撮った方向にあるもの(スコープで計算した、登録した地点・周辺の施設・経路・電車)
struct ScopeAskTarget: Equatable {
    var name: String
    /// 「登録した地点」「周辺の施設」など
    var kind: String
    var bearing: Double
    var distance: Double
    var heightDifference: Double?
}

/// 「撮って聞く」を押した瞬間の状況。画像以外は、送る前に設定で選んだものだけを文章にする。
/// 緯度経度は、送らない設定でも端末の中に持ち、答えの場所と撮った方向の照合に使う(外には送らない)。
struct ScopeAskSnapshot {
    var image: CGImage
    /// カメラの向き(真北からの方位、度)
    var heading: Double?
    /// カメラの上下の向き(水平で0、上が正、度)
    var pitch: Double?
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var targets: [ScopeAskTarget]
    var takenAt: Date
    /// 画面に写る範囲の左右の半分(度)。答えの場所が写る範囲の中かを確かめるのに使う。
    var halfFieldOfView: Double? = nil
}

/// 一緒に送る情報の選択(設定から)。初期値は、居場所が分からないもの(方角と端末の向き)だけ。
struct ScopeAskOptions: Equatable {
    var heading = true
    var place = false
    var coordinates = false
    var targets = false

    init(heading: Bool = true, place: Bool = false, coordinates: Bool = false, targets: Bool = false) {
        self.heading = heading
        self.place = place
        self.coordinates = coordinates
        self.targets = targets
    }

    init(_ settings: ClaudeSettings) {
        self.init(heading: settings.sendsHeading, place: settings.sendsPlace, coordinates: settings.sendsCoordinates,
                  targets: settings.sendsTargets)
    }
}

/// 1回の質問と答え
struct ScopeAskExchange: Identifiable, Equatable {
    let id = UUID()
    var question: String
    var answer: String?
    var error: String?
    var usage: ClaudeUsage?
    var cost: Double?
    /// 答えに使った Web 検索の出典
    var citations: [ClaudeCitation] = []
    /// 答えで特定した場所(決まった形で返ってきたもの)
    var place: ScopeAskPlace?
    /// 今回送ったもの(「画像・質問・方角と向き」)
    var sentSummary = ""
    /// 補足(Web 検索が使えなかった、など)
    var note: String?
}

enum ScopeAsk {
    static let defaultQuestion = "これは何ですか？"
    static let presets = ["これは何？", "何の建物？", "何という山？", "文字を読んで"]
    /// 続けて質問するとき、送り直すのは直近のやり取りだけ
    static let keptExchanges = 3
    static let maxTokens = 8_000
    /// 一緒に送る、撮った方向にあるものの数
    static let maxTargets = 15
    /// pause_turn(検索が長くかかって、途中で返ってきた)の続きを頼む回数の上限
    static let maxContinuations = 3

    /// system prompt。Web 検索を使うかどうかで、検索の決まりを足す。
    static func systemPrompt(webSearch: Bool, maxSearches: Int) -> String {
        var text = """
        あなたは、利用者がスマートフォンのカメラで撮った画像について、日本語で答える係です。画像に写っているものから見つけることを基本にしてください。

        答え方:
        - 画像から確かに分かること と、推測(画像以外の手がかりや一般的な知識からの見当)を、はっきり分けて書いてください。見出しは「画像から分かること」「推測」とし、推測には根拠を添えてください。
        - 分からないときは、無理に答えず「分からない」と答えてください。見当が付く場合でも、確かでないことは推測の側に書いてください。
        - 利用者のメッセージに「撮影の状況」(方角、端末の向き、利用者が送ることを選んだ場合は、おおよその現在地や周りの地点)が付くことがあります。アプリが端末のセンサーと保存データから付けた参考情報で、画像の中身そのものではありません。画像と食い違うときは画像を優先し、参考情報から言えることは推測として扱ってください。
        - 写っている人物がだれかは答えないでください。
        - 簡潔に答えてください(長くても300字程度)。文字を読む依頼のときは、読めた文字をそのまま書き、読めない部分は「(判読できない)」としてください。
        """
        if webSearch {
            text += """


            Web 検索:
            - 画像だけで分からないときや、名前を確かめたいときだけ、Web 検索を使ってください(1回の質問で\(maxSearches)回まで)。
            - 検索の言葉は、写っているものの特徴(形、色、文字、看板の名前、建物の様式など)から作ってください。利用者の現在地・地名・住所・緯度経度を、検索の言葉に入れないでください(撮影の状況に地名が含まれていても使わないでください)。
            - 検索で分かったことは、推測の側に書き、出典が分かるようにしてください。
            """
        }
        text += """


        場所の特定:
        - 答えの最後に、写っているものの場所を、次の決まった形で1つだけ書いてください。この部分は利用者には表示されず、アプリが読み取ります。
        - 特定の建物・山・施設などで、場所を特定できたとき: <place>{"identified": true, "name": "名前", "latitude": 緯度, "longitude": 経度, "confidence": "high", "reason": "根拠"}</place>
        - confidence は、確かなら high、たぶんなら medium、見当なら low にしてください。緯度経度は、写っているもの(建物・山頂など)の位置で、撮った人の位置ではありません。
        - 場所を特定できないとき(ありふれた物、室内、どこにでもある景色など)は、座標を作らずに: <place>{"identified": false, "reason": "特定できない理由"}</place>
        """
        return text
    }

    /// 送る質問の文(空なら「これは何ですか？」)
    static func question(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultQuestion : trimmed
    }

    /// 一緒に送る情報の文。選んだものだけを入れる。
    static func contextText(_ snapshot: ScopeAskSnapshot, options: ScopeAskOptions) -> String {
        var lines: [String] = []
        if options.heading, let heading = snapshot.heading {
            var line = "- 撮った方角: \(WaypointMath.compassPoint(heading))(\(Int(heading.rounded()))°)"
            if let pitch = snapshot.pitch {
                let degrees = Int(pitch.rounded())
                line += "。端末の向き: " + (abs(degrees) < 3 ? "ほぼ水平" : "水平より\(abs(degrees))°\(degrees > 0 ? "上向き" : "下向き")")
            }
            lines.append(line)
        }
        if options.place {
            var parts: [String] = []
            if let name = snapshot.placeName { parts.append(name) }
            if options.coordinates, let latitude = snapshot.latitude, let longitude = snapshot.longitude {
                parts.append(String(format: "緯度%.3f、経度%.3f", latitude, longitude))
            }
            if !parts.isEmpty { lines.append("- おおよその現在地: " + parts.joined(separator: "。")) }
        }
        if options.targets, !snapshot.targets.isEmpty {
            lines.append("- 撮った方向(画面に写る範囲)にあるもの。名前と、ここからの距離はアプリの保存データから計算したもので、画像に写っているとは限りません:")
            for target in snapshot.targets.sorted(by: { $0.distance < $1.distance }).prefix(maxTargets) {
                var line = "  - \(target.name)(\(target.kind))方角\(Int(target.bearing.rounded()))°、\(WaypointMath.distanceText(target.distance))"
                if let difference = target.heightDifference { line += "、高低差 " + WaypointMath.heightText(difference) }
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { return "撮影の状況: 送っていません(画像だけで答えてください)。" }
        return "撮影の状況(参考情報。画像の中身ではありません):\n" + lines.joined(separator: "\n")
    }

    /// 今回送るもの(画面の下に出す)。実際に文に入ったものだけ。
    static func sentItems(_ snapshot: ScopeAskSnapshot, options: ScopeAskOptions) -> [String] {
        var items = ["画像", "質問"]
        if options.heading, snapshot.heading != nil { items.append("方角と向き") }
        if options.place {
            if snapshot.placeName != nil { items.append("地名") }
            if options.coordinates, snapshot.latitude != nil, snapshot.longitude != nil { items.append("緯度経度") }
        }
        if options.targets, !snapshot.targets.isEmpty { items.append("周りの地点の名前と距離") }
        return items
    }

    static func sentSummary(_ items: [String]) -> String {
        items.joined(separator: "・") + "を送信"
    }

    /// 送るメッセージ。画像と撮影の状況は最初のメッセージに入れ、そこまでをプロンプトキャッシュに入れる
    /// (続けて質問するときは、そこまでが毎回同じになる)。やり取りは直近 keptExchanges 回だけ。
    static func messages(jpeg: Data, context: String, history: [ScopeAskExchange], question: String) -> [ClaudeMessage] {
        let answered = history.filter { $0.answer != nil }.suffix(keptExchanges)
        let questions = answered.map(\.question) + [question]
        let answers = answered.compactMap(\.answer)
        var messages = [ClaudeMessage(role: .user, content: [.jpeg(jpeg), .text(context, cached: true), .text(questions[0])])]
        for (index, answer) in answers.enumerated() {
            messages.append(.assistant(answer))
            messages.append(.user(questions[index + 1]))
        }
        return messages
    }

    static func request(messages: [ClaudeMessage], settings: ClaudeSettings, webSearch: Bool? = nil) -> ClaudeRequest {
        let usesSearch = webSearch ?? settings.webSearch
        return ClaudeRequest(model: settings.model, system: systemPrompt(webSearch: usesSearch, maxSearches: settings.webSearchMaxUses),
                             cachesSystem: false, messages: messages, maxTokens: maxTokens, thinking: settings.thinkingForCamera,
                             webSearchMaxUses: usesSearch ? settings.webSearchMaxUses : nil)
    }

    /// 1回の質問の結果(pause_turn の続きをつなげたもの)
    struct Answer: Equatable {
        var response: ClaudeResponse
        var cost: Double
        /// Web 検索を使う依頼が受け付けられず、検索なしで聞き直した
        var searchFallback = false
    }

    /// 聞く。pause_turn なら、受け取った内容をそのまま送り返して続きを頼む(上限 maxContinuations 回)。
    /// Web 検索を付けた依頼が HTTP 400 になったら(このモデルや組織で使えないなど)、検索なしで1回だけ聞き直す。
    static func ask(_ request: ClaudeRequest, call: (ClaudeRequest) async throws -> ClaudeCallResult) async throws -> Answer {
        do {
            return try await continueTurns(request, call: call)
        } catch let error as ClaudeError {
            guard case .badRequest = error, request.webSearchMaxUses != nil else { throw error }
            var plain = request
            plain.webSearchMaxUses = nil
            plain.system = systemPrompt(webSearch: false, maxSearches: 0)
            var answer = try await continueTurns(plain, call: call)
            answer.searchFallback = true
            return answer
        }
    }

    private static func continueTurns(_ request: ClaudeRequest, call: (ClaudeRequest) async throws -> ClaudeCallResult) async throws -> Answer {
        var current = request
        let first = try await call(current)
        var response = first.response
        var cost = first.cost
        var last = first.response
        var continuations = 0
        while last.stopReason == "pause_turn", continuations < maxContinuations {
            continuations += 1
            current.messages.append(ClaudeMessage(role: .assistant, content: last.rawContent.map { .raw($0) }))
            let next = try await call(current)
            response = response.appending(next.response)
            cost += next.cost
            last = next.response
        }
        return Answer(response: response, cost: cost)
    }
}

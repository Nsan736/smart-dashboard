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
}

/// 一緒に送る情報の選択(設定から)
struct ScopeAskOptions: Equatable {
    var heading = true
    var place = true
    var coordinates = true
    var targets = true

    init(heading: Bool = true, place: Bool = true, coordinates: Bool = true, targets: Bool = true) {
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
}

enum ScopeAsk {
    static let defaultQuestion = "これは何ですか？"
    static let presets = ["これは何？", "何の建物？", "何という山？", "文字を読んで"]
    /// 続けて質問するとき、送り直すのは直近のやり取りだけ
    static let keptExchanges = 3
    static let maxTokens = 8_000
    /// 一緒に送る、撮った方向にあるものの数
    static let maxTargets = 15

    static let systemPrompt = """
    あなたは、利用者がスマートフォンのカメラで撮った画像について、日本語で答える係です。

    答え方:
    - 画像から確かに分かること と、推測(画像以外の手がかりや一般的な知識からの見当)を、はっきり分けて書いてください。見出しは「画像から分かること」「推測」とし、推測には根拠を添えてください。
    - 分からないときは、無理に答えず「分からない」と答えてください。見当が付く場合でも、確かでないことは推測の側に書いてください。
    - 利用者のメッセージに付く「撮影の状況」(方角、端末の向き、おおよその現在地、撮った方向にある登録した地点や施設の名前と距離)は、アプリが端末のセンサーと保存データから付けた参考情報です。画像の中身そのものではありません。名前を答えるときの手がかりには使ってよいですが、画像と食い違うときは画像を優先し、参考情報から言えることは推測として扱ってください。
    - 写っている人物がだれかは答えないでください。
    - 簡潔に答えてください(長くても300字程度)。文字を読む依頼のときは、読めた文字をそのまま書き、読めない部分は「(判読できない)」としてください。
    """

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

    static func request(messages: [ClaudeMessage], settings: ClaudeSettings) -> ClaudeRequest {
        ClaudeRequest(model: settings.model, system: systemPrompt, cachesSystem: false, messages: messages,
                      maxTokens: maxTokens, thinking: settings.thinkingForCamera)
    }
}

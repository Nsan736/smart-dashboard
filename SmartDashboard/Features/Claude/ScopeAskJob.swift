import CoreGraphics
import Foundation
import ImageIO
import Observation

/// 「撮って聞く」の記録(最近聞いたこと)。画像は縮めたもの(長い辺 480px の JPEG)だけを保存する
struct ScopeAskRecord: ClaudeRecentEntry {
    static let thumbnailEdge = 480

    var id = UUID()
    var createdAt: Date
    var thumbnail: Data
    var heading: Double?
    var pitch: Double?
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var halfFieldOfView: Double?
    var exchanges: [ScopeAskExchange]

    /// 料金の合計(概算)
    var cost: Double { exchanges.compactMap(\.cost).reduce(0, +) }
    var firstQuestion: String { exchanges.first?.question ?? "" }

    /// 保存した画像を読む
    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// 今の「撮って聞く」の会話(画面で開いているもの、または裏で答えを待っているもの)
struct ScopeAskLive {
    var recordID: UUID
    var createdAt: Date
    var snapshot: ScopeAskSnapshot
    /// 最近聞いたことから開き直した(画像は縮めたもの)
    var isRestored: Bool
    var thumbnail: Data?
    /// 確定した囲み(画像のピクセル)。なければ画像全体を送る
    var shape: [CGPoint]?
    /// 送った画像(続けて質問するときも同じものを送る)。囲みを変えたら作り直す
    var jpeg: Data?
    var exchanges: [ScopeAskExchange] = []

    var record: ScopeAskRecord? {
        guard let thumbnail, !exchanges.isEmpty else { return nil }
        return ScopeAskRecord(id: recordID, createdAt: createdAt, thumbnail: thumbnail, heading: snapshot.heading, pitch: snapshot.pitch,
                              latitude: snapshot.latitude, longitude: snapshot.longitude, placeName: snapshot.placeName,
                              halfFieldOfView: snapshot.halfFieldOfView, exchanges: exchanges)
    }
}

/// 「撮って聞く」の作業。画面を閉じても答えを待ち続け、会話は「最近聞いたこと」に残す
@MainActor
@Observable
final class ScopeAskJob {
    private(set) var live: ScopeAskLive?
    private(set) var isThinking = false
    /// 画面を閉じている間に答えが届いた(帯の「答えが届きました」)
    private(set) var hasUnseenAnswer = false
    var isShowing = false {
        didSet { if isShowing { hasUnseenAnswer = false } }
    }
    let recents: ClaudeRecents<ScopeAskRecord>

    @ObservationIgnored private var task: Task<Void, Never>?

    init(fileURL: URL = ClaudeRecentList.fileURL("scope-ask.json")) {
        recents = ClaudeRecents(fileURL: fileURL)
    }

    /// 撮った画像で、新しい会話を始める
    func begin(_ snapshot: ScopeAskSnapshot, now: Date = Date()) {
        let thumbnail = ScopeAskImage.prepare(snapshot.image, shape: nil, maxEdge: ScopeAskRecord.thumbnailEdge)
        live = ScopeAskLive(recordID: UUID(), createdAt: now, snapshot: snapshot, isRestored: false, thumbnail: thumbnail)
        hasUnseenAnswer = false
    }

    /// 最近聞いたことから開き直す(画像は縮めたもの。続けて質問すると、その画像を送る)
    func open(_ record: ScopeAskRecord) {
        guard let image = ScopeAskRecord.image(record.thumbnail) else { return }
        let snapshot = ScopeAskSnapshot(image: image, heading: record.heading, pitch: record.pitch, latitude: record.latitude,
                                        longitude: record.longitude, placeName: record.placeName, targets: [], takenAt: record.createdAt,
                                        halfFieldOfView: record.halfFieldOfView)
        live = ScopeAskLive(recordID: record.id, createdAt: record.createdAt, snapshot: snapshot, isRestored: true,
                            thumbnail: record.thumbnail, exchanges: record.exchanges)
    }

    func setPlaceName(_ name: String?) {
        live?.snapshot.placeName = name
    }

    /// 囲みを変える。画像が変わるので、前のやり取りは続けない(前の会話は「最近聞いたこと」に残る)。返り値は知らせる文
    @discardableResult
    func setShape(_ shape: [CGPoint]?) -> String? {
        guard var current = live, !isThinking else { return nil }
        current.shape = shape
        var notice: String?
        if current.jpeg != nil {
            current.jpeg = nil
            if !current.exchanges.isEmpty {
                // 新しい画像として、別の会話にする
                current.exchanges = []
                current.recordID = UUID()
                current.createdAt = Date()
                notice = "囲みを変えたので、新しい画像として聞きます"
            }
        }
        live = current
        return notice
    }

    /// 質問を送る。call は Claude を呼ぶ部分(本番は ClaudeService.call)
    func send(question: String, settings: ClaudeSettings, imageEdge: Int, blockReason: String?,
              call: @escaping (ClaudeRequest) async throws -> ClaudeCallResult) {
        guard var current = live, !isThinking else { return }
        if let blockReason {
            current.exchanges.append(ScopeAskExchange(question: question, error: blockReason))
            live = current
            return
        }
        if current.jpeg == nil {
            current.jpeg = ScopeAskImage.prepare(current.snapshot.image, shape: current.shape, maxEdge: imageEdge)
        }
        guard let jpeg = current.jpeg else {
            current.exchanges.append(ScopeAskExchange(question: question, error: "画像を用意できませんでした"))
            live = current
            return
        }
        let options = ScopeAskOptions(settings)
        let context = ScopeAsk.contextText(current.snapshot, options: options)
        let messages = ScopeAsk.messages(jpeg: jpeg, context: context, history: current.exchanges, question: question)
        let request = ScopeAsk.request(messages: messages, settings: settings)
        var pending = ScopeAskExchange(question: question)
        pending.sentSummary = ScopeAsk.sentSummary(ScopeAsk.sentItems(current.snapshot, options: options))
        let exchange = pending
        current.exchanges.append(exchange)
        live = current
        persist()
        let recordID = current.recordID
        isThinking = true
        let maxUses = settings.webSearchMaxUses
        // この入れ物はアプリの間ずっとある(AppEnvironment)ので、self を強く持ってよい
        task = Task {
            var updated = exchange
            do {
                let result = try await ScopeAsk.ask(request, call: call)
                updated = Self.answered(exchange, result: result, maxUses: maxUses)
            } catch is CancellationError {
                updated.error = "中止しました"
            } catch {
                updated.error = error.localizedDescription
            }
            apply(updated, recordID: recordID)
            isThinking = false
            if !isShowing { hasUnseenAnswer = true }
            task = nil
        }
    }

    /// 答えを、やり取りに入れる
    nonisolated static func answered(_ exchange: ScopeAskExchange, result: ScopeAsk.Answer, maxUses: Int) -> ScopeAskExchange {
        var updated = exchange
        updated.usage = result.response.usage
        updated.cost = result.cost
        updated.citations = result.response.citations
        var notes: [String] = []
        if result.searchFallback { notes.append("Web 検索を使う依頼が受け付けられなかったため、検索なしで答えています") }
        if result.response.searchErrors.contains("max_uses_exceeded") { notes.append("Web 検索の上限(\(maxUses)回)に達しました") }
        if result.response.stopReason == "pause_turn" { notes.append("検索に時間がかかったため、途中までの答えです") }
        updated.note = notes.isEmpty ? nil : notes.joined(separator: "。")
        let extracted = ScopeAskPlace.extract(from: result.response.text)
        updated.place = extracted.place
        if extracted.answer.isEmpty {
            updated.error = ClaudeError.emptyAnswer(stopReason: result.response.stopReason).localizedDescription
        } else {
            updated.answer = extracted.answer
        }
        return updated
    }

    /// 届いた答えを入れる。画面の会話が変わっていても(新しく撮った、など)、その会話の記録に入れる
    func apply(_ exchange: ScopeAskExchange, recordID: UUID) {
        if var current = live, current.recordID == recordID, let index = current.exchanges.firstIndex(where: { $0.id == exchange.id }) {
            current.exchanges[index] = exchange
            live = current
            persist()
        } else if var record = recents.entry(recordID), let index = record.exchanges.firstIndex(where: { $0.id == exchange.id }) {
            record.exchanges[index] = exchange
            recents.upsert(record)
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 今の会話を捨てる(最近聞いたことからも消す)
    func discardCurrent() {
        guard let current = live else { return }
        if isThinking { task?.cancel() }
        recents.remove(current.recordID)
        live = nil
    }

    func remove(_ id: UUID) {
        recents.remove(id)
        if live?.recordID == id, !isThinking { live = nil }
    }

    private func persist() {
        guard let record = live?.record else { return }
        recents.upsert(record)
    }
}

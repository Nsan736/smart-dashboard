import CoreGraphics
import Foundation
import Observation

/// 文章から作ったオブジェクトの「最近作ったもの」の1件(保存する前の結果。確認の画面を開き直せる)
struct ObjectComposeRecord: ClaudeRecentEntry {
    var id = UUID()
    var createdAt: Date
    var instruction: String
    /// ObjectDetail の rawValue
    var detail: String
    var webSearch: Bool
    /// 返ってきた JSON(検証を通ったか、最後の誤りのあるもの)
    var json: String
    var issues: [ToolIssue]
    var usage: ClaudeUsage
    var cost: Double
    var attempts: Int
    var searchFallback: Bool
    var citations: [ClaudeCitation]
    var searchErrors: [String]
    var dimensions: [ObjectDimension]
    var hiddenShapes: [Int]
    /// オブジェクトの一覧に保存した日時
    var savedAt: Date?
    /// 写真から作ったときの写真の枚数と、入力した寸法(文章から作ったときは nil。写真は保存しない)
    var photoCount: Int?
    var inputDimensions: String?

    init(outcome: ObjectGenerator.Outcome, instruction: String, webSearch: Bool, createdAt: Date = Date(),
         photoCount: Int? = nil, inputDimensions: String? = nil) {
        self.createdAt = createdAt
        self.photoCount = photoCount
        self.inputDimensions = inputDimensions
        self.instruction = instruction
        detail = outcome.detail.rawValue
        self.webSearch = webSearch
        json = outcome.json
        issues = outcome.issues
        usage = outcome.usage
        cost = outcome.cost
        attempts = outcome.attempts
        searchFallback = outcome.searchFallback
        citations = outcome.citations
        searchErrors = outcome.searchErrors
        dimensions = outcome.dimensions
        hiddenShapes = outcome.hiddenShapes
    }

    var objectDetail: ObjectDetail { ObjectDetail(rawValue: detail) ?? .initial }

    /// 確認の画面に出す結果(JSON を読み直す。誤りが残っていたものは、オブジェクトなし)
    var outcome: ObjectGenerator.Outcome {
        var outcome = ObjectGenerator.Outcome(object: nil, json: json, issues: issues, usage: usage, cost: cost, attempts: attempts,
                                              detail: objectDetail)
        outcome.searchFallback = searchFallback
        outcome.citations = citations
        outcome.searchErrors = searchErrors
        outcome.dimensions = dimensions
        outcome.hiddenShapes = hiddenShapes
        if issues.isEmpty, case .success(let object) = ObjectCodec.parse(json, maxShapes: objectDetail.maxShapes) {
            outcome.object = object
        }
        return outcome
    }
}

/// 文章からオブジェクトを作る作業。画面を閉じても作るのは続け(アプリの中で)、結果は「最近作ったもの」に残す。
/// 「撮って聞く」で撮って囲んだあとに選ぶもの(v0.9.31): 聞く(下の質問の欄へ)か、オブジェクトを作る(写真から作る画面へ。写真は3枚まで)
enum ScopeAskUse {
    enum Kind: Hashable {
        case ask
        case makeObject
    }

    struct Choice: Equatable {
        var kind: Kind
        var label: String
        var isEnabled: Bool
    }

    /// 出すボタン。前回の続き(保存してあった画像)では出さない。作っている途中と、写真が3枚あるときは「オブジェクト」を押せない
    static func choices(isRestored: Bool, photoCount: Int, isComposing: Bool) -> [Choice] {
        guard !isRestored else { return [] }
        let max = ObjectPhotoImage.maxPhotos
        let label = photoCount == 0 ? "オブジェクトを作る" : "オブジェクトの写真に足す(\(min(photoCount + 1, max))/\(max))"
        return [
            Choice(kind: .ask, label: "聞く", isEnabled: true),
            Choice(kind: .makeObject, label: label, isEnabled: photoCount < max && !isComposing),
        ]
    }

    /// 「オブジェクトを作る」を選んだ: 写真を足して、作る画面を開く印を付ける。足せなければ false(聞く画面は閉じない)
    @MainActor
    static func useForObject(compose: ObjectComposeJob, image: CGImage, shape: [CGPoint]?) -> Bool {
        guard !compose.isRunning else { return false }
        return compose.addCapturedPhoto(image, shape: shape)
    }
}

/// 入力した文・細かさ・検索のオンとオフも残す(作る画面に戻ったときに、そのまま入っている)
@MainActor
@Observable
final class ObjectComposeJob {
    static let draftKey = "objects.composeDraft"
    static let detailKey = "objects.composeDetail2"
    static let searchKey = "objects.composeSearch2"
    static let photoKey = "objects.photoDraft"

    var instruction: String {
        didSet { defaults.set(instruction, forKey: Self.draftKey) }
    }
    var detailRaw: String {
        didSet { defaults.set(detailRaw, forKey: Self.detailKey) }
    }
    var webSearch: Bool {
        didSet { defaults.set(webSearch, forKey: Self.searchKey) }
    }
    /// 写真から作る(v0.9.30): 選んだ写真(端末には保存しない)と、分かっている寸法・説明(残す)
    private(set) var photos: [ObjectPhotoDraft] = []
    /// スコープのカメラ表示で、オブジェクトの写真を撮り足している間(v0.9.31。カメラ表示に帯を出す)
    var isCollectingPhotos = false
    /// 「撮って聞く」で「オブジェクトを作る」を選んだ(聞く画面を閉じたら、カメラ表示が作る画面を出す)
    var opensPhotoComposer = false
    var photoHeight = "" { didSet { savePhotoDraft() } }
    var photoWidth = "" { didSet { savePhotoDraft() } }
    var photoDepth = "" { didSet { savePhotoDraft() } }
    var photoNote = "" { didSet { savePhotoDraft() } }
    private(set) var isRunning = false
    private(set) var progress = ObjectGenerationProgress()
    private(set) var errorText: String?
    /// 作り終わって、まだ確認していない結果(帯の「できました」)
    private(set) var unseenID: UUID?
    /// 作る画面で開いている結果
    var viewingID: UUID?
    /// 作る画面を開いているか(開いている間にできた結果は、すぐ見たことにする)
    var isShowing = false {
        didSet { if isShowing, unseenID != nil { viewingID = unseenID; unseenID = nil } }
    }
    let recents: ClaudeRecents<ObjectComposeRecord>

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, fileURL: URL = ClaudeRecentList.fileURL("objects.json")) {
        self.defaults = defaults
        instruction = defaults.string(forKey: Self.draftKey) ?? ""
        detailRaw = defaults.string(forKey: Self.detailKey) ?? ObjectDetail.initial.rawValue
        webSearch = defaults.object(forKey: Self.searchKey) as? Bool ?? false
        recents = ClaudeRecents(fileURL: fileURL)
        let draft = defaults.stringArray(forKey: Self.photoKey) ?? []
        if draft.count == 4 {
            photoHeight = draft[0]
            photoWidth = draft[1]
            photoDepth = draft[2]
            photoNote = draft[3]
        }
    }

    var detail: ObjectDetail { ObjectDetail(rawValue: detailRaw) ?? .initial }

    private func savePhotoDraft() {
        defaults.set([photoHeight, photoWidth, photoDepth, photoNote], forKey: Self.photoKey)
    }

    func addPhoto(_ image: CGImage, shape: [CGPoint]? = nil) {
        guard photos.count < ObjectPhotoImage.maxPhotos else { return }
        photos.append(ObjectPhotoDraft(image: image, shape: shape))
    }

    var canAddPhoto: Bool { photos.count < ObjectPhotoImage.maxPhotos }

    /// 「撮って聞く」で撮って囲んだ写真を、オブジェクトの写真にする(作る画面を出す)
    /// 足せたら true(3枚あるときは足さず、作る画面も開かない)
    @discardableResult
    func addCapturedPhoto(_ image: CGImage, shape: [CGPoint]?) -> Bool {
        guard canAddPhoto else { return false }
        addPhoto(image, shape: shape)
        isCollectingPhotos = true
        opensPhotoComposer = true
        return true
    }

    func removePhoto(_ id: UUID) {
        photos.removeAll { $0.id == id }
    }

    func setShape(_ shape: [CGPoint]?, for id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].shape = shape
    }

    /// Claude に送る寸法の文
    var photoDimensionsText: String {
        ObjectPhotoImage.dimensionsText(height: photoHeight, width: photoWidth, depth: photoDepth)
    }

    /// 写真から作る料金の目安
    var photoEstimatedCost: Double {
        ObjectGenerator.estimatedPhotoCost(detail: detail, imageSizes: photos.map { ObjectPhotoImage.sentSize($0.image, shape: $0.shape) })
    }

    /// 写真から作り始める(Web 検索は使わない)
    func startPhotos(model: String, thinking: Bool,
                     call: @escaping (ClaudeRequest, @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ClaudeCallResult) {
        guard !isRunning, !photos.isEmpty else { return }
        let images = photos.compactMap { ObjectPhotoImage.prepare($0.image, shape: $0.shape) }
        guard images.count == photos.count else {
            errorText = "写真を用意できませんでした"
            return
        }
        errorText = nil
        viewingID = nil
        progress = ObjectGenerationProgress()
        isRunning = true
        isCollectingPhotos = false
        let detail = detail
        let note = photoNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let dimensions = photoDimensionsText
        let count = images.count
        // この入れ物はアプリの間ずっとある(AppEnvironment)ので、self を強く持ってよい
        task = Task {
            do {
                let outcome = try await ObjectGenerator.runPhotos(images: images, description: note, dimensions: dimensions, detail: detail,
                                                                  model: model, thinking: thinking) { request in
                    try await call(request) { event in
                        Task { @MainActor in self.progress.apply(event) }
                    }
                }
                finish(ObjectComposeRecord(outcome: outcome, instruction: note.isEmpty ? "写真から作成" : note, webSearch: false,
                                           photoCount: count, inputDimensions: dimensions.isEmpty ? nil : dimensions))
            } catch is CancellationError {
                errorText = "中止しました(Claude 側で処理が進んでいた分は、料金がかかることがあります)"
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
            task = nil
        }
    }

    /// 作り始める。call は Claude を呼ぶ部分(本番はストリーミング)。終わったら「最近作ったもの」に入れる
    func start(model: String, thinking: Bool,
               call: @escaping (ClaudeRequest, @escaping @Sendable (ClaudeStreamEvent) -> Void) async throws -> ClaudeCallResult) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty else { return }
        errorText = nil
        viewingID = nil
        progress = ObjectGenerationProgress()
        isRunning = true
        let detail = detail
        let webSearch = webSearch
        // この入れ物はアプリの間ずっとある(AppEnvironment)ので、self を強く持ってよい
        task = Task {
            do {
                let outcome = try await ObjectGenerator.run(description: text, detail: detail, webSearch: webSearch, model: model,
                                                            thinking: thinking) { request in
                    try await call(request) { event in
                        Task { @MainActor in self.progress.apply(event) }
                    }
                }
                finish(ObjectComposeRecord(outcome: outcome, instruction: text, webSearch: webSearch))
            } catch is CancellationError {
                errorText = "中止しました(Claude 側で処理が進んでいた分は、料金がかかることがあります)"
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
            task = nil
        }
    }

    func finish(_ record: ObjectComposeRecord) {
        recents.upsert(record)
        viewingID = record.id
        unseenID = isShowing ? nil : record.id
    }

    /// 呼ぶ前に止まったとき(APIキーがない、上限に達した、など)
    func reportBlocked(_ text: String) {
        errorText = text
    }

    /// 作るのを途中でやめる
    func cancel() {
        task?.cancel()
    }

    /// 結果を開く(帯の「できました」は消える)
    func open(_ id: UUID) {
        viewingID = id
        if unseenID == id { unseenID = nil }
    }

    func markSaved(_ id: UUID) {
        guard var record = recents.entry(id) else { return }
        record.savedAt = Date()
        recents.upsert(record)
    }

    /// 捨てる(一覧からも消す)
    func discard(_ id: UUID) {
        recents.remove(id)
        if viewingID == id { viewingID = nil }
        if unseenID == id { unseenID = nil }
    }

    /// 作り直す(その結果の文と設定を、入力に戻す)
    func restoreInput(from record: ObjectComposeRecord) {
        detailRaw = record.detail
        if record.photoCount != nil {
            // 写真は保存していないので、今選んでいる写真で作り直す
            photoNote = record.instruction == "写真から作成" ? "" : record.instruction
            return
        }
        instruction = record.instruction
        webSearch = record.webSearch
    }
}

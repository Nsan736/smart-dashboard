import Foundation
import Observation

/// 小ツールを文章から作るか、今のツールを文章で直すか
enum ToolComposeMode: Equatable {
    case create
    /// 今のツールを直す(今の JSON と、もとのツールの ID)
    case revise(json: String, id: String)

    /// 入力の文を分けて覚えるための名前(作る / 直すツールごと)
    var draftKey: String {
        switch self {
        case .create: return "create"
        case .revise(_, let id): return "revise." + id
        }
    }
}

/// 小ツールを文章から作った結果の「最近作ったもの」の1件
struct ToolComposeRecord: ClaudeRecentEntry {
    var id = UUID()
    var createdAt: Date
    var instruction: String
    /// 直したときの、もとのツールの ID と JSON(作ったときは nil)
    var reviseID: String?
    var reviseJSON: String?
    var json: String
    var isValid: Bool
    var toolName: String?
    var kindLabel: String?
    var issues: [ToolIssue]
    var usage: ClaudeUsage
    var cost: Double
    var attempts: Int
    var savedAt: Date?

    init(generation: ToolGeneration, instruction: String, mode: ToolComposeMode, createdAt: Date = Date()) {
        self.createdAt = createdAt
        self.instruction = instruction
        if case .revise(let json, let id) = mode {
            reviseID = id
            reviseJSON = json
        }
        switch generation.outcome {
        case .valid(let json, let tool):
            self.json = json
            isValid = true
            toolName = tool.name
            kindLabel = tool.kind.label
            issues = []
        case .invalid(let json, let issues):
            self.json = json
            isValid = false
            self.issues = issues
        }
        usage = generation.usage
        cost = generation.cost
        attempts = generation.attempts
    }

    var mode: ToolComposeMode {
        if let reviseID { return .revise(json: reviseJSON ?? "", id: reviseID) }
        return .create
    }

    /// 検証を通ったツール(読み直す)
    var tool: CustomTool? {
        guard isValid, case .success(let tool) = CustomToolParser.parse(json) else { return nil }
        return tool
    }
}

/// 小ツールを文章から作る・直す作業。画面を閉じても作るのは続け、結果は「最近作ったもの」に残す。
/// 入力した文は、作る / 直すツールごとに残す
@MainActor
@Observable
final class ToolComposeJob {
    static let draftsKey = "tools.composeDrafts"

    private(set) var mode: ToolComposeMode = .create
    private var drafts: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(drafts) { defaults.set(data, forKey: Self.draftsKey) }
        }
    }
    private(set) var isRunning = false
    private(set) var errorText: String?
    private(set) var unseenID: UUID?
    var viewingID: UUID?
    var isShowing = false {
        didSet { if isShowing, unseenID != nil { viewingID = unseenID; unseenID = nil } }
    }
    let recents: ClaudeRecents<ToolComposeRecord>

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, fileURL: URL = ClaudeRecentList.fileURL("tools.json")) {
        self.defaults = defaults
        drafts = defaults.data(forKey: Self.draftsKey).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        recents = ClaudeRecents(fileURL: fileURL)
    }

    var instruction: String {
        get { drafts[mode.draftKey] ?? "" }
        set { drafts[mode.draftKey] = newValue.isEmpty ? nil : newValue }
    }

    var isRevising: Bool {
        if case .revise = mode { return true }
        return false
    }

    /// 作る画面を開いたとき。作っている間は、今の作業のまま
    func prepare(_ mode: ToolComposeMode) {
        guard !isRunning else { return }
        self.mode = mode
    }

    func start(model: String, thinking: Bool, validate: @escaping (CustomTool) async -> [ToolIssue],
               call: @escaping (ClaudeRequest) async throws -> ClaudeCallResult) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !text.isEmpty else { return }
        errorText = nil
        viewingID = nil
        isRunning = true
        let mode = mode
        let messages: [ClaudeMessage]
        switch mode {
        case .create: messages = ToolGenerator.createMessages(description: text)
        case .revise(let json, _): messages = ToolGenerator.reviseMessages(currentJSON: json, instruction: text)
        }
        // この入れ物はアプリの間ずっとある(AppEnvironment)ので、self を強く持ってよい
        task = Task {
            do {
                let generation = try await ToolGenerator.run(messages: messages, model: model, thinking: thinking,
                                                             format: ToolGenerator.formatDocument, validate: validate, call: call)
                finish(ToolComposeRecord(generation: generation, instruction: text, mode: mode))
            } catch is CancellationError {
                errorText = "中止しました(Claude 側で処理が進んでいた分は、料金がかかることがあります)"
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
            task = nil
        }
    }

    func finish(_ record: ToolComposeRecord) {
        recents.upsert(record)
        viewingID = record.id
        unseenID = isShowing ? nil : record.id
    }

    func reportBlocked(_ text: String) {
        errorText = text
    }

    func cancel() {
        task?.cancel()
    }

    func open(_ id: UUID) {
        viewingID = id
        if unseenID == id { unseenID = nil }
        if !isRunning, let record = recents.entry(id) { mode = record.mode }
    }

    func markSaved(_ id: UUID) {
        guard var record = recents.entry(id) else { return }
        record.savedAt = Date()
        recents.upsert(record)
    }

    func discard(_ id: UUID) {
        recents.remove(id)
        if viewingID == id { viewingID = nil }
        if unseenID == id { unseenID = nil }
    }

    /// 作り直す(その結果の文と、作る / 直すを、入力に戻す)
    func restoreInput(from record: ToolComposeRecord) {
        guard !isRunning else { return }
        mode = record.mode
        instruction = record.instruction
    }
}

import Foundation
import JavaScriptCore

/// スクリプトを、画面に出さずに数秒分だけ試しに動かして、エラーが出ないかを確かめる(Claude が作ったツールの確認に使う)。
/// 時間を早回しにして、setup・2秒分のコマ・触れる・入力の部品・onStop を呼ぶ。音・振動・書き出しは行わず、保存領域は端末に書かない。
/// アプリのデータは、実際のデータではなく仮のデータ(ScriptMockData)を渡す。途中で onData も呼び、センサーの開始・停止にも仮の値で応える。
enum ScriptTrial {
    static let screen = ScriptScreen(width: 375, height: 500, dark: false, scale: 2)
    static let frames = 60
    /// 1回の呼び出しの時間の上限(実行時間の制限が使えるとき)
    static let callTimeLimit = 2.0
    /// 全体を待つ時間(これを超えたら、無限ループとみなして打ち切る)
    static let overallTimeout = 8.0
    static let maxProblems = 10
    /// このコマで、仮のデータをもう一度渡して onData を呼ぶ
    static let dataFrame = 30

    /// 構文の誤り(実行はしない)。なければ nil。
    static func syntaxError(_ script: String) -> String? {
        guard let context = JSContext() else { return nil }
        let source = JSStringCreateWithCFString(script as CFString)
        let url = JSStringCreateWithCFString("tool.js" as CFString)
        defer {
            JSStringRelease(source)
            JSStringRelease(url)
        }
        var exception: JSValueRef?
        if JSCheckScriptSyntax(context.jsGlobalContextRef, source, url, 1, &exception) { return nil }
        guard let exception, let value = JSValue(jsValueRef: exception, in: context) else { return "構文の誤りがあります" }
        return "構文の誤り: " + ScriptRuntime.describe(value)
    }

    /// 試しに動かして見つかった問題(なければ空)。専用のスレッドで動かし、overallTimeout まで待つ。
    static func problems(for content: ScriptToolContent) async -> [String] {
        if let syntax = syntaxError(content.script) { return [syntax] }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let thread = Thread {
                once.resume(run(content))
            }
            thread.stackSize = ScriptRunner.stackSize
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + overallTimeout) {
                once.resume(["\(Int(overallTimeout))秒たっても終わりませんでした(無限ループや、重すぎる処理の可能性)"])
            }
        }
    }

    /// ツールの確認に使う形(スクリプト型でなければ空)
    static func issues(for tool: CustomTool) async -> [ToolIssue] {
        guard tool.kind == .script, let content = tool.script else { return [] }
        return await problems(for: content).map { ToolIssue(path: "script", message: $0) }
    }

    /// 同じスレッドで、続けて動かす(テストからも呼ぶ)
    static func run(_ content: ScriptToolContent) -> [String] {
        let initial = ScriptMockData.all(requested: content.permissions, now: Date())
        let runtime = ScriptRuntime(content: content, storage: ScriptStorage(fileURL: nil), timeLimit: callTimeLimit, headless: true,
                                    data: initial, granted: Set(content.permissions))
        var problems: [String] = []
        var activeSensors = Set<String>()
        var pendingData: [String: String] = [:]
        func handleSensors(_ output: ScriptOutput) {
            guard !output.sensorRequests.isEmpty else { return }
            for request in output.sensorRequests {
                if request.on { activeSensors.insert(request.kind.rawValue) } else { activeSensors.remove(request.kind.rawValue) }
            }
            pendingData[ScriptDataKind.sensors.rawValue] = ScriptJSON.string(ScriptMockData.sensors(now: Date(), active: activeSensors))
        }
        func collect(_ output: ScriptOutput) {
            for line in output.logs where line.level == 2 && problems.count < maxProblems {
                if line.text != output.error { problems.append("console.error: " + line.text) }
            }
            if let error = output.error, problems.count < maxProblems { problems.append(error) }
        }
        let first = runtime.load(screen: screen)
        collect(first)
        guard first.error == nil else { return problems }
        handleSensors(first)
        let initialInputs = content.controls.filter { $0.kind != .button }.map { ($0.id, $0.value) }
        let buttons = content.controls.filter { $0.kind == .button }.map { ($0.id, ScriptControlValue.bool(true)) }
        let center = (x: screen.width / 2, y: screen.height / 2)
        let dt = 1.0 / Double(content.fps)
        for frame in 0..<frames {
            var touches: [ScriptTouch] = []
            switch frame {
            case 10: touches = [ScriptTouch(phase: .down, x: center.x, y: center.y)]
            case 12: touches = [ScriptTouch(phase: .move, x: center.x + 20, y: center.y + 10)]
            case 14: touches = [ScriptTouch(phase: .up, x: center.x + 20, y: center.y + 10)]
            default: break
            }
            let inputs = frame == 0 ? initialInputs : frame == 20 ? buttons : []
            if frame == dataFrame {
                pendingData.merge(ScriptMockData.all(requested: content.permissions, now: Date())) { _, new in new }
                if !activeSensors.isEmpty {
                    pendingData[ScriptDataKind.sensors.rawValue] = ScriptJSON.string(ScriptMockData.sensors(now: Date(), active: activeSensors))
                }
            }
            let output = runtime.tick(t: Double(frame + 1) * dt, dt: dt, screen: screen, touches: touches, inputs: inputs, data: pendingData)
            pendingData = [:]
            collect(output)
            if output.error != nil { return problems }
            handleSensors(output)
        }
        collect(runtime.stop())
        return problems
    }

    /// 1回だけ返す(スレッドの結果と、時間切れの、早いほう)
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String], Never>?

        init(_ continuation: CheckedContinuation<[String], Never>) {
            self.continuation = continuation
        }

        func resume(_ value: [String]) {
            let pending = lock.withLock { () -> CheckedContinuation<[String], Never>? in
                let c = continuation
                continuation = nil
                return c
            }
            pending?.resume(returning: value)
        }
    }
}

import Observation
import SwiftUI
import UIKit

/// 1つのスクリプト型のツールの実行(画面の側)。スクリプトは ScriptRunner の専用のスレッドで動き、結果をここに反映する。
/// 呼び出しが2秒以上戻らなければ「応答なし」にする。実行中は「実行中のツール」を記録し、閉じたら消す。
/// アプリのデータは data(本物か仮のデータ)から受け取ってスクリプトに渡す。閉じたときは、センサーも必ず止める。
@MainActor
@Observable
final class ScriptSession {
    enum Status: Equatable {
        case idle
        case running
        case failed(String)
        case closed
    }

    /// 「応答なし」にするまでの時間(秒)
    static let unresponsiveAfter = 2.0
    static let maxLogLines = 300

    private(set) var status: Status = .idle
    private(set) var ops: [ScriptDrawOp] = []
    private(set) var images: [Int: CGImage] = [:]
    private(set) var controls: [ScriptControlSpec]
    private(set) var logs: [ScriptLogLine] = []
    private(set) var isUnresponsive = false
    /// 書き出した PNG(共有シートで渡す)
    var exportedFile: URL?
    var exportMessage: String?

    let tool: CustomTool
    let content: ScriptToolContent
    let isPreview: Bool
    /// スクリプトに渡すデータの種類(JSON に書いてあって、許可したもの)
    let granted: Set<ScriptPermission>

    @ObservationIgnored private var runner: ScriptRunner?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private let runGuard: ScriptRunGuard
    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private let sound = ScriptSoundPlayer()
    @ObservationIgnored private var screen = ScriptScreen(width: 0, height: 0, dark: false, scale: 2)
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private let data: ScriptDataSource

    init(tool: CustomTool, content: ScriptToolContent, isPreview: Bool, runGuard: ScriptRunGuard, storageDirectory: URL,
         granted: Set<ScriptPermission> = [], data: ScriptDataSource? = nil) {
        self.tool = tool
        self.content = content
        self.isPreview = isPreview
        self.granted = granted.intersection(content.permissions)
        self.data = data ?? ScriptMockDataSource(requested: [])
        self.runGuard = runGuard
        controls = content.controls
        // プレビューは端末に保存しない(保存する前のツールが、保存領域を作らないように)
        storageURL = isPreview ? nil : ScriptStorage.storageURL(toolID: tool.id, directory: storageDirectory)
    }

    var timeLimitAvailable: Bool { ScriptTimeLimit.isAvailable }

    /// キャンバスの大きさが分かったら始める
    func start(screen: ScriptScreen) {
        guard status == .idle || isFailed else { return }
        self.screen = screen
        ops = []
        images = [:]
        logs = []
        controls = content.controls
        isUnresponsive = false
        status = .running
        markRunning()
        let content = content
        let storageURL = storageURL
        let granted = granted
        let initial = data.initialData()
        let runner = ScriptRunner(screen: screen, fps: content.fps, makeRuntime: {
            ScriptRuntime(content: content, storage: ScriptStorage(fileURL: storageURL), data: initial, granted: granted)
        }, onOutput: { [weak self] output in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(output) }
            }
        })
        self.runner = runner
        runner.start()
        data.start { [weak runner] changes in runner?.update(data: changes) }
        // 初期値を、onInput で伝える(部品の初期値をスクリプトが知れるように)
        for control in content.controls where control.kind != .button {
            runner.send(input: control.id, value: control.value)
        }
        startWatchdog()
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    /// 最初から動かし直す
    func restart() {
        stopRunner()
        status = .idle
        start(screen: screen)
    }

    /// 画面を閉じる。応答がなくても、すぐに閉じる(スクリプトの実行は打ち切る)。
    func close() {
        stopRunner()
        status = .closed
    }

    private func stopRunner() {
        runner?.cancel()
        runner = nil
        ScreenAwake.set(awakeReason, false)
        watchdog?.invalidate()
        watchdog = nil
        sound.stop()
        data.stop()
        runGuard.end()
        isUnresponsive = false
    }

    /// バックグラウンドでは止める(電池のため。「実行中のツール」の記録も消す)
    func pause() {
        guard status == .running, !isPaused else { return }
        isPaused = true
        runner?.pause()
        runGuard.end()
        sound.stop()
        data.pause()
    }

    func resume() {
        guard status == .running, isPaused else { return }
        isPaused = false
        markRunning()
        data.resume()
        runner?.resume()
    }

    func update(screen new: ScriptScreen) {
        guard new != screen else { return }
        screen = new
        runner?.update(screen: new)
    }

    func touch(_ phase: ScriptTouch.Phase, at point: CGPoint) {
        runner?.send(ScriptTouch(phase: phase, x: Double(point.x), y: Double(point.y)))
    }

    func input(_ id: String, value: ScriptControlValue) {
        if let index = controls.firstIndex(where: { $0.id == id }), controls[index].kind != .button {
            controls[index].value = value
        }
        runner?.send(input: id, value: value)
    }

    private func markRunning() {
        runGuard.begin(ScriptRunRecord(toolID: tool.id, name: tool.name, startedAt: Date(), isPreview: isPreview))
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let runner = self.runner else { return }
                let stuck = runner.busySince.map { Date().timeIntervalSince($0) >= Self.unresponsiveAfter } ?? false
                if stuck != self.isUnresponsive { self.isUnresponsive = stuck }
            }
        }
    }

    // MARK: - 結果の反映

    private func apply(_ output: ScriptOutput) {
        guard status == .running else { return }
        if let images = output.images { self.images = images }
        if let ops = output.ops { self.ops = ops }
        if !output.logs.isEmpty {
            logs.append(contentsOf: output.logs)
            if logs.count > Self.maxLogLines { logs.removeFirst(logs.count - Self.maxLogLines) }
        }
        if !output.uiChanges.isEmpty { controls = ScriptUIChange.apply(output.uiChanges, to: controls) }
        for request in output.sounds { sound.play(request) }
        for kind in output.haptics { ScriptHaptics.play(kind) }
        // バックグラウンドの間の依頼は、データの出どころが覚えておき、戻ったときに動かす
        for request in output.sensorRequests where granted.contains(.sensors) { data.setSensor(request.kind, on: request.on) }
        for request in output.exports { export(request) }
        applySystem(output)
        if let error = output.error {
            status = .failed(error)
            stopRunner()
        }
    }

    // MARK: - 通知・画面を消さない・コピー(v0.9.32)

    private var awakeReason: String { "script.\(tool.id)" }

    private func applySystem(_ output: ScriptOutput) {
        // プレビュー(保存する前)では、通知を予約しない
        if !isPreview {
            for request in output.notifications { ScriptNotifications.apply(request, toolID: tool.id, toolName: tool.name) }
        }
        if let on = output.keepAwake { ScreenAwake.set(awakeReason, on) }
        if let text = output.clipboard {
            UIPasteboard.general.string = text
            showMessage("コピーしました")
        }
    }

    private func showMessage(_ text: String) {
        exportMessage = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if self?.exportMessage == text { self?.exportMessage = nil }
        }
    }

    // MARK: - PNG の書き出し

    static let maxExportSide = 4096.0

    private func export(_ request: ScriptExportRequest) {
        let image: CGImage?
        let name: String
        switch request {
        case .canvas(let width, let requestedName):
            name = requestedName
            image = renderCanvas(width: width)
        case .image(let source, let scale, let requestedName):
            name = requestedName
            image = Self.scaledNearest(source, scale: scale)
        }
        guard let image, let data = UIImage(cgImage: image).pngData() else {
            exportMessage = "PNG を作れませんでした"
            return
        }
        let base = name.isEmpty ? tool.id : name.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(base + ".png")
        do {
            try data.write(to: url, options: .atomic)
            exportedFile = url
        } catch {
            exportMessage = "PNG を書き出せませんでした"
        }
    }

    /// 今の表示を、指定の幅(px)で描き直す。0 なら画面と同じ大きさ。
    func renderCanvas(width: Double) -> CGImage? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        let target = width > 0 ? width : screen.width * screen.scale
        let scale = min(target, Self.maxExportSide) / screen.width
        let renderer = ImageRenderer(content: ScriptCanvasView(ops: ops, images: images)
            .frame(width: screen.width, height: screen.height)
            .background(Color(screen.dark ? UIColor.black : UIColor.white)))
        renderer.scale = max(scale, 0.1)
        return renderer.cgImage
    }

    /// 補間しないで整数倍に拡大する(ドット絵がにじまないように)
    static func scaledNearest(_ image: CGImage, scale: Int) -> CGImage? {
        let factor = min(max(scale, 1), 16)
        let width = min(image.width * factor, Int(maxExportSide))
        let height = min(image.height * factor, Int(maxExportSide))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// 共有シート(書き出した PNG を渡す)
struct ScriptShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

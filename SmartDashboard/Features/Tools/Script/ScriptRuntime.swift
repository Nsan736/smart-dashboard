import CoreGraphics
import Foundation
import JavaScriptCore
import UIKit

/// 触れた・動かした・離した
struct ScriptTouch: Equatable {
    enum Phase: String {
        case down
        case move
        case up
    }

    var phase: Phase
    var x: Double
    var y: Double
}

/// 画面の情報(スクリプトの screen)
struct ScriptScreen: Equatable {
    var width: Double
    var height: Double
    var dark: Bool
    var scale: Double
}

struct ScriptLogLine: Identifiable, Equatable {
    let id = UUID()
    /// 0: log、1: warn、2: error
    var level: Int
    var text: String
    var time: Date
}

/// PNG の書き出しの依頼(画面の側で、共有シートを出す)
enum ScriptExportRequest {
    /// キャンバス全体。width は書き出す幅(px)。0 なら画面と同じ。
    case canvas(width: Double, name: String)
    /// image.create で作った画像。scale は整数倍(ドット絵がにじまないように、補間しないで拡大する)。
    case image(CGImage, scale: Int, name: String)
}

/// app.sensors.start / stop の依頼(画面の側で、センサーを動かす・止める)
struct ScriptSensorRequest: Equatable {
    var kind: ScriptSensorKind
    var on: Bool
}

struct ScriptSoundRequest: Equatable {
    var name: String
    var frequency: Double
    var duration: Double
    var volume: Double
}

/// 1回の呼び出し(setup・1コマ・onStop)の結果。画面への反映は、画面の側でまとめて行う。
struct ScriptOutput {
    /// 描画の命令(このコマで何も描かなければ nil。前の表示のまま)
    var ops: [ScriptDrawOp]?
    /// 画像の一覧(変わったときだけ)
    var images: [Int: CGImage]?
    var logs: [ScriptLogLine] = []
    var uiChanges: [ScriptUIChange] = []
    var exports: [ScriptExportRequest] = []
    var sounds: [ScriptSoundRequest] = []
    var haptics: [String] = []
    var sensorRequests: [ScriptSensorRequest] = []
    /// 通知の予約・取り消し(v0.9.32)
    var notifications: [ScriptNotificationRequest] = []
    /// 画面を消さない(v0.9.32。最後の指定だけ。nil は変更なし)
    var keepAwake: Bool?
    /// クリップボードに書く文字(v0.9.32。1回の呼び出しで1つだけ)
    var clipboard: String?
    /// 止めるほどのエラー(例外、時間切れ)
    var error: String?
    var timedOut = false
}

/// JavaScriptCore でスクリプトを動かす。作るのも呼ぶのも、スクリプトの専用のスレッドだけで行う。
/// スクリプトが使えるのは、ここで渡す関数(__native)と、ScriptPrelude の中のものだけ。
/// 通信・ファイル・カメラに触れる関数は渡さない(JSContext には fetch なども元からない)。
/// アプリのデータは、許可した種類の写し(JSON の文字列)を画面の側から受け取って渡すだけで、スクリプトから取りに行く関数はない。
final class ScriptRuntime {
    /// 1回の呼び出しの時間の上限(秒)。実行時間の制限が使えるときだけ効く。
    static let defaultTimeLimit = 5.0
    static let maxLogsPerCall = 50
    static let maxSoundsPerCall = 8
    static let maxHapticsPerCall = 2
    static let maxLogLength = 500
    static let maxSensorRequestsPerCall = 20

    let content: ScriptToolContent
    let storage: ScriptStorage
    let images = ScriptImageStore()
    /// 音・振動・書き出しを使わない(試しの実行)
    let headless: Bool
    /// 許可したデータの種類(JSON に書いてあって、利用者が許可したもの)
    let granted: Set<ScriptPermission>
    /// 始めたときのデータ(種類 → JSON)
    private let initialData: [String: String]
    let timeLimit: Double
    private(set) var timeLimitApplied = false

    private var context: JSContext?
    private var decoder = ScriptDrawDecoder()
    private var pending = ScriptOutput()
    private var lastError = ""
    private var exception: JSValue?
    private var lastScreen: ScriptScreen?
    private var warnedOverflow = false

    init(content: ScriptToolContent, storage: ScriptStorage, timeLimit: Double = ScriptRuntime.defaultTimeLimit, headless: Bool = false,
         data: [String: String] = [:], granted: Set<ScriptPermission> = []) {
        self.content = content
        self.storage = storage
        self.timeLimit = timeLimit
        self.headless = headless
        self.granted = granted.intersection(content.permissions)
        initialData = data
    }

    // MARK: - 呼び出し

    /// 読み込んで setup を呼ぶ
    func load(screen: ScriptScreen) -> ScriptOutput {
        pending = ScriptOutput()
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            pending.error = "スクリプトを動かす準備ができませんでした"
            return pending
        }
        self.context = context
        // 実行時間の制限は、スクリプトを動かす前に設定する
        timeLimitApplied = ScriptTimeLimit.apply(to: context, seconds: timeLimit)
        context.name = "SmartDashboard.ScriptTool"
        context.exceptionHandler = { [weak self] _, value in self?.exception = value }
        installNatives(in: context)
        exception = nil
        context.evaluateScript(ScriptPrelude.source)
        if let exception {
            pending.error = "内部の準備でエラー: " + Self.describe(exception)
            return pending
        }
        updateScreen(screen)
        // setup の時点で app.* を読めるように、スクリプトより先にデータを入れる(onData は呼ばない)
        setData(initialData)
        context.objectForKeyedSubscript("__begin")?.call(withArguments: [])
        let started = Date()
        exception = nil
        context.evaluateScript(content.script, withSourceURL: URL(string: "tool.js"))
        if let exception {
            fail(exception, during: "読み込み", started: started)
            return pending
        }
        call("setup", [])
        return finish()
    }

    /// 1コマ。データの更新(onData)、入力、触れたことを先に伝えてから frame を呼ぶ。
    func tick(t: Double, dt: Double, screen: ScriptScreen, touches: [ScriptTouch], inputs: [(String, ScriptControlValue)],
              data: [String: String] = [:]) -> ScriptOutput {
        pending = ScriptOutput()
        guard let context else {
            pending.error = "スクリプトが読み込まれていません"
            return pending
        }
        updateScreen(screen)
        context.objectForKeyedSubscript("__begin")?.call(withArguments: [])
        for kind in setData(data) {
            guard call("onData", [kind]) else { return finish() }
        }
        for (name, value) in inputs {
            guard call("onInput", [name, value.jsObject]) else { return finish() }
        }
        for touch in touches {
            guard call("onTouch", [["type": touch.phase.rawValue, "x": touch.x, "y": touch.y]]) else { return finish() }
        }
        call("frame", [t, dt])
        return finish()
    }

    /// onStop を呼び、保存領域を書く
    func stop(callStop: Bool = true) -> ScriptOutput {
        pending = ScriptOutput()
        if callStop, let context {
            context.objectForKeyedSubscript("__begin")?.call(withArguments: [])
            call("onStop", [])
        }
        storage.flush()
        return pending
    }

    /// 決まった関数があれば呼ぶ。止めるほどのエラーになったら false。
    @discardableResult
    private func call(_ name: String, _ arguments: [Any]) -> Bool {
        guard pending.error == nil, let context else { return false }
        guard let function = context.objectForKeyedSubscript(name), !function.isUndefined, !function.isNull else { return true }
        exception = nil
        let started = Date()
        function.call(withArguments: arguments)
        if let exception {
            fail(exception, during: name, started: started)
            return false
        }
        return true
    }

    private func fail(_ exception: JSValue, during name: String, started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        if timeLimitApplied, elapsed >= timeLimit * 0.9 {
            pending.timedOut = true
            pending.error = "\(name) が\(Int(timeLimit))秒以上戻らなかったため、スクリプトを止めました(無限ループの可能性)"
        } else {
            pending.error = "\(name) でエラー: " + Self.describe(exception)
        }
        pending.logs.append(ScriptLogLine(level: 2, text: pending.error ?? "", time: Date()))
    }

    static func describe(_ exception: JSValue) -> String {
        var text = exception.toString() ?? "不明なエラー"
        if let line = exception.forProperty("line"), line.isNumber { text += "(\(line.toInt32())行目)" }
        return text
    }

    /// コマの終わり: まとめた描画の命令を受け取って変換する
    private func finish() -> ScriptOutput {
        defer { storage.flushIfNeeded() }
        pending.images = images.takeChanges()
        guard !pending.timedOut, let context, let end = context.objectForKeyedSubscript("__end"),
              let result = end.call(withArguments: []), result.isObject else { return pending }
        if result.forProperty("reset")?.toBool() == true { decoder.resetStrings() }
        if let strings = result.forProperty("strings")?.toArray() as? [String], !strings.isEmpty { decoder.addStrings(strings) }
        if result.forProperty("overflow")?.toBool() == true, !warnedOverflow {
            warnedOverflow = true
            pending.logs.append(ScriptLogLine(level: 1, text: "1コマの描画の命令が多すぎるため、一部を描いていません", time: Date()))
        }
        let count = Int(result.forProperty("count")?.toInt32() ?? 0)
        guard count > 0, let buffer = result.forProperty("buffer"), let values = Self.doubles(buffer, count: count, in: context) else {
            return pending
        }
        pending.ops = decoder.decode(values)
        return pending
    }

    /// データの写しを入れる。許可していない種類と、知らない種類は入れない。入れた種類を返す(名前の順)。
    @discardableResult
    private func setData(_ data: [String: String]) -> [String] {
        guard !data.isEmpty, let setter = context?.objectForKeyedSubscript("__setData") else { return [] }
        var applied: [String] = []
        for (kind, json) in data.sorted(by: { $0.key < $1.key }) {
            guard Self.accepts(kind, granted: granted) else { continue }
            setter.call(withArguments: [kind, json])
            applied.append(kind)
        }
        return applied
    }

    /// その種類のデータを、スクリプトに入れてよいか
    static func accepts(_ kind: String, granted: Set<ScriptPermission>) -> Bool {
        ScriptDataKind(rawValue: kind)?.isAllowed(granted) ?? false
    }

    private func updateScreen(_ screen: ScriptScreen) {
        guard screen != lastScreen, let object = context?.objectForKeyedSubscript("screen") else { return }
        lastScreen = screen
        object.setValue(screen.width, forProperty: "width")
        object.setValue(screen.height, forProperty: "height")
        object.setValue(screen.dark, forProperty: "dark")
        object.setValue(screen.scale, forProperty: "scale")
    }

    // MARK: - 型付き配列の読み取り

    static func bytes(_ value: JSValue, in context: JSContext) -> Data? {
        let ref = context.jsGlobalContextRef
        guard value.isObject, let object = JSValueToObject(ref, value.jsValueRef, nil) else { return nil }
        let type = JSValueGetTypedArrayType(ref, value.jsValueRef, nil)
        guard type == kJSTypedArrayTypeUint8ClampedArray || type == kJSTypedArrayTypeUint8Array else { return nil }
        let length = JSObjectGetTypedArrayByteLength(ref, object, nil)
        guard let pointer = JSObjectGetTypedArrayBytesPtr(ref, object, nil) else { return length == 0 ? Data() : nil }
        return Data(bytes: pointer, count: length)
    }

    static func doubles(_ value: JSValue, count: Int, in context: JSContext) -> [Double]? {
        let ref = context.jsGlobalContextRef
        guard value.isObject, let object = JSValueToObject(ref, value.jsValueRef, nil),
              JSValueGetTypedArrayType(ref, value.jsValueRef, nil) == kJSTypedArrayTypeFloat64Array else { return nil }
        let length = JSObjectGetTypedArrayLength(ref, object, nil)
        guard let pointer = JSObjectGetTypedArrayBytesPtr(ref, object, nil) else { return nil }
        let n = min(count, length)
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Double.self), count: n))
    }

    // MARK: - アプリが渡す関数

    private func installNatives(in context: JSContext) {
        guard let native = JSValue(newObjectIn: context) else { return }
        func set(_ name: String, _ block: AnyObject) {
            native.setObject(block, forKeyedSubscript: name as NSString)
        }
        let lastError: @convention(block) () -> String = { [weak self] in self?.lastError ?? "" }
        set("lastError", unsafeBitCast(lastError, to: AnyObject.self))

        let log: @convention(block) (Int, String) -> Void = { [weak self] level, text in
            guard let self, self.pending.logs.count < Self.maxLogsPerCall else { return }
            self.pending.logs.append(ScriptLogLine(level: min(max(level, 0), 2), text: String(text.prefix(Self.maxLogLength)), time: Date()))
        }
        set("log", unsafeBitCast(log, to: AnyObject.self))

        let measure: @convention(block) (String, String) -> Double = { text, fontText in
            let font = ScriptFont.parse(fontText)
            let uiFont = UIFont.systemFont(ofSize: font.size, weight: font.bold ? .bold : .regular)
            return Double((text as NSString).size(withAttributes: [.font: uiFont]).width)
        }
        set("measureText", unsafeBitCast(measure, to: AnyObject.self))

        let createImage: @convention(block) (Int, Int, JSValue) -> Int = { [weak self] width, height, pixels in
            guard let self, let context = self.context else { return -1 }
            if let problem = self.images.check(width: width, height: height) {
                self.lastError = problem
                return -1
            }
            guard let data = Self.bytes(pixels, in: context) else {
                self.lastError = "image.create: ピクセルを読めませんでした"
                return -1
            }
            switch self.images.create(width: width, height: height, bytes: data) {
            case .success(let id): return id
            case .failure(let error):
                self.lastError = error.message
                return -1
            }
        }
        set("createImage", unsafeBitCast(createImage, to: AnyObject.self))

        let updateImage: @convention(block) (Int, JSValue) -> Bool = { [weak self] id, pixels in
            guard let self, let context = self.context, let data = Self.bytes(pixels, in: context) else { return false }
            if let problem = self.images.update(id: id, bytes: data) {
                self.lastError = problem
                return false
            }
            return true
        }
        set("updateImage", unsafeBitCast(updateImage, to: AnyObject.self))

        let releaseImage: @convention(block) (Int) -> Void = { [weak self] id in self?.images.release(id: id) }
        set("releaseImage", unsafeBitCast(releaseImage, to: AnyObject.self))

        let exportImage: @convention(block) (Int, Double, String) -> Void = { [weak self] id, scale, name in
            guard let self, !self.headless, let image = self.images.images[id], self.pending.exports.isEmpty else { return }
            let factor = min(max(Int(scale.rounded()), 1), 16)
            self.pending.exports.append(.image(image, scale: factor, name: String(name.prefix(60))))
        }
        set("exportImage", unsafeBitCast(exportImage, to: AnyObject.self))

        let exportCanvas: @convention(block) (Double, String) -> Void = { [weak self] width, name in
            guard let self, !self.headless, self.pending.exports.isEmpty else { return }
            self.pending.exports.append(.canvas(width: min(max(width, 0), 4096), name: String(name.prefix(60))))
        }
        set("exportCanvas", unsafeBitCast(exportCanvas, to: AnyObject.self))

        let ui: @convention(block) (String) -> Void = { [weak self] json in
            guard let self else { return }
            let change = ScriptUIChange.parse(json)
            if case .invalid(let message) = change {
                self.pending.logs.append(ScriptLogLine(level: 1, text: message, time: Date()))
            } else if self.pending.uiChanges.count < 100 {
                self.pending.uiChanges.append(change)
            }
        }
        set("ui", unsafeBitCast(ui, to: AnyObject.self))

        let sound: @convention(block) (String, Double, Double, Double) -> Void = { [weak self] name, frequency, duration, volume in
            guard let self, !self.headless, self.pending.sounds.count < Self.maxSoundsPerCall else { return }
            self.pending.sounds.append(ScriptSoundRequest(name: String(name.prefix(20)), frequency: frequency, duration: duration, volume: volume))
        }
        set("sound", unsafeBitCast(sound, to: AnyObject.self))

        let haptic: @convention(block) (String) -> Void = { [weak self] kind in
            guard let self, !self.headless, self.pending.haptics.count < Self.maxHapticsPerCall else { return }
            self.pending.haptics.append(String(kind.prefix(20)))
        }
        set("haptic", unsafeBitCast(haptic, to: AnyObject.self))

        let storageGet: @convention(block) (String) -> JSValue? = { [weak self] key in
            guard let self, let context = self.context else { return nil }
            guard let raw = self.storage.get(key) else { return JSValue(nullIn: context) }
            return JSValue(object: raw, in: context)
        }
        set("storageGet", unsafeBitCast(storageGet, to: AnyObject.self))

        let storageSet: @convention(block) (String, JSValue) -> Bool = { [weak self] key, value in
            guard let self else { return false }
            let raw: String? = (value.isNull || value.isUndefined) ? nil : value.toString()
            if let problem = self.storage.set(key, raw) {
                self.lastError = problem
                return false
            }
            return true
        }
        set("storageSet", unsafeBitCast(storageSet, to: AnyObject.self))

        let storageKeys: @convention(block) () -> String = { [weak self] in
            let keys = self?.storage.keys ?? []
            let data = (try? JSONSerialization.data(withJSONObject: keys)) ?? Data("[]".utf8)
            return String(data: data, encoding: .utf8) ?? "[]"
        }
        set("storageKeys", unsafeBitCast(storageKeys, to: AnyObject.self))

        let storageClear: @convention(block) () -> Void = { [weak self] in self?.storage.clear() }
        set("storageClear", unsafeBitCast(storageClear, to: AnyObject.self))

        // センサーを動かす・止める依頼。センサーを許可していなければ受け付けない(false)。
        let sensor: @convention(block) (String, Bool) -> Bool = { [weak self] name, on in
            guard let self, self.granted.contains(.sensors), let kind = ScriptSensorKind(rawValue: name),
                  self.pending.sensorRequests.count < Self.maxSensorRequestsPerCall else { return false }
            self.pending.sensorRequests.append(ScriptSensorRequest(kind: kind, on: on))
            return true
        }
        set("sensor", unsafeBitCast(sensor, to: AnyObject.self))

        // 祝日の名前(計算だけ。祝日でなければ空の文字)
        let holidayName: @convention(block) (Int, Int, Int) -> String = { year, month, day in
            JapaneseHolidays.holidayName(year: year, month: month, day: day) ?? ""
        }
        set("holidayName", unsafeBitCast(holidayName, to: AnyObject.self))

        // 通知(v0.9.32)。予約するのは画面の側(ツールの ID で分ける)。試しの実行では受け付けない
        let notify: @convention(block) (String) -> Bool = { [weak self] json in
            guard let self else { return false }
            self.lastError = ""
            switch ScriptNotificationRequest.parse(json) {
            case .success(let request):
                guard !self.headless, self.pending.notifications.count < ScriptNotificationRequest.maxPerCall else { return false }
                self.pending.notifications.append(request)
                return true
            case .failure(let issue):
                self.lastError = "notify: " + issue.message
                return false
            }
        }
        set("notify", unsafeBitCast(notify, to: AnyObject.self))

        let keepAwake: @convention(block) (Bool) -> Void = { [weak self] on in
            guard let self, !self.headless else { return }
            self.pending.keepAwake = on
        }
        set("keepAwake", unsafeBitCast(keepAwake, to: AnyObject.self))

        // クリップボードに書くだけ(読む関数はない)
        let copy: @convention(block) (String) -> Bool = { [weak self] text in
            guard let self else { return false }
            self.lastError = ""
            guard text.count <= ScriptClipboard.maxLength else {
                self.lastError = "clipboard.copy: \(ScriptClipboard.maxLength)文字までにしてください"
                return false
            }
            guard !self.headless, self.pending.clipboard == nil else { return false }
            self.pending.clipboard = text
            return true
        }
        set("copy", unsafeBitCast(copy, to: AnyObject.self))

        let secureRandom: @convention(block) () -> Double = { ScriptSecureRandom.next() }
        set("secureRandom", unsafeBitCast(secureRandom, to: AnyObject.self))

        context.setObject(native, forKeyedSubscript: "__native" as NSString)
    }
}

/// スクリプトを専用のスレッドで動かし続ける(1秒あたり fps コマ)。画面の操作は止めない。
/// 呼び出しの間は busySince に始めた時刻を入れる(画面の側が、戻らない時間を見て「応答なし」を出す)。
final class ScriptRunner: @unchecked Sendable {
    /// JavaScriptCore は深い呼び出しで多くのスタックを使うので、スレッドのスタックを大きめにする
    static let stackSize = 8 * 1024 * 1024

    private let condition = NSCondition()
    private var cancelled = false
    private var paused = false
    private var resumed = false
    private var touches: [ScriptTouch] = []
    private var inputs: [(String, ScriptControlValue)] = []
    /// まだ渡していない、データの更新(種類ごとに最新の1つ)
    private var dataChanges: [String: String] = [:]
    private var screen: ScriptScreen
    private var busySinceValue: Date?
    private let fps: Int
    private let makeRuntime: () -> ScriptRuntime
    private let onOutput: (ScriptOutput) -> Void

    init(screen: ScriptScreen, fps: Int, makeRuntime: @escaping () -> ScriptRuntime, onOutput: @escaping (ScriptOutput) -> Void) {
        self.screen = screen
        self.fps = min(max(fps, 15), 60)
        self.makeRuntime = makeRuntime
        self.onOutput = onOutput
    }

    var busySince: Date? { condition.withLock { busySinceValue } }

    func start() {
        let thread = Thread { [self] in self.main() }
        thread.stackSize = Self.stackSize
        thread.name = "SmartDashboard.ScriptTool"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// 打ち切る。今の呼び出しが戻ったら終わる(戻らなければ、そのまま捨てる)。
    func cancel() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    func pause() {
        condition.withLock { paused = true }
    }

    func resume() {
        condition.withLock {
            if paused { resumed = true }
            paused = false
            condition.broadcast()
        }
    }

    func send(_ touch: ScriptTouch) {
        condition.withLock {
            // 動かしたことは、まだ渡していない最後の1つにまとめる
            if touch.phase == .move, let last = touches.last, last.phase == .move {
                touches[touches.count - 1] = touch
            } else if touches.count < 64 {
                touches.append(touch)
            }
        }
    }

    func send(input name: String, value: ScriptControlValue) {
        condition.withLock {
            inputs.removeAll { $0.0 == name && value != .bool(true) }
            if inputs.count < 64 { inputs.append((name, value)) }
        }
    }

    func update(screen new: ScriptScreen) {
        condition.withLock { screen = new }
    }

    func update(data changes: [String: String]) {
        condition.withLock { dataChanges.merge(changes) { _, new in new } }
    }

    private func busy<T>(_ work: () -> T) -> T {
        condition.withLock { busySinceValue = Date() }
        let result = work()
        condition.withLock { busySinceValue = nil }
        return result
    }

    private func main() {
        let runtime = makeRuntime()
        let first = busy { runtime.load(screen: condition.withLock { screen }) }
        onOutput(first)
        guard first.error == nil else {
            _ = runtime.stop(callStop: false)
            return
        }
        let interval = 1.0 / Double(fps)
        var last = Date()
        var elapsed = 0.0
        var next = Date().addingTimeInterval(interval)
        var lastOutput = first
        while true {
            condition.lock()
            while !cancelled && (paused || Date() < next) {
                if paused {
                    condition.wait()
                } else {
                    _ = condition.wait(until: next)
                }
                if resumed {
                    // 止めていた間の時間は数えない
                    resumed = false
                    last = Date()
                    next = Date()
                }
            }
            if cancelled {
                condition.unlock()
                break
            }
            let currentTouches = touches
            let currentInputs = inputs
            let currentData = dataChanges
            touches = []
            inputs = []
            dataChanges = [:]
            let currentScreen = screen
            condition.unlock()

            let now = Date()
            let dt = min(max(now.timeIntervalSince(last), 0), 0.1)
            last = now
            elapsed += dt
            lastOutput = busy {
                runtime.tick(t: elapsed, dt: dt, screen: currentScreen, touches: currentTouches, inputs: currentInputs, data: currentData)
            }
            onOutput(lastOutput)
            if lastOutput.error != nil { break }
            next = max(next.addingTimeInterval(interval), Date())
        }
        // 時間切れのあとは onStop を呼ばない(また固まるかもしれないため)。保存領域は書く。
        let stopped = busy { runtime.stop(callStop: !lastOutput.timedOut && lastOutput.error == nil) }
        if !stopped.logs.isEmpty { onOutput(stopped) }
    }
}

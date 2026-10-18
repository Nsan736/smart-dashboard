import CoreGraphics
import SwiftUI
import XCTest
@testable import SmartDashboard

/// スクリプト型の小ツール: 描画の命令のまとめ方と変換、色と文字の指定
final class ScriptDrawTests: XCTestCase {
    func testColors() {
        XCTAssertEqual(ScriptColor.parse("#f00"), ScriptRGBA(r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(ScriptColor.parse("#0000ff80")?.a ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(ScriptColor.parse("rgb(255, 128, 0)")?.g ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(ScriptColor.parse("rgba(0,0,255,0.5)"), ScriptRGBA(r: 0, g: 0, b: 1, a: 0.5))
        let green = ScriptColor.parse("hsl(120, 100%, 50%)")
        XCTAssertEqual(green?.g ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(green?.r ?? 1, 0, accuracy: 0.001)
        // 色相は360で回る(負の値も)
        XCTAssertEqual(ScriptColor.parse("hsl(-240, 100%, 50%)")?.g ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(ScriptColor.parse("Crimson")?.r ?? 0, 220.0 / 255, accuracy: 0.001)
        XCTAssertEqual(ScriptColor.parse("transparent"), .clear)
        XCTAssertNil(ScriptColor.parse("#12"))
        XCTAssertNil(ScriptColor.parse("rgb(1,2)"))
        XCTAssertNil(ScriptColor.parse("notacolor"))
    }

    func testFonts() {
        XCTAssertEqual(ScriptFont.parse("bold 24px sans-serif"), ScriptFont(size: 24, bold: true, italic: false, design: .standard))
        XCTAssertEqual(ScriptFont.parse("italic 12px monospace").design, .monospaced)
        XCTAssertTrue(ScriptFont.parse("700 10px serif").bold)
        XCTAssertEqual(ScriptFont.parse("9999px serif").size, 400)
        XCTAssertEqual(ScriptFont.parse("").size, 10)
    }

    func testDecodeOps() {
        var decoder = ScriptDrawDecoder()
        decoder.addStrings(["#ff0000", "bold 20px sans-serif", "こんにちは"])
        let ops = decoder.decode([
            11, 0, 42, 1, 2, 3, 4,
            30, 31, 0, 0, 32, 10, 10, 35, 5, 5, 3, 0, 6.28, 1, 37, 41,
            18, 1, 19, 1, 50, 2, 100, 50,
            1, 3, 10, 20, 4, 0.5, 5, 2, 2, 2,
            21, 2, 4, 3, 22, 0, 60, 7, 0, 0, 16, 16,
        ])
        XCTAssertEqual(ops, [
            .fillStyle(.color(ScriptRGBA(r: 1, g: 0, b: 0, a: 1))),
            .fillRect(CGRect(x: 1, y: 2, width: 3, height: 4)),
            .beginPath, .move(.zero), .line(CGPoint(x: 10, y: 10)),
            .arc(center: CGPoint(x: 5, y: 5), radius: 3, start: 0, end: 6.28, anticlockwise: true),
            .closePath, .strokePath,
            .font(ScriptFont(size: 20, bold: true, italic: false, design: .standard)), .textAlign(1),
            .fillText("こんにちは", CGPoint(x: 100, y: 50)),
            .save, .translate(10, 20), .rotate(0.5), .scale(2, 2), .restore,
            .lineDash([4, 3]), .smoothing(false), .image(id: 7, rect: CGRect(x: 0, y: 0, width: 16, height: 16)),
        ])
    }

    func testDecodeGradientsAndBadInput() {
        var decoder = ScriptDrawDecoder()
        decoder.addStrings(["#000", "#fff"])
        // 線形のグラデーション(id 0、(0,0)→(100,0)、2つの色)を定義して、塗りに使う
        let ops = decoder.decode([70, 0, 0, 0, 100, 0, 2, 1, 1, 0, 0, 13, 0, 40])
        XCTAssertEqual(ops.count, 2)
        guard case .fillStyle(.linear(let start, let end, let stops)) = ops[0] else { return XCTFail("グラデーションになるはず") }
        XCTAssertEqual(start, .zero)
        XCTAssertEqual(end, CGPoint(x: 100, y: 0))
        // 位置の順に並べ直す
        XCTAssertEqual(stops.map(\.offset), [0, 1])
        XCTAssertEqual(stops.first?.color, ScriptRGBA(r: 0, g: 0, b: 0, a: 1))
        // 知らない命令や、途中で切れた命令のあとは読まない。値が数でなければ0。
        XCTAssertEqual(decoder.decode([42, 1, 2, 3, 4, 999, 42, 0, 0, 1, 1]).count, 1)
        XCTAssertEqual(decoder.decode([42, 1, 2]), [])
        XCTAssertEqual(decoder.decode([3, .nan, .infinity]), [.translate(0, 0)])
        // 文字の表にない番号は、黒と空の文字
        XCTAssertEqual(decoder.decode([11, 99, 50, 99, 0, 0]), [.fillStyle(.color(.black)), .fillText("", .zero)])
        // 1コマの命令の数の上限
        let many = Array(repeating: 30.0, count: ScriptDrawDecoder.maxOps + 100)
        XCTAssertEqual(decoder.decode(many).count, ScriptDrawDecoder.maxOps)
    }

    func testRendererAnchor() {
        XCTAssertEqual(ScriptRenderer.anchor(align: 1, baseline: 2), UnitPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(ScriptRenderer.anchor(align: 2, baseline: 1), UnitPoint(x: 1, y: 0))
    }
}

/// スクリプトを実際に動かす(JavaScriptCore)。描画の命令、使えない機能、画像と保存領域の上限、時間切れ。
final class ScriptRuntimeTests: XCTestCase {
    private let screen = ScriptScreen(width: 300, height: 200, dark: true, scale: 2)

    private func content(_ script: String, controls: [ScriptControlSpec] = []) -> ScriptToolContent {
        ScriptToolContent(script: script, controls: controls, controlsAtTop: false, fps: 30, aspect: nil)
    }

    private func runtime(_ script: String, storage: ScriptStorage = ScriptStorage(fileURL: nil), timeLimit: Double = 2) -> ScriptRuntime {
        ScriptRuntime(content: content(script), storage: storage, timeLimit: timeLimit, headless: true)
    }

    func testDrawCommandsAreBatchedPerFrame() {
        let runtime = runtime("""
        var n = 0;
        function frame(t, dt) {
          ctx.fillStyle = screen.dark ? 'white' : 'black';
          ctx.fillRect(0, 0, screen.width, screen.height);
          ctx.font = '12px monospace';
          ctx.fillText('frame ' + n, 10, 20);
          n++;
        }
        """)
        let loaded = runtime.load(screen: screen)
        XCTAssertNil(loaded.error)
        // setup も frame も描いていなければ、命令はない
        XCTAssertNil(loaded.ops)
        let first = runtime.tick(t: 0.1, dt: 0.033, screen: screen, touches: [], inputs: [])
        XCTAssertEqual(first.ops, [
            .fillStyle(.color(ScriptRGBA(r: 1, g: 1, b: 1, a: 1))),
            .fillRect(CGRect(x: 0, y: 0, width: 300, height: 200)),
            .font(ScriptFont(size: 12, bold: false, italic: false, design: .monospaced)),
            .fillText("frame 0", CGPoint(x: 10, y: 20)),
        ])
        // 2コマ目は、変わった文字だけを新しく送る(同じ文字は番号で)
        let second = runtime.tick(t: 0.2, dt: 0.033, screen: screen, touches: [], inputs: [])
        XCTAssertEqual(second.ops?.last, .fillText("frame 1", CGPoint(x: 10, y: 20)))
    }

    func testCallbacksReceiveInputsAndTouches() {
        let runtime = runtime("""
        var log = [];
        function onInput(name, value) { log.push(name + '=' + value); }
        function onTouch(e) { log.push(e.type + ':' + e.x + ',' + e.y); }
        function frame(t, dt) { console.log(log.join(' ')); log = []; }
        """)
        XCTAssertNil(runtime.load(screen: screen).error)
        let output = runtime.tick(t: 0, dt: 0, screen: screen, touches: [ScriptTouch(phase: .down, x: 1, y: 2)],
                                  inputs: [("speed", .number(3)), ("on", .bool(true)), ("name", .text("a"))])
        XCTAssertEqual(output.logs.map(\.text), ["speed=3 on=true name=a down:1,2"])
    }

    func testNoNetworkOrHostAccess() {
        let runtime = runtime("""
        function setup() {
          var names = ['fetch', 'XMLHttpRequest', 'WebSocket', 'setTimeout', 'setInterval', 'require', 'importScripts',
                       'document', 'window', 'navigator', 'localStorage', '__native', 'process'];
          var found = names.filter(function (n) { return typeof this[n] !== 'undefined'; }, this);
          console.log(found.length === 0 ? 'none' : found.join(','));
        }
        """)
        let output = runtime.load(screen: screen)
        XCTAssertNil(output.error)
        XCTAssertEqual(output.logs.map(\.text), ["none"])
    }

    func testErrorsStopTheTool() {
        let syntax = runtime("function frame( {")
        XCTAssertNotNil(syntax.load(screen: screen).error)
        let thrown = runtime("function frame() { throw new Error('壊れた'); }")
        XCTAssertNil(thrown.load(screen: screen).error)
        let output = thrown.tick(t: 0, dt: 0, screen: screen, touches: [], inputs: [])
        XCTAssertTrue(output.error?.contains("壊れた") == true)
        XCTAssertFalse(output.timedOut)
    }

    func testImageLimits() {
        let store = ScriptImageStore()
        XCTAssertNotNil(store.check(width: 0, height: 10))
        XCTAssertNotNil(store.check(width: ScriptImageStore.maxSide + 1, height: 10))
        XCTAssertNil(store.check(width: ScriptImageStore.maxSide, height: ScriptImageStore.maxSide))
        let pixel = Data([255, 0, 0, 255])
        for _ in 0..<ScriptImageStore.maxImages {
            if case .failure(let error) = store.create(width: 1, height: 1, bytes: pixel) { XCTFail(error.message) }
        }
        // 枚数の上限
        guard case .failure = store.create(width: 1, height: 1, bytes: pixel) else { return XCTFail("上限を超えて作れてしまう") }
        // 合計の大きさの上限: 1024×1024 を8枚(32MB)までで、9枚目は作れない
        let big = ScriptImageStore()
        let bytes = Data(count: 1024 * 1024 * 4)
        for _ in 0..<8 { _ = big.create(width: 1024, height: 1024, bytes: bytes) }
        XCTAssertNotNil(big.check(width: 1024, height: 1024))
        // バイト数が合わないものは作らない
        guard case .failure = ScriptImageStore().create(width: 2, height: 2, bytes: pixel) else { return XCTFail("大きさの違うピクセル") }
        // 変わったときだけ渡す
        let fresh = ScriptImageStore()
        XCTAssertNil(fresh.takeChanges())
        _ = fresh.create(width: 1, height: 1, bytes: pixel)
        XCTAssertEqual(fresh.takeChanges()?.count, 1)
        XCTAssertNil(fresh.takeChanges())
    }

    func testImagesFromScript() {
        let runtime = runtime("""
        var img;
        function setup() {
          var px = new Uint8ClampedArray(4 * 4 * 4);
          for (var i = 0; i < px.length; i += 4) { px[i] = 255; px[i + 3] = 255; }
          img = image.create(4, 4, px);
          try { image.create(2000, 10, new Uint8ClampedArray(2000 * 10 * 4)); } catch (e) { console.log('too big'); }
          try { image.create(2, 2, new Uint8ClampedArray(3)); } catch (e) { console.log('bad length'); }
        }
        function frame() { ctx.drawImage(img, 0, 0, 8, 8); }
        """)
        let loaded = runtime.load(screen: screen)
        XCTAssertNil(loaded.error)
        XCTAssertEqual(loaded.logs.map(\.text), ["too big", "bad length"])
        XCTAssertEqual(loaded.images?.count, 1)
        XCTAssertEqual(loaded.images?.first?.value.width, 4)
        let output = runtime.tick(t: 0, dt: 0, screen: screen, touches: [], inputs: [])
        XCTAssertEqual(output.ops, [.image(id: 1, rect: CGRect(x: 0, y: 0, width: 8, height: 8))])
    }

    func testStorageFromScript() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("script-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = runtime("""
        function setup() {
          storage.set('best', 42);
          storage.set('names', ['a', 'b']);
          try { storage.set('big', new Array(300000).join('x')); } catch (e) { console.log('limit'); }
          console.log(JSON.stringify(storage.get('names')) + ' ' + storage.keys().join(','));
        }
        """, storage: ScriptStorage(fileURL: url))
        let output = first.load(screen: screen)
        XCTAssertEqual(output.logs.map(\.text), ["limit", #"["a","b"] best,names"#])
        // 閉じると書く。次に開くと、前の値が読める。
        _ = first.stop()
        let second = runtime("function setup() { console.log(storage.get('best') + ' ' + (storage.get('none') === undefined)); }",
                             storage: ScriptStorage(fileURL: url))
        XCTAssertEqual(second.load(screen: screen).logs.map(\.text), ["42 true"])
    }

    func testTimeLimitStopsInfiniteLoop() throws {
        try XCTSkipUnless(ScriptTimeLimit.isAvailable, "この環境では実行時間の制限が使えない")
        let runtime = runtime("function frame() { for (;;) {} }", timeLimit: 0.5)
        XCTAssertNil(runtime.load(screen: screen).error)
        let started = Date()
        let output = runtime.tick(t: 0, dt: 0, screen: screen, touches: [], inputs: [])
        XCTAssertTrue(output.timedOut)
        XCTAssertNotNil(output.error)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

/// 保存領域、「実行中のツール」の記録、入力の部品、音
final class ScriptSupportTests: XCTestCase {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("script-\(UUID().uuidString)").appendingPathComponent(name)
    }

    func testStorageLimitsAndAtomicFile() throws {
        let url = tempURL("tool.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let storage = ScriptStorage(fileURL: url)
        XCTAssertNil(storage.set("a", "1"))
        XCTAssertNotNil(storage.set("", "1"))
        XCTAssertNotNil(storage.set(String(repeating: "k", count: ScriptStorage.maxKeyLength + 1), "1"))
        XCTAssertNotNil(storage.set("big", String(repeating: "x", count: ScriptStorage.maxBytes)))
        // 上限ちょうどまでは書ける(置き換えは、前の値の分を引いて数える)
        XCTAssertNil(storage.set("a", String(repeating: "x", count: ScriptStorage.maxBytes - 1)))
        XCTAssertEqual(storage.byteCount, ScriptStorage.maxBytes)
        XCTAssertNil(storage.set("a", "2"))
        // 一度書いたあと2秒たたないうちは、flushIfNeeded では書かない
        storage.flushIfNeeded(now: Date())
        XCTAssertNil(storage.set("a", "3"))
        storage.flushIfNeeded(now: Date())
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)), ["a": "2"])
        XCTAssertNil(storage.set("a", "2"))
        storage.flush()
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved, ["a": "2"])
        XCTAssertNil(storage.set("a", nil))
        storage.flush()
        XCTAssertEqual(ScriptStorage(fileURL: url).values, [:])
        // 読めないファイルは空として扱い、落ちない
        try Data("{壊れた".utf8).write(to: url)
        XCTAssertEqual(ScriptStorage(fileURL: url).values, [:])
        // 端末に書かない保存領域
        let memory = ScriptStorage(fileURL: nil)
        XCTAssertNil(memory.set("x", "1"))
        memory.flush()
        XCTAssertEqual(memory.get("x"), "1")
        XCTAssertEqual(ScriptStorage.storageURL(toolID: "a/b", directory: URL(fileURLWithPath: "/tmp")).lastPathComponent, "a_b.json")
    }

    func testRunGuardRecordsAndRecovers() throws {
        let url = tempURL("script-running.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let guardFile = ScriptRunGuard(fileURL: url)
        XCTAssertNil(guardFile.load())
        let record = ScriptRunRecord(toolID: "game", name: "ゲーム", startedAt: Date(timeIntervalSince1970: 1000), isPreview: false)
        guardFile.begin(record)
        // 正常に閉じなかった(アプリが落ちた)ときは、次に起動したときに残っている
        XCTAssertEqual(ScriptRunGuard(fileURL: url).load(), record)
        guardFile.end()
        XCTAssertNil(guardFile.load())
        // 読めない記録は、無いとみなす
        try Data("壊れた".utf8).write(to: url)
        XCTAssertNil(guardFile.load())
    }

    @MainActor
    func testLibraryReadsCrashRecordAtLaunch() throws {
        let directory = tempURL("lib")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "script-test-\(UUID().uuidString)"))
        let fileURL = directory.appendingPathComponent("custom-tools.json")
        ScriptRunGuard(fileURL: directory.appendingPathComponent("script-running.json"))
            .begin(ScriptRunRecord(toolID: "x", name: "X", startedAt: Date(), isPreview: false))
        let library = ToolLibrary(fileURL: fileURL, defaults: defaults)
        XCTAssertEqual(library.crashedScript?.toolID, "x")
        library.resolveCrashedScript()
        XCTAssertNil(library.crashedScript)
        XCTAssertNil(ToolLibrary(fileURL: fileURL, defaults: defaults).crashedScript)
    }

    func testControlsAndUIChanges() {
        guard case .success(let slider) = ScriptControlSpec.parse(["id": "speed", "type": "slider", "min": 0, "max": 10, "step": 2, "value": 5], path: "c") else {
            return XCTFail("スライダーを読めるはず")
        }
        XCTAssertEqual(slider.value, .number(5))
        XCTAssertEqual(slider.snapped(5.1), 6)
        XCTAssertEqual(slider.snapped(99), 10)
        guard case .failure = ScriptControlSpec.parse(["id": "1bad", "type": "slider"], path: "c") else { return XCTFail("名前の誤り") }
        guard case .failure = ScriptControlSpec.parse(["id": "s", "type": "slider", "min": 5, "max": 1], path: "c") else { return XCTFail("範囲の誤り") }
        guard case .failure = ScriptControlSpec.parse(["id": "c", "type": "choice"], path: "c") else { return XCTFail("選択肢がない") }
        guard case .success(let choice) = ScriptControlSpec.parse(["id": "c", "type": "choice", "options": ["A", "B"], "value": "B"], path: "c") else {
            return XCTFail("選択肢を読めるはず")
        }
        XCTAssertEqual(choice.value, .text("B"))

        var controls = [slider, choice]
        controls = ScriptUIChange.apply([
            ScriptUIChange.parse(#"{"op":"set","id":"speed","value":7}"#),
            ScriptUIChange.parse(#"{"op":"set","id":"c","value":"Z"}"#),
            ScriptUIChange.parse(#"{"op":"add","id":"go","type":"button","label":"開始"}"#),
            ScriptUIChange.parse(#"{"op":"remove","id":"c"}"#),
        ], to: controls)
        XCTAssertEqual(controls.map(\.id), ["speed", "go"])
        XCTAssertEqual(controls[0].value, .number(8))
        XCTAssertEqual(ScriptUIChange.parse("壊れた"), .invalid("ui: 読めない指定です"))
    }

    func testSynth() {
        XCTAssertEqual(ScriptSynth.tone(frequency: 440, duration: 0.5, volume: 1).count, Int(0.5 * ScriptSynth.sampleRate))
        // 長さは2秒まで、音量は半分まで
        XCTAssertEqual(ScriptSynth.tone(frequency: 440, duration: 10, volume: 1).count, Int(ScriptSynth.maxDuration * ScriptSynth.sampleRate))
        XCTAssertLessThanOrEqual(ScriptSynth.tone(frequency: 440, duration: 0.1, volume: 5).map { abs($0) }.max() ?? 1, 0.5)
        for name in ScriptSynth.presets { XCTAssertNotNil(ScriptSynth.preset(name), name) }
        XCTAssertNil(ScriptSynth.preset("explosion"))
    }
}

/// スクリプト型の形式の読み取り、サンプル、試しの実行、Claude での作り直し
final class ScriptToolFormatTests: XCTestCase {
    static let samples = ["analog_clock", "bouncing_ball", "fireworks", "pixel_walker", "pattern_maker", "tap_target",
                          "weather_board", "next_train", "place_compass", "pressure_graph"]

    private func sample(_ name: String) throws -> CustomTool {
        let json = try XCTUnwrap(String(data: Fixture.data("tool_script_" + name), encoding: .utf8))
        guard case .success(let tool) = CustomToolParser.parse(json) else {
            XCTFail("\(name) を読めない")
            throw ScriptImageError(message: name)
        }
        return tool
    }

    func testParseScriptTool() throws {
        let tool = try sample("pattern_maker")
        XCTAssertEqual(tool.kind, .script)
        XCTAssertEqual(tool.kind.label, "スクリプト型")
        let content = try XCTUnwrap(tool.script)
        XCTAssertTrue(content.controlsAtTop)
        XCTAssertEqual(content.fps, 15)
        XCTAssertEqual(content.controls.map(\.kind), [.choice, .slider, .button])
        // 誤り
        guard case .failure(let issues) = CustomToolParser.parse(#"{"format":1,"id":"x","name":"X","type":"script","fps":200,"aspect":9,"controlsPosition":"left","controls":[{"id":"a","type":"knob"}]}"#) else {
            return XCTFail("誤りがあるはず")
        }
        XCTAssertEqual(Set(issues.map(\.path)), ["script", "fps", "aspect", "controlsPosition", "controls[0].type"])
        let long = String(repeating: "a", count: ScriptToolContent.maxScriptLength + 1)
        guard case .failure(let longIssues) = CustomToolParser.parse(#"{"format":1,"id":"x","name":"X","type":"script","script":""# + long + #""}"#) else {
            return XCTFail("長すぎるはず")
        }
        XCTAssertEqual(longIssues.map(\.path), ["script"])
    }

    func testSamplesRunWithoutErrors() throws {
        for name in Self.samples {
            let tool = try sample(name)
            let content = try XCTUnwrap(tool.script)
            XCTAssertNil(ScriptTrial.syntaxError(content.script), name)
            XCTAssertEqual(ScriptTrial.run(content), [], name)
        }
    }

    func testTrialFindsProblems() async {
        func content(_ script: String) -> ScriptToolContent {
            ScriptToolContent(script: script, controls: [], controlsAtTop: false, fps: 30, aspect: nil)
        }
        let syntax = await ScriptTrial.problems(for: content("function frame( {"))
        XCTAssertEqual(syntax.count, 1)
        XCTAssertTrue(syntax[0].hasPrefix("構文の誤り"))
        // 触れたときだけ起きる誤りも見つける
        let touch = await ScriptTrial.problems(for: content("function onTouch(e) { undefinedFunction(); }"))
        XCTAssertTrue(touch.first?.contains("onTouch") == true)
        let logged = await ScriptTrial.problems(for: content("function setup() { console.error('おかしい'); }"))
        XCTAssertEqual(logged, ["console.error: おかしい"])
        let fine = await ScriptTrial.problems(for: content("function frame(t) { ctx.fillRect(0, 0, 10, 10); }"))
        XCTAssertEqual(fine, [])
    }

    func testGeneratorRetriesScriptThatFailsTrial() async throws {
        let broken = #"{"format":1,"id":"g","name":"G","type":"script","script":"function frame() { nope(); }"}"#
        let fixed = #"{"format":1,"id":"g","name":"G","type":"script","script":"function frame() { ctx.fillRect(0, 0, 1, 1); }"}"#
        var answers = [broken, fixed]
        var requests: [ClaudeRequest] = []
        let generation = try await ToolGenerator.run(messages: ToolGenerator.createMessages(description: "ゲーム"), model: "m", thinking: true,
                                                     format: "F", validate: { await ScriptTrial.issues(for: $0) }) { request in
            requests.append(request)
            let text = answers.removeFirst()
            return ClaudeCallResult(response: ClaudeResponse(text: text, usage: ClaudeUsage(input: 1, output: 1), stopReason: "end_turn", model: nil), cost: 0)
        }
        guard case .valid = generation.outcome else { return XCTFail("2回目で通るはず") }
        XCTAssertEqual(generation.attempts, 2)
        guard case .text(let retry, _)? = requests[1].messages.last?.content.first else { return XCTFail("作り直しの依頼がない") }
        XCTAssertTrue(retry.contains("script"))
        XCTAssertTrue(retry.contains("frame"))
        // スクリプトは長くなるので、出力の上限と待つ時間を大きくとる
        XCTAssertEqual(requests[0].maxTokens, 32_000)
        XCTAssertEqual(requests[0].timeout, ToolGenerator.timeout)
        // 形式の説明に、スクリプト型の API が入っている
        XCTAssertTrue(ToolGenerator.formatDocument.contains("frame(t, dt)"))
        XCTAssertTrue(ToolGenerator.systemPrompt(format: "").contains("script"))
    }
}

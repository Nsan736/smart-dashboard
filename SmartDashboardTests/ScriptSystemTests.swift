import CoreGraphics
import XCTest
@testable import SmartDashboard

/// スクリプト型に足した機能(v0.9.32): 通知、画面を消さない、クリップボード、暗号に使える乱数、複数行の文字の欄
final class ScriptSystemTests: XCTestCase {
    private let screen = ScriptScreen(width: 320, height: 480, dark: false, scale: 2)

    private func load(_ script: String, headless: Bool = false) -> ScriptOutput {
        let content = ScriptToolContent(script: script, controls: [], controlsAtTop: false, fps: 30, aspect: nil)
        let runtime = ScriptRuntime(content: content, storage: ScriptStorage(fileURL: nil), headless: headless)
        return runtime.load(screen: screen)
    }

    func testNotificationRequestParsing() {
        XCTAssertEqual(try ScriptNotificationRequest.parse(#"{"op":"schedule","id":"t1","seconds":90,"title":"終わり","body":"5分"}"#).get(),
                       .schedule(id: "t1", seconds: 90, title: "終わり", body: "5分"))
        XCTAssertEqual(try ScriptNotificationRequest.parse(#"{"op":"cancel","id":"t-1_a"}"#).get(), .cancel(id: "t-1_a"))
        XCTAssertEqual(try ScriptNotificationRequest.parse(#"{"op":"cancelAll"}"#).get(), .cancelAll)
        // 題名が空なら「小ツール」、長い文字は切り詰める
        let long = String(repeating: "あ", count: 200)
        guard case .success(.schedule(_, _, let title, let body)) = ScriptNotificationRequest.parse(#"{"op":"schedule","id":"a","seconds":1,"title":"","body":"\#(long)"}"#) else {
            return XCTFail("読めるはず")
        }
        XCTAssertEqual(title, "小ツール")
        XCTAssertEqual(body.count, ScriptNotificationRequest.maxBody)
        // 誤り: id の文字、秒の範囲、知らない op
        for json in [#"{"op":"schedule","id":"a b","seconds":10}"#, #"{"op":"schedule","id":"","seconds":10}"#,
                     #"{"op":"schedule","id":"a","seconds":0}"#, #"{"op":"schedule","id":"a","seconds":86401}"#,
                     #"{"op":"schedule","id":"a"}"#, #"{"op":"fire","id":"a"}"#, "not json"] {
            if case .success = ScriptNotificationRequest.parse(json) { XCTFail(json) }
        }
        XCTAssertEqual(ScriptNotificationRequest.identifier(toolID: "builtin-js.timer", id: "t1"), "script.builtin-js.timer.t1")
        XCTAssertTrue(ScriptNotificationRequest.identifier(toolID: "x", id: "1").hasPrefix(ScriptNotificationRequest.prefix(toolID: "x")))
    }

    func testRuntimeCollectsSystemRequests() {
        let output = load("""
        var results = [];
        function setup() {
          for (var i = 0; i < 6; i++) results.push(notify.schedule('n' + i, 60, { title: 'T' }));
          screen.keepAwake(true);
          results.push(clipboard.copy('一回目'));
          results.push(clipboard.copy('二回目'));
          console.log(JSON.stringify(results));
        }
        """)
        XCTAssertNil(output.error)
        // 1回の呼び出しで通知は4件まで、コピーは1回まで
        XCTAssertEqual(output.notifications.count, ScriptNotificationRequest.maxPerCall)
        XCTAssertEqual(output.keepAwake, true)
        XCTAssertEqual(output.clipboard, "一回目")
        XCTAssertEqual(output.logs.first?.text, "[true,true,true,true,false,false,true,false]")
    }

    func testRuntimeRejectsBadRequests() {
        let badID = load("function setup() { notify.schedule('だめ', 10, 'x'); }")
        XCTAssertTrue(badID.error?.contains("notify") == true, badID.error ?? "")
        XCTAssertTrue(badID.notifications.isEmpty)
        let long = load("function setup() { clipboard.copy(new Array(10002).join('a')); }")
        XCTAssertTrue(long.error?.contains("clipboard.copy") == true, long.error ?? "")
        XCTAssertNil(long.clipboard)
        // 試しの実行では、通知・コピー・画面を消さないを受け付けない(例外にもしない)
        let headless = load("function setup() { console.log(String(notify.schedule('a', 10)) + String(clipboard.copy('x'))); screen.keepAwake(true); }", headless: true)
        XCTAssertNil(headless.error)
        XCTAssertTrue(headless.notifications.isEmpty)
        XCTAssertNil(headless.clipboard)
        XCTAssertNil(headless.keepAwake)
        XCTAssertEqual(headless.logs.first?.text, "falsefalse")
        // スクリプトから取り出せない(読む関数はない)
        let read = load("function setup() { console.log(typeof clipboard.read + typeof clipboard.paste + String(Object.isFrozen(notify))); }")
        XCTAssertEqual(read.logs.first?.text, "undefinedundefinedtrue")
    }

    func testSecureRandom() {
        for _ in 0..<1000 {
            let value = ScriptSecureRandom.next()
            XCTAssertTrue((0..<1).contains(value))
        }
        let output = load("""
        function setup() {
          var ok = true, seen = {};
          for (var i = 0; i < 2000; i++) {
            var v = random.secureInt(3, 7), f = random.secure();
            if (v < 3 || v > 7 || v !== Math.floor(v) || f < 0 || f >= 1) ok = false;
            seen[v] = true;
          }
          random.seed(1);
          var a = random.secure(); random.seed(1);
          console.log(String(ok) + Object.keys(seen).length + String(a !== random.secure()));
        }
        """, headless: true)
        XCTAssertNil(output.error)
        XCTAssertEqual(output.logs.first?.text, "true5true")
    }

    func testMultilineTextControls() throws {
        let spec = try ScriptControlSpec.parse(["id": "memo", "type": "text", "multiline": true, "keyboard": "decimal", "placeholder": "ここに",
                                                "value": String(repeating: "x", count: 6000)], path: "controls[0]").get()
        XCTAssertTrue(spec.multiline)
        XCTAssertEqual(spec.keyboard, .decimal)
        XCTAssertEqual(spec.placeholder, "ここに")
        XCTAssertEqual(spec.maxLength, ScriptControlSpec.maxMultilineLength)
        XCTAssertEqual(spec.value, .text(String(repeating: "x", count: 5000)))
        let single = try ScriptControlSpec.parse(["id": "name", "type": "text", "value": String(repeating: "y", count: 300)], path: "c").get()
        XCTAssertFalse(single.multiline)
        XCTAssertEqual(single.keyboard, .text)
        XCTAssertEqual(single.value, .text(String(repeating: "y", count: 200)))
        guard case .failure(let issue) = ScriptControlSpec.parse(["id": "a", "type": "text", "keyboard": "phone"], path: "controls[1]") else {
            return XCTFail("知らないキーボードは誤り")
        }
        XCTAssertEqual(issue.path, "controls[1].keyboard")
        // ui.set の長さは、その欄の上限まで
        let long = String(repeating: "z", count: 6000)
        let applied = ScriptUIChange.apply([.set(id: "memo", value: .text(long)), .set(id: "name", value: .text(long))], to: [spec, single])
        XCTAssertEqual(applied[0].value, .text(String(repeating: "z", count: 5000)))
        XCTAssertEqual(applied[1].value, .text(String(repeating: "z", count: 200)))
        // スクリプトの ui.text から
        let output = load("function setup() { ui.text('memo', { label: 'メモ', multiline: true, keyboard: 'number', value: 'a' }); }")
        guard case .add(let added)? = output.uiChanges.first else { return XCTFail("部品が足されるはず") }
        XCTAssertTrue(added.multiline)
        XCTAssertEqual(added.keyboard, .number)
    }
}

/// 「撮って聞く」で撮って囲んだあとの分かれ方(v0.9.31 の残り)
final class ScopeAskUseTests: XCTestCase {
    func testChoices() {
        XCTAssertEqual(ScopeAskUse.choices(isRestored: true, photoCount: 0, isComposing: false), [])
        let first = ScopeAskUse.choices(isRestored: false, photoCount: 0, isComposing: false)
        XCTAssertEqual(first.map(\.kind), [.ask, .makeObject])
        XCTAssertEqual(first.map(\.label), ["聞く", "オブジェクトを作る"])
        XCTAssertTrue(first.allSatisfy(\.isEnabled))
        let more = ScopeAskUse.choices(isRestored: false, photoCount: 2, isComposing: false)
        XCTAssertEqual(more[1].label, "オブジェクトの写真に足す(3/3)")
        XCTAssertTrue(more[1].isEnabled)
        // 3枚あるとき・作っている途中は、オブジェクトを押せない(聞くは押せる)
        let full = ScopeAskUse.choices(isRestored: false, photoCount: 3, isComposing: false)
        XCTAssertEqual(full.map(\.isEnabled), [true, false])
        XCTAssertEqual(ScopeAskUse.choices(isRestored: false, photoCount: 1, isComposing: true).map(\.isEnabled), [true, false])
    }

    @MainActor
    func testUseForObjectAddsUpToThreePhotos() throws {
        let name = "ScopeAskUseTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("askuse-\(UUID().uuidString)").appendingPathComponent("objects.json")
        let job = ObjectComposeJob(defaults: defaults, fileURL: url)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        // 「聞く」を選んだときは、オブジェクトの写真に何も足さない(作る画面も開かない)
        XCTAssertTrue(job.photos.isEmpty)
        XCTAssertFalse(job.opensPhotoComposer)
        for count in 1...3 {
            job.opensPhotoComposer = false
            XCTAssertTrue(ScopeAskUse.useForObject(compose: job, image: image, shape: [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 1), CGPoint(x: 5, y: 5)]))
            XCTAssertEqual(job.photos.count, count)
            XCTAssertTrue(job.opensPhotoComposer)
            XCTAssertTrue(job.isCollectingPhotos)
        }
        // 4枚目は足さず、作る画面も開かない(聞く画面は閉じない)
        job.opensPhotoComposer = false
        XCTAssertFalse(ScopeAskUse.useForObject(compose: job, image: image, shape: nil))
        XCTAssertEqual(job.photos.count, ObjectPhotoImage.maxPhotos)
        XCTAssertFalse(job.opensPhotoComposer)
        XCTAssertEqual(ScopeAskUse.choices(isRestored: false, photoCount: job.photos.count, isComposing: job.isRunning)[1].isEnabled, false)
        defaults.removePersistentDomain(forName: name)
    }
}

import CoreGraphics
import XCTest
@testable import SmartDashboard

/// 方角の手動補正(方角の計算・東西南北の印・目印に合わせる計算)
final class HeadingCorrectionTests: XCTestCase {
    private let size = CGSize(width: 375, height: 667)
    private let tangents = (horizontal: 0.6, vertical: 1.0)

    private func camera(azimuth: Double, elevation: Double = 0) -> CameraAttitude {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        let forward = Vector3(x: cos(e) * cos(a), y: -cos(e) * sin(a), z: sin(e))
        let right = Vector3(x: cos(a + .pi / 2), y: -sin(a + .pi / 2), z: 0)
        return CameraAttitude(right: right, up: Vector3.cross(right, forward), forward: forward)
    }

    override func tearDown() {
        HeadingCorrection.current = 0
        super.tearDown()
    }

    func testNormalizeApplyAndText() {
        XCTAssertEqual(HeadingCorrection.normalized(190), -170)
        XCTAssertEqual(HeadingCorrection.normalized(-180), 180)
        XCTAssertEqual(HeadingCorrection.normalized(540), 180)
        XCTAssertEqual(HeadingCorrection.normalized(12.34), 12.3)
        XCTAssertEqual(HeadingCorrection.apply(350, offset: 20), 10, accuracy: 1e-9)
        XCTAssertEqual(HeadingCorrection.apply(10, offset: -20), 350, accuracy: 1e-9)
        XCTAssertEqual(HeadingCorrection.text(12), "補正 +12°")
        XCTAssertEqual(HeadingCorrection.text(-7.5), "補正 -7.5°")
        XCTAssertNil(HeadingCorrection.text(0))
    }

    func testCorrectedAttitudeMovesCompassRose() {
        // 端末は北と言っているが、実際は東を向いている(磁気センサーが90°ずれた)。補正 +90° で「東」が中央に来る
        let raw = camera(azimuth: 0, elevation: 5)
        let corrected = raw.rotatedClockwise(by: 90)
        XCTAssertEqual(corrected.azimuth, 90, accuracy: 1e-9)
        XCTAssertEqual(corrected.elevation, raw.elevation, accuracy: 1e-9)
        let marks = ScopeCompassRose.marks(attitude: corrected, tangents: tangents, size: size)
        XCTAssertEqual(marks.first { $0.name == "東" }?.point.x ?? -1, size.width / 2, accuracy: 1e-6)
        XCTAssertNil(marks.first { $0.name == "北" })
        // 地点の投影も同じだけ動く(東にある地点が中央)
        let point = WaypointProjection.point(bearing: 90, attitude: corrected, tangents: tangents, viewSize: size)
        XCTAssertEqual(point?.x ?? -1, size.width / 2, accuracy: 1e-6)
    }

    func testAlignToLandmark() {
        // 今の補正 +5° で、カメラの方角は 100°。中央に合わせた山の本当の方角は 112° → 補正は +17°
        XCTAssertEqual(HeadingCorrection.aligned(offset: 5, currentAzimuth: 100, targetBearing: 112), 17, accuracy: 1e-9)
        // 0°をまたぐとき
        XCTAssertEqual(HeadingCorrection.aligned(offset: 0, currentAzimuth: 355, targetBearing: 5), 10, accuracy: 1e-9)
        XCTAssertEqual(HeadingCorrection.aligned(offset: 170, currentAzimuth: 0, targetBearing: 20), -170, accuracy: 1e-9)
        // 合わせたあとの補正で、その目印がちょうど中央に来る
        let rawAzimuth = 95.0
        let offset = HeadingCorrection.aligned(offset: 5, currentAzimuth: rawAzimuth + 5, targetBearing: 112)
        XCTAssertEqual(HeadingCorrection.apply(rawAzimuth, offset: offset), 112, accuracy: 1e-9)
        // 中央に一番近い目印(25°以内)
        let landmarks = [HeadingCorrection.Landmark(name: "富士山", bearing: 250), HeadingCorrection.Landmark(name: "塔", bearing: 262),
                         HeadingCorrection.Landmark(name: "家", bearing: 10)]
        XCTAssertEqual(HeadingCorrection.nearest(landmarks, azimuth: 255)?.name, "富士山")
        XCTAssertEqual(HeadingCorrection.nearest(landmarks, azimuth: 350)?.name, "家")
        XCTAssertNil(HeadingCorrection.nearest(landmarks, azimuth: 120))
    }

    @MainActor
    func testSettingIsSavedAndApplied() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "HeadingCorrectionTests"))
        defaults.removePersistentDomain(forName: "HeadingCorrectionTests")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.headingOffset, 0)
        settings.headingOffset = 12
        XCTAssertEqual(HeadingCorrection.current, 12)
        XCTAssertEqual(AppSettings(defaults: defaults).headingOffset, 12)
        // 範囲の外は、保存と反映のときに丸める
        settings.headingOffset = 200
        XCTAssertEqual(HeadingCorrection.current, -160)
        XCTAssertEqual(AppSettings(defaults: defaults).headingOffset, -160)
        defaults.removePersistentDomain(forName: "HeadingCorrectionTests")
    }
}

/// 「最近作ったもの」の保存・上限・読み込み
@MainActor
final class ClaudeRecentsTests: XCTestCase {
    private struct Entry: ClaudeRecentEntry {
        var id = UUID()
        var createdAt: Date
        var text: String
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("recents-\(UUID().uuidString)").appendingPathComponent(name)
    }

    private func defaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testUpsertKeepsNewestTen() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var list: [Entry] = []
        for index in 0..<12 {
            list = ClaudeRecentList.upserting(Entry(createdAt: base.addingTimeInterval(Double(index)), text: "\(index)"), into: list)
        }
        XCTAssertEqual(list.count, ClaudeRecentList.limit)
        XCTAssertEqual(list.map(\.text), (2..<12).reversed().map { "\($0)" })
        // 同じ ID は置き換え(数は増えない)
        var changed = list[3]
        changed.text = "変えた"
        list = ClaudeRecentList.upserting(changed, into: list)
        XCTAssertEqual(list.count, 10)
        XCTAssertEqual(list.first { $0.id == changed.id }?.text, "変えた")
    }

    func testSaveAndLoad() throws {
        let url = temporaryURL("entries.json")
        let recents = ClaudeRecents<Entry>(fileURL: url)
        let first = Entry(createdAt: Date(timeIntervalSince1970: 100), text: "古い")
        let second = Entry(createdAt: Date(timeIntervalSince1970: 200), text: "新しい")
        recents.upsert(first)
        recents.upsert(second)
        let reloaded = ClaudeRecents<Entry>(fileURL: url)
        XCTAssertEqual(reloaded.entries.map(\.text), ["新しい", "古い"])
        reloaded.remove(second.id)
        XCTAssertEqual(ClaudeRecents<Entry>(fileURL: url).entries.map(\.text), ["古い"])
        // 壊れたファイルは空として読む
        try Data("壊れた".utf8).write(to: url)
        XCTAssertTrue(ClaudeRecents<Entry>(fileURL: url).entries.isEmpty)
        XCTAssertTrue(ClaudeRecentList.decode(nil, as: Entry.self).isEmpty)
    }

    func testObjectRecordRoundTrip() throws {
        let json = #"{"format":1,"type":"scope-object","name":"塔","shapes":[{"kind":"box","width":10,"depth":10,"height":10},{"kind":"box","width":2,"depth":2,"height":2,"z":4}]}"#
        guard case .success(let object) = ObjectCodec.parse(json) else { return XCTFail("読めない") }
        var outcome = ObjectGenerator.Outcome(object: object, json: json, issues: [], usage: ClaudeUsage(input: 10, output: 20), cost: 0.02,
                                              attempts: 1, detail: .veryDetailed)
        outcome.dimensions = [ObjectDimension(id: 0, label: "全高", value: "10m")]
        outcome.hiddenShapes = [1]
        outcome.citations = [ClaudeCitation(title: "ページ", url: "https://example.com", citedText: "")]
        let record = ObjectComposeRecord(outcome: outcome, instruction: "赤い塔", webSearch: true, createdAt: Date(timeIntervalSince1970: 1_000_000))
        let data = try XCTUnwrap(ClaudeRecentList.encode([record]))
        let decoded = ClaudeRecentList.decode(data, as: ObjectComposeRecord.self)
        XCTAssertEqual(decoded, [record])
        let restored = decoded[0].outcome
        XCTAssertEqual(restored.object?.shapes.count, 2)
        XCTAssertEqual(restored.dimensions.map(\.label), ["全高"])
        XCTAssertEqual(restored.hiddenShapes, [1])
        XCTAssertEqual(restored.detail, .veryDetailed)
        XCTAssertEqual(restored.cost, 0.02, accuracy: 1e-9)
    }

    func testObjectJobKeepsInputAndResults() async throws {
        let defaults = try defaults("ObjectComposeJobTests")
        let url = temporaryURL("objects.json")
        let job = ObjectComposeJob(defaults: defaults, fileURL: url)
        XCTAssertEqual(job.detail, .veryDetailed)
        XCTAssertFalse(job.webSearch)
        job.instruction = "東京タワー"
        job.detailRaw = ObjectDetail.normal.rawValue
        job.webSearch = true
        // 入力は残る
        let reopened = ObjectComposeJob(defaults: defaults, fileURL: url)
        XCTAssertEqual(reopened.instruction, "東京タワー")
        XCTAssertEqual(reopened.detail, .normal)
        XCTAssertTrue(reopened.webSearch)
        // 画面を閉じている間に作り終わったら「できました」
        let json = #"{"format":1,"type":"scope-object","name":"塔","shapes":[{"kind":"box"}]}"#
        job.start(model: "m", thinking: false) { _, _ in
            ClaudeCallResult(response: ClaudeResponse(text: json, usage: ClaudeUsage(input: 1, output: 1), stopReason: "end_turn", model: "m"),
                             cost: 0.01)
        }
        for _ in 0..<200 where job.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(job.isRunning)
        let id = try XCTUnwrap(job.unseenID)
        XCTAssertEqual(job.recents.entries.first?.instruction, "東京タワー")
        // 再起動しても残る
        XCTAssertEqual(ObjectComposeJob(defaults: defaults, fileURL: url).recents.entries.map(\.id), [id])
        // 画面を開くと見たことになる
        job.isShowing = true
        XCTAssertNil(job.unseenID)
        XCTAssertEqual(job.viewingID, id)
        job.markSaved(id)
        XCTAssertNotNil(job.recents.entry(id)?.savedAt)
        job.discard(id)
        XCTAssertTrue(job.recents.entries.isEmpty)
        XCTAssertNil(job.viewingID)
        defaults.removePersistentDomain(forName: "ObjectComposeJobTests")
    }

    func testObjectJobCancel() async throws {
        let defaults = try defaults("ObjectComposeJobCancel")
        let job = ObjectComposeJob(defaults: defaults, fileURL: temporaryURL("objects.json"))
        job.instruction = "塔"
        job.start(model: "m", thinking: false) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
        XCTAssertTrue(job.isRunning)
        job.cancel()
        for _ in 0..<200 where job.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(job.isRunning)
        XCTAssertNotNil(job.errorText)
        XCTAssertTrue(job.recents.entries.isEmpty)
        defaults.removePersistentDomain(forName: "ObjectComposeJobCancel")
    }

    func testToolJobDraftsPerModeAndRecord() throws {
        let defaults = try defaults("ToolComposeJobTests")
        let url = temporaryURL("tools.json")
        let job = ToolComposeJob(defaults: defaults, fileURL: url)
        job.instruction = "燃費の計算"
        job.prepare(.revise(json: "{}", id: "tool.a"))
        XCTAssertEqual(job.instruction, "")
        job.instruction = "単価を足して"
        job.prepare(.create)
        XCTAssertEqual(job.instruction, "燃費の計算")
        // 再起動しても、作る / 直すツールごとに残る
        let reopened = ToolComposeJob(defaults: defaults, fileURL: url)
        XCTAssertEqual(reopened.instruction, "燃費の計算")
        reopened.prepare(.revise(json: "{}", id: "tool.a"))
        XCTAssertEqual(reopened.instruction, "単価を足して")
        // 結果の記録(誤りが残ったもの)
        let generation = ToolGeneration(outcome: .invalid(json: "{}", issues: [ToolIssue(path: "name", message: "名前が必要です")]),
                                        usage: ClaudeUsage(input: 1, output: 2), cost: 0.03, attempts: 2)
        let record = ToolComposeRecord(generation: generation, instruction: "単価を足して", mode: .revise(json: "{}", id: "tool.a"),
                                       createdAt: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertFalse(record.isValid)
        XCTAssertNil(record.tool)
        XCTAssertEqual(record.mode, .revise(json: "{}", id: "tool.a"))
        job.finish(record)
        XCTAssertEqual(job.unseenID, record.id)
        XCTAssertEqual(ToolComposeJob(defaults: defaults, fileURL: url).recents.entries, [record])
        defaults.removePersistentDomain(forName: "ToolComposeJobTests")
    }

    private func sampleImage(width: Int = 1280, height: Int = 720) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testScopeAskKeepsConversationWithSmallImage() async throws {
        let url = temporaryURL("scope-ask.json")
        let job = ScopeAskJob(fileURL: url)
        let snapshot = ScopeAskSnapshot(image: try sampleImage(), heading: 120, pitch: 3, latitude: 35.68, longitude: 139.76, placeName: nil,
                                        targets: [], takenAt: Date(), halfFieldOfView: 30)
        job.begin(snapshot)
        // 聞く前は残さない
        XCTAssertTrue(job.recents.entries.isEmpty)
        job.send(question: "これは何？", settings: ClaudeSettings(), imageEdge: 512, blockReason: nil) { _ in
            ClaudeCallResult(response: ClaudeResponse(text: "塔です", usage: ClaudeUsage(input: 10, output: 5), stopReason: "end_turn", model: "m"),
                             cost: 0.004)
        }
        XCTAssertTrue(job.isThinking)
        for _ in 0..<200 where job.isThinking { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(job.live?.exchanges.first?.answer, "塔です")
        XCTAssertTrue(job.hasUnseenAnswer)
        // 再起動しても残り、画像は縮めたもの
        let reloaded = ScopeAskJob(fileURL: url)
        let record = try XCTUnwrap(reloaded.recents.entries.first)
        XCTAssertEqual(record.exchanges.first?.answer, "塔です")
        XCTAssertEqual(record.cost, 0.004, accuracy: 1e-9)
        XCTAssertEqual(record.heading, 120)
        let thumbnail = try XCTUnwrap(ScopeAskRecord.image(record.thumbnail))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), ScopeAskRecord.thumbnailEdge)
        // 開き直すと、会話と縮めた画像で続けられる
        reloaded.open(record)
        XCTAssertEqual(reloaded.live?.isRestored, true)
        XCTAssertEqual(reloaded.live?.exchanges.count, 1)
        XCTAssertEqual(reloaded.live?.snapshot.heading, 120)
        // 捨てると一覧からも消える
        reloaded.discardCurrent()
        XCTAssertNil(reloaded.live)
        XCTAssertTrue(ScopeAskJob(fileURL: url).recents.entries.isEmpty)
    }
}

import CoreGraphics
import ImageIO
import XCTest
@testable import SmartDashboard

/// 「撮って聞く」v0.9.20: 位置を送らない初期値、Web 検索、場所の読み取りと方角の照合、サンプルの同梱
final class ScopeAskPrivacyTests: XCTestCase {
    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return try XCTUnwrap(context.makeImage())
    }

    private func snapshot() throws -> ScopeAskSnapshot {
        ScopeAskSnapshot(image: try image(), heading: 90, pitch: -5, latitude: 35.68123, longitude: 139.76712, placeName: "東京都千代田区",
                         targets: [ScopeAskTarget(name: "東京タワー", kind: "登録した地点", bearing: 200, distance: 3200, heightDifference: nil)],
                         takenAt: Date(timeIntervalSince1970: 0), halfFieldOfView: 30)
    }

    func testDefaultsSendNothingThatRevealsLocation() throws {
        let options = ScopeAskOptions(ClaudeSettings())
        let snapshot = try snapshot()
        let context = ScopeAsk.contextText(snapshot, options: options)
        // 方角と向きは送る(居場所は分からない)
        XCTAssertTrue(context.contains("東(90°)"))
        XCTAssertTrue(context.contains("下向き"))
        // 地名・緯度経度・周りの地点は送らない
        XCTAssertFalse(context.contains("千代田"))
        XCTAssertFalse(context.contains("35.68"))
        XCTAssertFalse(context.contains("139.76"))
        XCTAssertFalse(context.contains("東京タワー"))
        XCTAssertEqual(ScopeAsk.sentItems(snapshot, options: options), ["画像", "質問", "方角と向き"])
        XCTAssertEqual(ScopeAsk.sentSummary(ScopeAsk.sentItems(snapshot, options: options)), "画像・質問・方角と向きを送信")
        // 選べば送る(送ったものの表示にも出る)
        let all = ScopeAskOptions(heading: true, place: true, coordinates: true, targets: true)
        XCTAssertEqual(ScopeAsk.sentItems(snapshot, options: all), ["画像", "質問", "方角と向き", "地名", "緯度経度", "周りの地点の名前と距離"])
        // 地名がまだ分からなければ、地名は送ったことにしない
        var noName = snapshot
        noName.placeName = nil
        XCTAssertEqual(ScopeAsk.sentItems(noName, options: ScopeAskOptions(heading: false, place: true)), ["画像", "質問"])
    }

    func testOldSettingsAreMigratedToPrivateDefaults() throws {
        // v0.9.19 までの設定(privacyVersion がない)は、地名・緯度経度・周りの地点を送らない設定に合わせる
        let old = try JSONDecoder().decode(ClaudeSettings.self, from: Data(#"{"sendsPlace":true,"sendsCoordinates":true,"sendsTargets":true,"sendsHeading":false}"#.utf8))
        XCTAssertFalse(old.sendsPlace || old.sendsCoordinates || old.sendsTargets)
        XCTAssertFalse(old.sendsHeading)
        XCTAssertEqual(old.privacyVersion, ClaudeSettings.currentPrivacyVersion)
        XCTAssertTrue(old.webSearch)
        XCTAssertEqual(old.webSearchMaxUses, 3)
        // 新しい版で、利用者が選んで送るようにした設定は、そのまま
        var chosen = ClaudeSettings()
        chosen.sendsPlace = true
        chosen.sendsTargets = true
        let reloaded = try JSONDecoder().decode(ClaudeSettings.self, from: JSONEncoder().encode(chosen))
        XCTAssertTrue(reloaded.sendsPlace && reloaded.sendsTargets)
        // 検索の上限は 1〜10 に収める
        let large = try JSONDecoder().decode(ClaudeSettings.self, from: Data(#"{"privacyVersion":2,"webSearchMaxUses":99}"#.utf8))
        XCTAssertEqual(large.webSearchMaxUses, ClaudeSettings.maxWebSearches)
    }

    func testJPEGHasNoLocationMetadata() throws {
        let jpeg = try XCTUnwrap(ScopeAskImage.prepare(try image(), shape: nil, maxEdge: 1024))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel])
    }
}

final class ScopeAskSearchTests: XCTestCase {
    func testWebSearchToolAndPricing() throws {
        var settings = ClaudeSettings()
        settings.webSearchMaxUses = 4
        let request = ScopeAsk.request(messages: [.user("q")], settings: settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body()) as? [String: Any])
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "web_search_20250305")
        XCTAssertEqual(tools[0]["name"] as? String, "web_search")
        XCTAssertEqual(tools[0]["max_uses"] as? Int, 4)
        // 検索の言葉に現在地を入れないよう、system prompt で指示する
        XCTAssertTrue(request.system.contains("現在地・地名・住所・緯度経度を、検索の言葉に入れないで"))
        XCTAssertTrue(request.system.contains("<place>"))
        // 検索を使わない設定では、ツールを渡さない
        settings.webSearch = false
        let plain = ScopeAsk.request(messages: [.user("q")], settings: settings)
        XCTAssertNil(plain.webSearchMaxUses)
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plain.body()) as? [String: Any])
        XCTAssertNil(plainObject["tools"])
        XCTAssertFalse(plain.system.contains("Web 検索:"))
        // 料金: 検索1回 0.01ドル(1,000回あたり10ドル)を足す
        XCTAssertEqual(ClaudePricing().cost(ClaudeUsage(webSearches: 3)), 0.03, accuracy: 1e-12)
        XCTAssertEqual(ClaudePricing().cost(ClaudeUsage(input: 1_000_000, webSearches: 1)), 0.11, accuracy: 1e-12)
        var ledger = ClaudeLedger()
        let usage = ClaudeUsage(input: 100, webSearches: 2)
        ledger.add(usage, cost: ClaudePricing().cost(usage), at: Date())
        XCTAssertEqual(ledger.month(Date()).usage.webSearches, 2)
        XCTAssertEqual(ledger.month(Date()).cost, 0.02 + 0.00001, accuracy: 1e-9)
        XCTAssertTrue(ClaudeUsage(webSearches: 2).summary.contains("Web検索 2回"))
        // 以前の版の記録と料金の設定(webSearches・webSearchPer1000 がない)も読める
        XCTAssertEqual(try JSONDecoder().decode(ClaudeUsage.self, from: Data(#"{"input":5,"output":6,"cacheWrite":0,"cacheRead":0,"thinking":1}"#.utf8)),
                       ClaudeUsage(input: 5, output: 6, thinking: 1))
        XCTAssertEqual(try JSONDecoder().decode(ClaudePricing.self, from: Data(#"{"input":1,"output":2,"cacheWrite":3,"cacheRead":4}"#.utf8)).webSearchPer1000, 10)
        let oldLedger = try JSONDecoder().decode(ClaudeLedger.self, from: Data(#"{"months":{"2026-10":{"usage":{"input":1,"output":2,"cacheWrite":0,"cacheRead":0,"thinking":0},"cost":0.5,"calls":1}}}"#.utf8))
        XCTAssertEqual(oldLedger.months["2026-10"]?.calls, 1)
    }

    func testParseSearchResponse() throws {
        let response = try HTTPClaudeClient.decode(data: Fixture.data("claude_message_search"), status: 200)
        XCTAssertEqual(response.usage.webSearches, 2)
        XCTAssertEqual(response.usage.thinking, 500)
        // 出典は URL ごとに1つ、出てきた順
        XCTAssertEqual(response.citations.map(\.url), ["https://example.com/tower", "https://example.org/guide"])
        XCTAssertEqual(response.citations.first?.title, "Example Tower")
        XCTAssertEqual(response.searchErrors, ["max_uses_exceeded"])
        // 受け取ったブロックを、そのまま送り返せるように持つ
        XCTAssertEqual(response.rawContent.count, 8)
        let extracted = ScopeAskPlace.extract(from: response.text)
        XCTAssertFalse(extracted.answer.contains("<place>"))
        XCTAssertTrue(extracted.answer.hasSuffix("可能性があります。"))
        XCTAssertEqual(extracted.place?.name, "東京タワー")
        XCTAssertEqual(extracted.place?.confidence, .high)
    }

    /// 決まった答えを順に返す
    private final class Script {
        var results: [Result<ClaudeResponse, Error>]
        var requests: [ClaudeRequest] = []

        init(_ results: [Result<ClaudeResponse, Error>]) {
            self.results = results
        }

        func call(_ request: ClaudeRequest) throws -> ClaudeCallResult {
            requests.append(request)
            let response = try results.removeFirst().get()
            return ClaudeCallResult(response: response, cost: ClaudePricing().cost(response.usage))
        }
    }

    func testPauseTurnIsContinuedWithRawContent() async throws {
        let paused = ClaudeResponse(text: "途中", usage: ClaudeUsage(input: 100, webSearches: 1), stopReason: "pause_turn", model: nil,
                                    citations: [ClaudeCitation(title: "A", url: "https://a.example", citedText: "")],
                                    rawContent: [Data(#"{"type":"text","text":"途中"}"#.utf8)])
        let done = ClaudeResponse(text: "の続き", usage: ClaudeUsage(input: 50, webSearches: 1), stopReason: "end_turn", model: nil,
                                  citations: [ClaudeCitation(title: "A", url: "https://a.example", citedText: ""),
                                              ClaudeCitation(title: "B", url: "https://b.example", citedText: "")])
        let script = Script([.success(paused), .success(done)])
        let request = ScopeAsk.request(messages: [.user("q")], settings: ClaudeSettings())
        let answer = try await ScopeAsk.ask(request) { try script.call($0) }
        XCTAssertEqual(answer.response.text, "途中の続き")
        XCTAssertEqual(answer.response.usage.webSearches, 2)
        XCTAssertEqual(answer.response.citations.map(\.url), ["https://a.example", "https://b.example"])
        XCTAssertEqual(answer.cost, 0.02 + 150 * 0.10 / 1_000_000, accuracy: 1e-12)
        XCTAssertFalse(answer.searchFallback)
        // 2回目は、受け取った内容をそのまま assistant として足し、同じツールで送る
        XCTAssertEqual(script.requests.count, 2)
        XCTAssertEqual(script.requests[1].messages.last, ClaudeMessage(role: .assistant, content: [.raw(Data(#"{"type":"text","text":"途中"}"#.utf8))]))
        XCTAssertEqual(script.requests[1].webSearchMaxUses, 3)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: script.requests[1].body()) as? [String: Any])
        let last = try XCTUnwrap((body["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        XCTAssertEqual(last.first?["text"] as? String, "途中")
    }

    func testFallbackWithoutSearchOnBadRequest() async throws {
        let ok = ClaudeResponse(text: "答え", usage: ClaudeUsage(input: 10), stopReason: "end_turn", model: nil)
        let script = Script([.failure(ClaudeError.badRequest("(web search is not enabled)")), .success(ok)])
        let answer = try await ScopeAsk.ask(ScopeAsk.request(messages: [.user("q")], settings: ClaudeSettings())) { try script.call($0) }
        XCTAssertTrue(answer.searchFallback)
        XCTAssertEqual(answer.response.text, "答え")
        XCTAssertNil(script.requests[1].webSearchMaxUses)
        XCTAssertFalse(script.requests[1].system.contains("Web 検索:"))
        // 検索を使っていない依頼の 400 は、そのまま失敗にする
        var settings = ClaudeSettings()
        settings.webSearch = false
        let failing = Script([.failure(ClaudeError.badRequest("x"))])
        do {
            _ = try await ScopeAsk.ask(ScopeAsk.request(messages: [.user("q")], settings: settings)) { try failing.call($0) }
            XCTFail("失敗になるはず")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .badRequest("x"))
        }
    }
}

final class ScopeAskPlaceTests: XCTestCase {
    private let observer = GeoPoint(35.68, 139.76)

    func testParsePlace() {
        let identified = ScopeAskPlace.parse(#"{"identified": true, "name": "東京タワー", "latitude": 35.6586, "longitude": 139.7454, "confidence": "Medium", "reason": "形"}"#)
        XCTAssertEqual(identified?.hasCoordinate, true)
        XCTAssertEqual(identified?.confidence, .medium)
        XCTAssertEqual(identified?.latitude ?? 0, 35.6586, accuracy: 1e-9)
        // 文字で書かれた数も読む。確からしさがなければ低。
        XCTAssertEqual(ScopeAskPlace.parse(#"{"identified": true, "name": "X", "latitude": "35.1", "longitude": "139.2"}"#)?.confidence, .low)
        // 特定できない(座標を作らない)
        let unknown = ScopeAskPlace.parse(#"{"identified": false, "reason": "ありふれた看板"}"#)
        XCTAssertEqual(unknown?.identified, false)
        XCTAssertEqual(unknown?.hasCoordinate, false)
        XCTAssertEqual(unknown?.reason, "ありふれた看板")
        // 特定したと言っていても、座標がない・範囲の外・0,0・名前がないなら、特定できないとして扱う
        XCTAssertEqual(ScopeAskPlace.parse(#"{"identified": true, "name": "X"}"#)?.hasCoordinate, false)
        XCTAssertEqual(ScopeAskPlace.parse(#"{"identified": true, "name": "X", "latitude": 95, "longitude": 10}"#)?.hasCoordinate, false)
        XCTAssertEqual(ScopeAskPlace.parse(#"{"identified": true, "name": "X", "latitude": 0, "longitude": 0}"#)?.hasCoordinate, false)
        XCTAssertEqual(ScopeAskPlace.parse(#"{"identified": true, "latitude": 35, "longitude": 139}"#)?.hasCoordinate, false)
        XCTAssertNil(ScopeAskPlace.parse("読めない"))
        // 答えの文から取り出し、表示からは消す
        let extracted = ScopeAskPlace.extract(from: "答えです。\n<place>{\"identified\": false, \"reason\": \"室内\"}</place>\n")
        XCTAssertEqual(extracted.answer, "答えです。")
        XCTAssertEqual(extracted.place?.identified, false)
        let none = ScopeAskPlace.extract(from: "  形のない答え  ")
        XCTAssertEqual(none.answer, "形のない答え")
        XCTAssertNil(none.place)
        let broken = ScopeAskPlace.extract(from: "答え<place>{壊れた</place>")
        XCTAssertEqual(broken.answer, "答え")
        XCTAssertNil(broken.place)
    }

    private func place(east: Double, north: Double) -> ScopeAskPlace {
        let point = GeoMath.offset(observer, east: east, north: north)
        return ScopeAskPlace(identified: true, name: "P", latitude: point.latitude, longitude: point.longitude, confidence: .high, reason: "")
    }

    func testDirectionCheck() throws {
        let east = place(east: 1000, north: 0)
        func check(_ heading: Double?, half: Double? = 30, latitude: Double? = 35.68, longitude: Double? = 139.76) -> ScopeAskPlaceCheck? {
            ScopeAskPlaceCheck.evaluate(place: east, observerLatitude: latitude, observerLongitude: longitude, heading: heading, halfFieldOfView: half)
        }
        let straight = try XCTUnwrap(check(90))
        XCTAssertEqual(straight.direction, .inView)
        XCTAssertEqual(straight.bearing ?? 0, 90, accuracy: 0.5)
        XCTAssertEqual(straight.distance ?? 0, 1000, accuracy: 5)
        XCTAssertEqual(straight.distanceNote, .normal)
        XCTAssertFalse(straight.isWarning)
        // 写る範囲(±30°)の少し外
        guard case .nearEdge(let edge) = try XCTUnwrap(check(45)).direction else { return XCTFail("少し外のはず") }
        XCTAssertEqual(edge, 15, accuracy: 0.5)
        // 30°以上外れたら「撮った方向と合いません」
        let wrong = try XCTUnwrap(check(0))
        guard case .mismatch(let off) = wrong.direction else { return XCTFail("合わないはず") }
        XCTAssertEqual(off, 60, accuracy: 0.5)
        XCTAssertTrue(wrong.isWarning)
        XCTAssertTrue(wrong.lines.contains { $0.contains("撮った方向と合いません") })
        // 北をまたぐ向き(350°と 20°)も、差は30°
        let north = place(east: 0, north: 1000)
        let across = ScopeAskPlaceCheck.evaluate(place: north, observerLatitude: 35.68, observerLongitude: 139.76, heading: 350, halfFieldOfView: 30)
        XCTAssertEqual(across?.direction, .inView)
        // 向きか位置が分からなければ、確かめられない
        XCTAssertEqual(try XCTUnwrap(check(nil)).direction, .unknown)
        XCTAssertEqual(try XCTUnwrap(check(90, latitude: nil, longitude: nil)).direction, .unknown)
        // 写る範囲が分からなければ、±30°とみなす
        XCTAssertEqual(try XCTUnwrap(check(110, half: nil)).direction, .inView)
        // 近すぎる・遠すぎる(目安)
        let close = ScopeAskPlaceCheck.evaluate(place: place(east: 3, north: 0), observerLatitude: 35.68, observerLongitude: 139.76, heading: 0, halfFieldOfView: 30)
        XCTAssertEqual(close?.distanceNote, .tooClose)
        XCTAssertEqual(close?.direction, .unknown)
        let far = ScopeAskPlaceCheck.evaluate(place: place(east: 400_000, north: 0), observerLatitude: 35.68, observerLongitude: 139.76, heading: 90, halfFieldOfView: 30)
        XCTAssertEqual(far?.distanceNote, .tooFar)
        XCTAssertEqual(far?.isWarning, true)
        // 座標のない場所は確かめない
        XCTAssertNil(ScopeAskPlaceCheck.evaluate(place: ScopeAskPlace(identified: false, name: "", latitude: nil, longitude: nil, confidence: nil, reason: ""),
                                                 observerLatitude: 35.68, observerLongitude: 139.76, heading: 0, halfFieldOfView: 30))
    }

    func testMemoKeepsReasonAndSources() {
        let memo = ScopeAskPlaceMemo.text(place: ScopeAskPlace(identified: true, name: "T", latitude: 1, longitude: 2, confidence: .medium, reason: "赤い鉄塔"),
                                          citations: [ClaudeCitation(title: "Example", url: "https://example.com/t", citedText: "")])
        XCTAssertTrue(memo.contains("確からしさ: 中"))
        XCTAssertTrue(memo.contains("根拠: 赤い鉄塔"))
        XCTAssertTrue(memo.contains("https://example.com/t"))
    }

    func testBundledSamples() {
        let samples = ToolSampleCatalog.bundled
        // examples/tools の11個(計算・表・チェックリスト・リストの5つと、スクリプト型の6つ)
        XCTAssertEqual(samples.count, 11)
        XCTAssertEqual(Set(samples.map(\.tool.id)).count, samples.count)
        XCTAssertEqual(samples.filter { $0.tool.kind == .script }.count, 6)
        XCTAssertTrue(samples.contains { $0.tool.id == "fuel-economy" })
        XCTAssertEqual(ToolSampleCatalog.load(Data("壊れた".utf8)), [])
    }
}

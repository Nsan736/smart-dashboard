import CoreGraphics
import XCTest
@testable import SmartDashboard

/// Claude API: 使用量と料金、月の上限、依頼の組み立て、応答とエラーの読み込み
final class ClaudeAPITests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        JapaneseHolidays.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testCostIncludesCacheAndThinking() {
        let usage = ClaudeUsage(input: 1000, output: 2000, cacheWrite: 3000, cacheRead: 4000, thinking: 1500)
        let pricing = ClaudePricing()
        // 1000×0.10 + 2000×0.50 + 3000×0.125 + 4000×0.01 = 1515(100万トークンあたりのドル)
        XCTAssertEqual(pricing.cost(usage), 0.001515, accuracy: 1e-12)
        // 思考は出力に含まれているので、二重には数えない
        var withoutThinking = usage
        withoutThinking.thinking = 0
        XCTAssertEqual(pricing.cost(withoutThinking), pricing.cost(usage))
        XCTAssertEqual(usage.totalInput, 8000)
        XCTAssertEqual(usage.total, 10_000)
        let sum = usage + usage
        XCTAssertEqual(sum, ClaudeUsage(input: 2000, output: 4000, cacheWrite: 6000, cacheRead: 8000, thinking: 3000))
        XCTAssertEqual(ClaudePricing.text(0.001515), "約0.0015ドル")
        XCTAssertEqual(ClaudePricing.text(1.234), "約1.23ドル")
        XCTAssertEqual(ClaudePricing.text(0), "0ドル")
        XCTAssertEqual(ClaudePricing.text(0.00001), "0.0001ドル未満")
        // 初期値は Claude Haiku 5.5 の料金
        XCTAssertEqual(pricing, ClaudePricing(input: 0.10, output: 0.50, cacheWrite: 0.125, cacheRead: 0.01))
        XCTAssertEqual(usage.summary, "入力 8,000(キャッシュ読込 4,000・書込 3,000)・出力 2,000(うち思考 1,500)")
    }

    func testLedgerByJapaneseMonth() {
        var ledger = ClaudeLedger()
        let october = date(2026, 10, 18)
        let usage = ClaudeUsage(input: 100, output: 50, cacheWrite: 10, cacheRead: 20, thinking: 30)
        ledger.add(usage, cost: 1.0, at: october)
        ledger.add(usage, cost: 2.5, at: october)
        XCTAssertEqual(ledger.month(october).cost, 3.5, accuracy: 1e-9)
        XCTAssertEqual(ledger.month(october).calls, 2)
        XCTAssertEqual(ledger.month(october).usage.thinking, 60)
        XCTAssertEqual(ClaudeLedger.monthKey(october), "2026-10")
        // 日本時間の11月1日0時30分は11月(UTC ではまだ10月)
        let earlyNovember = date(2026, 11, 1, 0, 30)
        XCTAssertEqual(ClaudeLedger.monthKey(earlyNovember), "2026-11")
        XCTAssertEqual(ledger.month(earlyNovember).calls, 0)
        // 直近12か月だけ残す
        for month in 1...12 { ledger.add(usage, cost: 0.1, at: date(2025, month, 10)) }
        XCTAssertEqual(ledger.months.count, ClaudeLedger.keptMonths)
        XCTAssertNotNil(ledger.months["2026-10"])
        XCTAssertNil(ledger.months["2025-01"])
    }

    func testGateOrder() {
        XCTAssertEqual(ClaudeGate.check(hasKey: false, spent: 0, limit: 5, isOnline: true), .missingKey)
        XCTAssertEqual(ClaudeGate.check(hasKey: true, spent: 5, limit: 5, isOnline: true), .overBudget(spent: 5, limit: 5))
        XCTAssertEqual(ClaudeGate.check(hasKey: true, spent: 6, limit: 5, isOnline: false), .overBudget(spent: 6, limit: 5))
        XCTAssertEqual(ClaudeGate.check(hasKey: true, spent: 4.99, limit: 5, isOnline: false), .offline)
        XCTAssertNil(ClaudeGate.check(hasKey: true, spent: 4.99, limit: 5, isOnline: true))
    }

    func testSettingsDefaultsAndOldData() throws {
        let defaults = ClaudeSettings()
        XCTAssertEqual(defaults.model, "claude-haiku-5-5")
        XCTAssertEqual(defaults.monthlyLimit, 5)
        XCTAssertTrue(defaults.thinkingForTools)
        XCTAssertTrue(defaults.thinkingForCamera)
        XCTAssertTrue(defaults.sendsHeading && defaults.sendsPlace && defaults.sendsCoordinates && defaults.sendsTargets)
        XCTAssertEqual(defaults.imageEdge(isExpensive: false), 1024)
        XCTAssertEqual(defaults.imageEdge(isExpensive: true), 768)
        // 足りない項目は初期値で読む
        let old = try JSONDecoder().decode(ClaudeSettings.self, from: Data(#"{"model":"claude-sonnet-5-5","monthlyLimit":2}"#.utf8))
        XCTAssertEqual(old.model, "claude-sonnet-5-5")
        XCTAssertEqual(old.monthlyLimit, 2)
        XCTAssertEqual(old.pricing, ClaudePricing())
        XCTAssertTrue(old.thinkingForCamera)
    }

    func testRequestBody() throws {
        let request = ClaudeRequest(model: "claude-haiku-5-5", system: "説明", cachesSystem: true,
                                    messages: [ClaudeMessage(role: .user, content: [.jpeg(Data([1, 2, 3])), .text("状況", cached: true), .text("質問")]),
                                               .assistant("答え"), .user("次")],
                                    maxTokens: 8000, thinking: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body()) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(object["max_tokens"] as? Int, 8000)
        XCTAssertEqual((object["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        let system = try XCTUnwrap(object["system"] as? [[String: Any]])
        XCTAssertEqual(system.first?["text"] as? String, "説明")
        XCTAssertEqual((system.first?["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let first = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        let source = try XCTUnwrap(first[0]["source"] as? [String: Any])
        XCTAssertEqual(first[0]["type"] as? String, "image")
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "AQID")
        XCTAssertNotNil(first[1]["cache_control"])
        XCTAssertNil(first[2]["cache_control"])

        // 思考なし、キャッシュなし
        var plain = request
        plain.thinking = false
        plain.cachesSystem = false
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: plain.body()) as? [String: Any])
        XCTAssertEqual((plainObject["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil((plainObject["system"] as? [[String: Any]])?.first?["cache_control"])

        // ヘッダー
        let urlRequest = try HTTPClaudeClient.urlRequest(request, apiKey: "test-key")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(urlRequest.timeoutInterval, HTTPClaudeClient.timeout)
    }

    func testResponseFixture() throws {
        let response = try HTTPClaudeClient.decode(data: Fixture.data("claude_message"), status: 200)
        // 思考の部分は使わず、text の部分をつなげる
        XCTAssertEqual(response.text, "画像から分かること: 赤い鉄塔が写っています。\n推測: 東京タワーの可能性があります。")
        XCTAssertEqual(response.usage, ClaudeUsage(input: 120, output: 640, cacheWrite: 0, cacheRead: 1450, thinking: 410))
        XCTAssertEqual(response.stopReason, "end_turn")
        XCTAssertEqual(response.model, "claude-haiku-5-5")
        // 拒否された応答
        let refusal = Data(#"{"content":[],"stop_reason":"refusal","usage":{"input_tokens":5,"output_tokens":1}}"#.utf8)
        XCTAssertThrowsError(try HTTPClaudeClient.decode(data: refusal, status: 200)) { XCTAssertEqual($0 as? ClaudeError, .refused) }
        XCTAssertThrowsError(try ClaudeResponse.parse(Data("not json".utf8))) { XCTAssertEqual($0 as? ClaudeError, .invalidResponse) }
    }

    func testErrors() throws {
        let body = try Fixture.data("claude_error")
        XCTAssertThrowsError(try HTTPClaudeClient.decode(data: body, status: 401)) { XCTAssertEqual($0 as? ClaudeError, .unauthorized) }
        XCTAssertEqual(ClaudeError.from(status: 400, data: body), .badRequest("(invalid x-api-key)"))
        XCTAssertEqual(ClaudeError.from(status: 403, data: body), .forbidden("(invalid x-api-key)"))
        XCTAssertEqual(ClaudeError.from(status: 429, data: Data()), .rateLimited(""))
        XCTAssertEqual(ClaudeError.from(status: 529, data: Data()), .overloaded)
        XCTAssertEqual(ClaudeError.from(status: 500, data: Data()), .server(500, ""))
        // どの失敗にも、日本語の説明がある
        for error in [ClaudeError.missingKey, .overBudget(spent: 5, limit: 5), .offline, .unauthorized, .overloaded, .refused,
                      .emptyAnswer(stopReason: "max_tokens")] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    /// 決まった応答を返す通信(POST の内容を記録する)
    private final class StubHTTP: HTTPClient, @unchecked Sendable {
        let result: Result<(Data, Int), Error>
        private(set) var sent: [URLRequest] = []

        init(_ result: Result<(Data, Int), Error>) {
            self.result = result
        }

        func get(_ url: URL) async throws -> Data { Data() }

        func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            sent.append(request)
            let (data, status) = try result.get()
            return (data, status)
        }
    }

    func testClientMapsNetworkErrors() async throws {
        let request = ClaudeRequest(model: "m", system: "s", messages: [.user("q")], maxTokens: 10, thinking: false)
        let ok = StubHTTP(.success((try Fixture.data("claude_message"), 200)))
        let response = try await HTTPClaudeClient(http: ok).send(request, apiKey: "k")
        XCTAssertEqual(response.usage.cacheRead, 1450)
        XCTAssertEqual(ok.sent.count, 1)
        do {
            _ = try await HTTPClaudeClient(http: StubHTTP(.failure(URLError(.notConnectedToInternet)))).send(request, apiKey: "k")
            XCTFail("オフラインのはず")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .offline)
        }
        do {
            _ = try await HTTPClaudeClient(http: StubHTTP(.failure(URLError(.cancelled)))).send(request, apiKey: "k")
            XCTFail("取り消しのはず")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        do {
            _ = try await HTTPClaudeClient(http: StubHTTP(.success((try Fixture.data("claude_error"), 401)))).send(request, apiKey: "k")
            XCTFail("無効なキーのはず")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .unauthorized)
        }
    }

    func testUsageCategory() {
        XCTAssertEqual(UsageCategory.from(url: URL(string: "https://api.anthropic.com/v1/messages")), .claude)
        XCTAssertTrue(UsageCategory.claude.countsSentBytes)
        XCTAssertFalse(UsageCategory.weather.countsSentBytes)
    }
}

/// 小ツールを文章から作る流れ(仮の応答で)
final class ToolGeneratorTests: XCTestCase {
    /// 送った依頼を記録し、決まった答えを順に返す
    private final class Script {
        var answers: [String]
        var requests: [ClaudeRequest] = []

        init(_ answers: [String]) {
            self.answers = answers
        }

        func call(_ request: ClaudeRequest) -> ClaudeCallResult {
            requests.append(request)
            let text = answers.isEmpty ? "" : answers.removeFirst()
            return ClaudeCallResult(response: ClaudeResponse(text: text, usage: ClaudeUsage(input: 100, output: 50, cacheWrite: 2000, cacheRead: 0, thinking: 30),
                                                             stopReason: "end_turn", model: "claude-haiku-5-5"),
                                    cost: 0.001)
        }
    }

    private var validJSON: String {
        get throws { try XCTUnwrap(String(data: Fixture.data("tool_fuel_economy"), encoding: .utf8)) }
    }

    func testValidOnFirstTry() async throws {
        let json = try validJSON
        let script = Script(["```json\n" + json + "\n```"])
        let generation = try await ToolGenerator.run(messages: ToolGenerator.createMessages(description: "燃費の計算"), model: "claude-haiku-5-5",
                                                     thinking: true, format: "形式の説明") { script.call($0) }
        guard case .valid(_, let tool) = generation.outcome else { return XCTFail("検証を通るはず") }
        XCTAssertEqual(tool.id, "fuel-economy")
        XCTAssertEqual(generation.attempts, 1)
        XCTAssertEqual(script.requests.count, 1)
        let request = script.requests[0]
        // 形式の説明は system prompt に入れ、キャッシュする。思考の設定を渡す。
        XCTAssertTrue(request.system.contains("形式の説明"))
        XCTAssertTrue(request.cachesSystem)
        XCTAssertTrue(request.thinking)
        XCTAssertEqual(request.maxTokens, ToolGenerator.maxTokens)
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(generation.usage.cacheWrite, 2000)
        XCTAssertEqual(generation.cost, 0.001, accuracy: 1e-12)
    }

    func testRetryOnceWithIssues() async throws {
        let json = try validJSON
        let script = Script([#"{"format": 1, "id": "x", "type": "calc"}"#, json])
        let generation = try await ToolGenerator.run(messages: ToolGenerator.createMessages(description: "燃費"), model: "m",
                                                     thinking: false, format: "F") { script.call($0) }
        guard case .valid = generation.outcome else { return XCTFail("2回目で検証を通るはず") }
        XCTAssertEqual(generation.attempts, 2)
        // 2回目は、1回目の答えと、誤りを添えた依頼を足して送る
        let second = script.requests[1]
        XCTAssertEqual(second.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(second.messages[1], .assistant(#"{"format": 1, "id": "x", "type": "calc"}"#))
        guard case .text(let retry, _)? = second.messages[2].content.first else { return XCTFail("作り直しの依頼がない") }
        XCTAssertTrue(retry.contains("誤り"))
        XCTAssertTrue(retry.contains("name"))
        // 使用量と金額は2回分の合計
        XCTAssertEqual(generation.usage.input, 200)
        XCTAssertEqual(generation.usage.thinking, 60)
        XCTAssertEqual(generation.cost, 0.002, accuracy: 1e-12)
    }

    func testStopsAfterTwoInvalidAnswers() async throws {
        let script = Script(["JSON ではない答え", #"{"format": 2}"#, "3回目は頼まない"])
        let generation = try await ToolGenerator.run(messages: ToolGenerator.createMessages(description: "何か"), model: "m",
                                                     thinking: true, format: "F") { script.call($0) }
        guard case .invalid(let json, let issues) = generation.outcome else { return XCTFail("誤りが残るはず") }
        XCTAssertEqual(json, #"{"format": 2}"#)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertEqual(generation.attempts, 2)
        XCTAssertEqual(script.requests.count, 2)
    }

    func testEmptyAnswerThrows() async throws {
        let script = Script([""])
        do {
            _ = try await ToolGenerator.run(messages: ToolGenerator.createMessages(description: "何か"), model: "m",
                                            thinking: true, format: "F") { script.call($0) }
            XCTFail("空の答えは失敗にする")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .emptyAnswer(stopReason: "end_turn"))
        }
    }

    func testExtractJSONAndRevision() {
        XCTAssertEqual(ToolGenerator.extractJSON(#"{"a": 1}"#), #"{"a": 1}"#)
        XCTAssertEqual(ToolGenerator.extractJSON("作りました。\n```json\n{\"a\": {\"b\": 2}}\n```\n以上です"), #"{"a": {"b": 2}}"#)
        XCTAssertEqual(ToolGenerator.extractJSON("前置き {\"a\": 1} 後書き"), #"{"a": 1}"#)
        XCTAssertEqual(ToolGenerator.extractJSON("JSON なし"), "JSON なし")
        // 直す依頼には、今の JSON と依頼文が入る
        let messages = ToolGenerator.reviseMessages(currentJSON: #"{"id": "fuel"}"#, instruction: "入力欄に燃料の単価を足して")
        XCTAssertEqual(messages.count, 1)
        guard case .text(let text, _)? = messages[0].content.first else { return XCTFail("文がない") }
        XCTAssertTrue(text.contains(#"{"id": "fuel"}"#))
        XCTAssertTrue(text.contains("入力欄に燃料の単価を足して"))
        // system prompt に形式の説明が入る。同梱した説明が読める。
        XCTAssertTrue(ToolGenerator.systemPrompt(format: "XYZ").contains("XYZ"))
        XCTAssertTrue(ToolGenerator.formatDocument.contains("format 1"))
    }
}

/// 「撮って聞く」: 画像の切り出し・外側を暗く・縮小、一緒に送る情報、送るメッセージ
final class ScopeAskTests: XCTestCase {
    /// 白い画像
    private func whiteImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// 画像の左上を原点とした位置の、赤の値(0〜255)
    private func red(_ image: CGImage, x: Int, y: Int) throws -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Int(pixels[(y * image.width + x) * 4])
    }

    func testVisibleRect() {
        // 縦長の映像(720×1280)を、横に広い画面に aspectFill で出したときは、上下が切れる
        XCTAssertEqual(ScopeAskImage.visibleRect(imageSize: CGSize(width: 720, height: 1280), viewSize: CGSize(width: 400, height: 600)),
                       CGRect(x: 0, y: 100, width: 720, height: 1080))
        // 縦長の画面では、左右が切れる
        XCTAssertEqual(ScopeAskImage.visibleRect(imageSize: CGSize(width: 720, height: 1280), viewSize: CGSize(width: 300, height: 800)),
                       CGRect(x: 0, y: 0, width: 720, height: 1280).insetBy(dx: 60, dy: 0))
    }

    func testShapeBounds() {
        let size = CGSize(width: 100, height: 100)
        XCTAssertNil(ScopeAskImage.bounds(of: [], imageSize: size))
        XCTAssertNil(ScopeAskImage.bounds(of: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)], imageSize: size))
        // 小さすぎる囲みは、囲みとして扱わない
        XCTAssertNil(ScopeAskImage.bounds(of: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 10, y: 20)], imageSize: size))
        // 画像の外にはみ出した分は切る
        XCTAssertEqual(ScopeAskImage.bounds(of: [CGPoint(x: -10, y: 20), CGPoint(x: 60, y: 20), CGPoint(x: 30, y: 130)], imageSize: size),
                       CGRect(x: 0, y: 20, width: 60, height: 80))
    }

    func testFittedSizeAndTokens() {
        let landscape = ScopeAskImage.fittedSize(width: 4032, height: 3024, maxEdge: 1024)
        XCTAssertEqual([landscape.width, landscape.height], [1024, 768])
        let portrait = ScopeAskImage.fittedSize(width: 720, height: 1280, maxEdge: 1024)
        XCTAssertEqual([portrait.width, portrait.height], [576, 1024])
        let small = ScopeAskImage.fittedSize(width: 500, height: 300, maxEdge: 1024)
        XCTAssertEqual([small.width, small.height], [500, 300])
        XCTAssertEqual(ScopeAskImage.estimatedTokens(width: 1024, height: 768), 37 * 28)
    }

    func testMaskOutsideOfShape() throws {
        let image = try whiteImage(width: 100, height: 100)
        // 左上の三角形で囲む
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)]
        let masked = try XCTUnwrap(ScopeAskImage.render(image, shape: triangle, maxEdge: 1024))
        XCTAssertEqual(masked.width, 100)
        XCTAssertEqual(try red(masked, x: 10, y: 10), 255)
        // 外側(右下)は暗くする
        let dark = Double(try red(masked, x: 90, y: 90))
        XCTAssertEqual(dark, Double(255 * (1 - ScopeAskImage.outsideDarkness)), accuracy: 3)
        // 囲みを囲む四角で切り出す
        let small = [CGPoint(x: 20, y: 30), CGPoint(x: 70, y: 30), CGPoint(x: 70, y: 90), CGPoint(x: 20, y: 90)]
        let cropped = try XCTUnwrap(ScopeAskImage.render(image, shape: small, maxEdge: 1024))
        XCTAssertEqual(cropped.width, 50)
        XCTAssertEqual(cropped.height, 60)
        // 囲みがなければ画像全体を、長い辺に合わせて縮める
        let whole = try XCTUnwrap(ScopeAskImage.render(try whiteImage(width: 200, height: 100), shape: nil, maxEdge: 50))
        XCTAssertEqual(whole.width, 50)
        XCTAssertEqual(whole.height, 25)
        // JPEG にする
        let jpeg = try XCTUnwrap(ScopeAskImage.prepare(image, shape: nil, maxEdge: 1024))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
    }

    private func snapshot() throws -> ScopeAskSnapshot {
        ScopeAskSnapshot(image: try whiteImage(width: 4, height: 4), heading: 45, pitch: 10.4, latitude: 35.68123, longitude: 139.76712,
                         placeName: "東京都千代田区",
                         targets: [ScopeAskTarget(name: "東京タワー", kind: "登録した地点", bearing: 200, distance: 3200, heightDifference: 300),
                                   ScopeAskTarget(name: "駅前のコンビニ", kind: "周辺の施設", bearing: 40, distance: 120, heightDifference: nil)],
                         takenAt: Date(timeIntervalSince1970: 0))
    }

    func testContextOptions() throws {
        let snapshot = try snapshot()
        let all = ScopeAsk.contextText(snapshot, options: ScopeAskOptions())
        XCTAssertTrue(all.contains("北東(45°)"))
        XCTAssertTrue(all.contains("水平より10°上向き"))
        XCTAssertTrue(all.contains("東京都千代田区"))
        XCTAssertTrue(all.contains("緯度35.681、経度139.767"))
        XCTAssertTrue(all.contains("東京タワー(登録した地点)"))
        // 近い順に並べる
        let near = try XCTUnwrap(all.range(of: "駅前のコンビニ"))
        let far = try XCTUnwrap(all.range(of: "東京タワー"))
        XCTAssertTrue(near.lowerBound < far.lowerBound)

        let noCoordinates = ScopeAsk.contextText(snapshot, options: ScopeAskOptions(coordinates: false))
        XCTAssertTrue(noCoordinates.contains("東京都千代田区"))
        XCTAssertFalse(noCoordinates.contains("緯度"))
        let noPlace = ScopeAsk.contextText(snapshot, options: ScopeAskOptions(place: false))
        XCTAssertFalse(noPlace.contains("千代田区"))
        XCTAssertFalse(noPlace.contains("緯度"))
        let noHeading = ScopeAsk.contextText(snapshot, options: ScopeAskOptions(heading: false))
        XCTAssertFalse(noHeading.contains("北東"))
        let noTargets = ScopeAsk.contextText(snapshot, options: ScopeAskOptions(targets: false))
        XCTAssertFalse(noTargets.contains("東京タワー"))
        let none = ScopeAsk.contextText(snapshot, options: ScopeAskOptions(heading: false, place: false, coordinates: false, targets: false))
        XCTAssertTrue(none.contains("送っていません"))
        XCTAssertFalse(none.contains("東京"))
        // 設定から作る
        var settings = ClaudeSettings()
        settings.sendsTargets = false
        XCTAssertEqual(ScopeAskOptions(settings), ScopeAskOptions(targets: false))
    }

    func testMessagesKeepRecentExchanges() {
        let jpeg = Data([0xFF, 0xD8])
        var history: [ScopeAskExchange] = []
        for index in 1...4 {
            var exchange = ScopeAskExchange(question: "質問\(index)")
            exchange.answer = "答え\(index)"
            history.append(exchange)
        }
        // 失敗したやり取りは送らない
        history.append(ScopeAskExchange(question: "失敗", error: "通信に失敗"))
        let messages = ScopeAsk.messages(jpeg: jpeg, context: "状況", history: history, question: "質問5")
        // 最初のメッセージ(画像・状況・残した最初の質問)+ 直近3回の答えと次の質問
        XCTAssertEqual(messages.count, 1 + 2 * ScopeAsk.keptExchanges)
        XCTAssertEqual(messages[0].content, [.jpeg(jpeg), .text("状況", cached: true), .text("質問2")])
        XCTAssertEqual(messages[1], .assistant("答え2"))
        XCTAssertEqual(messages.last, .user("質問5"))
        // 最初の質問
        let first = ScopeAsk.messages(jpeg: jpeg, context: "状況", history: [], question: ScopeAsk.question("  "))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].content.last, .text("これは何ですか？"))
        // 思考の設定を渡す
        var settings = ClaudeSettings()
        settings.thinkingForCamera = false
        let request = ScopeAsk.request(messages: first, settings: settings)
        XCTAssertFalse(request.thinking)
        XCTAssertEqual(request.model, "claude-haiku-5-5")
        XCTAssertTrue(request.system.contains("分からない"))
        XCTAssertTrue(request.system.contains("推測"))
    }

    func testUndergroundStyleIsTranslucentRed() {
        // 後ろのカメラの映像が透けて見える薄さ
        XCTAssertLessThanOrEqual(ScopeUndergroundStyle.fillOpacity, 0.4)
        XCTAssertGreaterThan(ScopeUndergroundStyle.strokeOpacity, ScopeUndergroundStyle.fillOpacity)
        XCTAssertFalse(ScopeUndergroundStyle.dash.isEmpty)
    }
}

import XCTest
@testable import SmartDashboard

/// 文章からオブジェクトを作る: 細かさ、Web 検索と検索なしへの切り替え、ストリーミングの読み取り、進み具合
final class ObjectGenerationTests: XCTestCase {
    private func json(shapes count: Int) -> String {
        let shapes = (0..<count).map { #"{"kind":"box","width":1,"depth":1,"height":1,"z":\#($0)}"# }.joined(separator: ",")
        return #"{"format":1,"type":"scope-object","name":"塔","shapes":[\#(shapes)]}"#
    }

    private func result(_ text: String, searches: Int = 0, citations: [ClaudeCitation] = [], stop: String = "end_turn") -> ClaudeCallResult {
        ClaudeCallResult(response: ClaudeResponse(text: text, usage: ClaudeUsage(input: 100, output: 50, webSearches: searches), stopReason: stop,
                                                  model: "claude-haiku-5-5", citations: citations),
                         cost: 0.01)
    }

    func testDetailLimits() {
        XCTAssertEqual(ObjectDetail.initial, .detailed)
        XCTAssertEqual(ObjectDetail.allCases.map(\.maxShapes), [30, 100, 300])
        XCTAssertEqual(ObjectDetail.allCases.map(\.maxTokens), [8_000, 24_000, 56_000])
        XCTAssertEqual(ObjectDetail.allCases.map(\.label), ["ふつう", "細かい", "とても細かい"])
        XCTAssertEqual(ScopeObject.maxShapes, 300)
        // 形の数の上限は、検証でも効く
        guard case .failure(let issues) = ObjectCodec.parse(json(shapes: 31), maxShapes: 30) else { return XCTFail("31個は多すぎる") }
        XCTAssertEqual(issues.map(\.path), ["shapes"])
        guard case .success(let object) = ObjectCodec.parse(json(shapes: 300)) else { return XCTFail("300個までは読める") }
        XCTAssertEqual(object.shapes.count, 300)
        // 料金の目安は、細かいほど高く、検索ありのほうが高い
        let costs = ObjectDetail.allCases.map { ObjectGenerator.estimatedCost(detail: $0, webSearch: false) }
        XCTAssertEqual(costs, costs.sorted())
        XCTAssertGreaterThan(ObjectGenerator.estimatedCost(detail: .detailed, webSearch: true), ObjectGenerator.estimatedCost(detail: .detailed, webSearch: false) + 0.019)
    }

    func testRequestUsesDetailAndSearch() throws {
        let messages = ObjectGenerator.messages(description: "東京タワー", detail: .detailed)
        guard case .text(let text, _)? = messages.first?.content.first else { return XCTFail("文がない") }
        XCTAssertTrue(text.contains("形は100個まで"))
        XCTAssertTrue(text.hasSuffix("東京タワー"))
        let request = ObjectGenerator.request(messages: messages, model: "m", thinking: true, detail: .veryDetailed, webSearch: true)
        XCTAssertEqual(request.maxTokens, 56_000)
        XCTAssertEqual(request.webSearchMaxUses, 2)
        XCTAssertTrue(request.cachesSystem)
        XCTAssertTrue(request.system.contains("web_search"))
        let tools = try XCTUnwrap(request.jsonObject["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["max_uses"] as? Int, 2)
        let plain = ObjectGenerator.request(messages: messages, model: "m", thinking: true, detail: .normal, webSearch: false)
        XCTAssertNil(plain.webSearchMaxUses)
        XCTAssertFalse(plain.system.contains("web_search"))
        XCTAssertNil(plain.jsonObject["tools"])
        // 細かく作るコツが入っている
        XCTAssertTrue(ObjectGenerator.basePrompt.contains("比率"))
        XCTAssertTrue(ObjectGenerator.basePrompt.contains("くり返す部分"))
    }

    func testSearchFallbackWhenSearchIsUnavailable() async throws {
        var requests: [ClaudeRequest] = []
        let outcome = try await ObjectGenerator.run(description: "東京タワー", detail: .normal, webSearch: true, model: "m", thinking: false) { request in
            requests.append(request)
            if request.webSearchMaxUses != nil { throw ClaudeError.badRequest("(web search is not supported)") }
            return self.result(self.json(shapes: 3))
        }
        XCTAssertTrue(outcome.searchFallback)
        XCTAssertEqual(outcome.object?.shapes.count, 3)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[1].webSearchMaxUses)
        XCTAssertEqual(requests[1].system, ObjectGenerator.systemPrompt(webSearch: false))
        XCTAssertEqual(outcome.attempts, 1)
    }

    func testSearchesAndCitationsAreReported() async throws {
        let citation = ClaudeCitation(title: "東京タワー", url: "https://example.com/tower", citedText: "高さ333m")
        let outcome = try await ObjectGenerator.run(description: "東京タワー", detail: .detailed, webSearch: true, model: "m", thinking: false) { _ in
            self.result("調べました。" + self.json(shapes: 5), searches: 2, citations: [citation])
        }
        XCTAssertFalse(outcome.searchFallback)
        XCTAssertEqual(outcome.searches, 2)
        XCTAssertEqual(outcome.citations, [citation])
        XCTAssertEqual(outcome.object?.shapes.count, 5)
        XCTAssertEqual(outcome.cost, 0.01, accuracy: 1e-9)
    }

    func testRetryIsWithoutSearchAndRespectsDetail() async throws {
        var requests: [ClaudeRequest] = []
        var answers = [json(shapes: 40), json(shapes: 20)]
        let outcome = try await ObjectGenerator.run(description: "塔", detail: .normal, webSearch: true, model: "m", thinking: false) { request in
            requests.append(request)
            return self.result(answers.removeFirst(), stop: requests.count == 1 ? "max_tokens" : "end_turn")
        }
        XCTAssertEqual(outcome.attempts, 2)
        XCTAssertEqual(outcome.object?.shapes.count, 20)
        XCTAssertNotNil(requests[0].webSearchMaxUses)
        XCTAssertNil(requests[1].webSearchMaxUses)
        // 作り直しの依頼に、形を減らす頼みが入る
        guard case .text(let retry, _)? = requests[1].messages.last?.content.first else { return XCTFail("作り直しの依頼がない") }
        XCTAssertTrue(retry.contains("途中で切れました"))
        XCTAssertTrue(retry.contains("shapes"))
    }

    func testStreamAccumulator() throws {
        let lines = [
            #"{"type":"message_start","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":120,"cache_read_input_tokens":2000,"output_tokens":1}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"東京"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"タワー 高さ\"}"}}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[]}}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"{\"shapes\":[{\"ki"}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"nd\":\"box\"},{\"kind\":\"cone\"}]}"}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://example.com/t","title":"東京タワー","cited_text":"333m"}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":900,"server_tool_use":{"web_search_requests":1}}}"#,
            #"{"type":"message_stop"}"#,
        ]
        var accumulator = ClaudeStreamAccumulator()
        var events: [ClaudeStreamEvent] = []
        for line in lines {
            if let event = accumulator.consume(line) { events.append(event) }
        }
        XCTAssertEqual(events.first, .started)
        XCTAssertTrue(events.contains(.thinking))
        XCTAssertTrue(events.contains(.searching(count: 1, query: "東京タワー 高さ")))
        XCTAssertTrue(events.contains(.searched(count: 1)))
        // "kind" が区切りをまたいでも数える
        XCTAssertEqual(events.last, .writing(characters: #"{"shapes":[{"kind":"box"},{"kind":"cone"}]}"#.count, shapes: 2))
        let response = try accumulator.response()
        XCTAssertEqual(response.text, #"{"shapes":[{"kind":"box"},{"kind":"cone"}]}"#)
        XCTAssertEqual(response.usage.input, 120)
        XCTAssertEqual(response.usage.cacheRead, 2000)
        XCTAssertEqual(response.usage.output, 900)
        XCTAssertEqual(response.usage.webSearches, 1)
        XCTAssertEqual(response.stopReason, "end_turn")
        XCTAssertEqual(response.citations.map(\.url), ["https://example.com/t"])
        // 続きで送り返すブロック(思考の署名、検索の入力も入る)
        XCTAssertEqual(response.rawContent.count, 4)
        let thinking = try XCTUnwrap(JSONSerialization.jsonObject(with: response.rawContent[0]) as? [String: Any])
        XCTAssertEqual(thinking["signature"] as? String, "sig")
        let toolUse = try XCTUnwrap(JSONSerialization.jsonObject(with: response.rawContent[1]) as? [String: Any])
        XCTAssertEqual((toolUse["input"] as? [String: Any])?["query"] as? String, "東京タワー 高さ")

        var failing = ClaudeStreamAccumulator()
        _ = failing.consume(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        XCTAssertThrowsError(try failing.response()) { XCTAssertEqual($0 as? ClaudeError, .overloaded) }
    }

    func testProgressStages() {
        var progress = ObjectGenerationProgress()
        progress.apply(.started)
        XCTAssertEqual(progress.stage, "作り始めました")
        progress.apply(.searching(count: 1, query: "東京タワー"))
        XCTAssertEqual(progress.searches, 1)
        XCTAssertEqual(progress.query, "東京タワー")
        XCTAssertTrue(progress.stage.contains("Web で調べています"))
        progress.apply(.writing(characters: 500, shapes: 12))
        XCTAssertEqual(progress.shapes, 12)
        XCTAssertEqual(progress.stage, "形を受け取っています(12個)")
    }

    func testSharedSearchCallKeepsScopeAskBehavior() async throws {
        // 「撮って聞く」と同じ部品: 400 なら検索なしで1回だけ聞き直す
        var calls = 0
        let request = ClaudeRequest(model: "m", system: "s", messages: [.user("q")], maxTokens: 100, thinking: false, webSearchMaxUses: 3)
        let result = try await ClaudeSearchCall.run(request) { request in
            calls += 1
            if request.webSearchMaxUses != nil { throw ClaudeError.badRequest("") }
            return self.result("答え")
        }
        XCTAssertTrue(result.searchFallback)
        XCTAssertEqual(calls, 2)
        // 400 以外の失敗は、そのまま返す
        do {
            _ = try await ClaudeSearchCall.run(request) { _ in throw ClaudeError.overloaded }
            XCTFail("失敗するはず")
        } catch {
            XCTAssertEqual(error as? ClaudeError, .overloaded)
        }
    }
}

/// カメラ表示の簡略化の段階と、面の割り当て
final class ObjectLODTests: XCTestCase {
    private let facingNorth = CameraAttitude(m11: 0, m12: -1, m13: 0, m21: 0, m22: 0, m23: 1, m31: -1, m32: 0, m33: 0)
    private let size = CGSize(width: 375, height: 667)
    private let tangents = (horizontal: 0.6, vertical: 1.0)
    private let user = GeoPoint(35, 139)

    private func layout(_ object: ScopeObject, north: Double) -> (ObjectRenderer.Layout, UUID) {
        let point = GeoMath.offset(user, east: 0, north: north)
        let placement = ObjectPlacement(objectID: object.id, name: object.name, latitude: point.latitude, longitude: point.longitude,
                                        groundElevation: 0, elevationState: .fetched)
        let input = ObjectDrawInput.make(placements: [placement], objects: [object], user: user, observerAltitude: 1.5, handHeight: 1.5)
        return (ObjectRenderer.layout(input, attitude: facingNorth, tangents: tangents, size: size), placement.id)
    }

    func testLevelsByScreenSize() {
        XCTAssertEqual(ObjectLOD.level(radiusOnScreen: 200), .full)
        XCTAssertEqual(ObjectLOD.level(radiusOnScreen: 80), .full)
        XCTAssertEqual(ObjectLOD.level(radiusOnScreen: 40), .medium)
        XCTAssertEqual(ObjectLOD.level(radiusOnScreen: 15), .box)
        XCTAssertEqual(ObjectLOD.level(radiusOnScreen: 5), .ring)
        // 粗い版は面が少ない
        XCTAssertLessThan(ObjectGeometry.unitFaces(.sphere, low: true).count, ObjectGeometry.unitFaces(.sphere).count)
        XCTAssertEqual(ObjectGeometry.unitFaces(.cylinder, low: true).count, 2 + ObjectGeometry.lowRoundSegments)
    }

    func testBudgetPrefersLargerOnScreen() {
        let counts: [ObjectLOD: Int] = [.full: 1500, .medium: 600, .box: 6, .ring: 0]
        let plan = ObjectLOD.plan([
            ObjectLOD.Candidate(id: 0, radiusOnScreen: 100, faceCounts: counts),
            ObjectLOD.Candidate(id: 1, radiusOnScreen: 300, faceCounts: counts),
            ObjectLOD.Candidate(id: 2, radiusOnScreen: 90, faceCounts: counts),
            ObjectLOD.Candidate(id: 3, radiusOnScreen: 4, faceCounts: counts),
        ], budget: 2000)
        // 一番大きく見えるもの(1)が細かいまま。次(0)は残り500に入らないので箱。その次(2)も箱。小さいもの(3)は印
        XCTAssertEqual(plan, [1: .full, 0: .box, 2: .box, 3: .ring])
    }

    func testMediumDropsSmallShapesAndBoxMergesEverything() {
        // 10mの箱と、5cmの小さな箱
        let object = ScopeObject(name: "塔", shapes: [
            ObjectShape(kind: .box, width: 10, depth: 10, height: 10, color: "#FF0000", opacity: 0.4),
            ObjectShape(kind: .box, width: 0.05, depth: 0.05, height: 0.05, z: 10, color: "#FFFFFF", opacity: 0.4),
        ])
        let (medium, id) = layout(object, north: 100)
        XCTAssertEqual(medium.levels[id], .medium)
        XCTAssertEqual(medium.faces.count, 6)
        // 5つの箱を横に並べたものは、遠いと1つの箱
        let row = ScopeObject(name: "列", shapes: (0..<5).map { i in
            ObjectShape(kind: .box, width: 2, depth: 2, height: 2, x: Double(i) * 3 - 6, color: "#00FF00", opacity: 0.4)
        })
        let (far, rowID) = layout(row, north: 150)
        XCTAssertEqual(far.levels[rowID], .box)
        XCTAssertEqual(far.faces.count, 6)
        let (near, nearID) = layout(row, north: 12)
        XCTAssertEqual(near.levels[nearID], .full)
        XCTAssertEqual(near.faces.count, 30)
    }

    func testBatchesMergeConsecutiveSameFill() {
        func face(_ key: String, _ depth: Double) -> ObjectRenderer.DrawFace {
            ObjectRenderer.DrawFace(points: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)], fill: .red, stroke: nil, depth: depth, key: key)
        }
        XCTAssertEqual(ObjectRenderer.batches([face("a", 3), face("a", 2), face("b", 1)]).count, 2)
        XCTAssertEqual(ObjectRenderer.batches([face("a", 3), face("b", 2), face("a", 1)]).count, 3)
        XCTAssertTrue(ObjectRenderer.batches([]).isEmpty)
    }
}

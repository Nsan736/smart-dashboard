import XCTest
@testable import SmartDashboard

/// スコープのオブジェクト: 形から面への変換、向き・倍率・高さ、描く順番、遠いときの印、JSON の読み書き、編集
final class ObjectGeometryTests: XCTestCase {
    private func close(_ a: ObjectPoint, _ b: ObjectPoint, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    func testShapesBecomeFaces() {
        XCTAssertEqual(ObjectGeometry.unitFaces(.box).count, 6)
        XCTAssertEqual(ObjectGeometry.unitFaces(.cylinder).count, 2 + ObjectGeometry.roundSegments)
        XCTAssertEqual(ObjectGeometry.unitFaces(.cone).count, 1 + ObjectGeometry.roundSegments)
        XCTAssertEqual(ObjectGeometry.unitFaces(.sphere).count, ObjectGeometry.sphereLatitudes * ObjectGeometry.sphereLongitudes)
        XCTAssertEqual(ObjectGeometry.unitFaces(.pyramid).count, 5)
        XCTAssertEqual(ObjectGeometry.unitFaces(.plane).count, 1)
        XCTAssertTrue(ObjectGeometry.unitFaces(.box).allSatisfy { $0.count == 4 })

        // 幅2・奥行き4・高さ6の箱を、右1・前2・上3に置く(位置は底面の中心)
        var box = ObjectShape.make(.box)
        box.width = 2
        box.depth = 4
        box.height = 6
        box.x = 1
        box.y = 2
        box.z = 3
        let points = ObjectGeometry.faces(of: box).flatMap(\.vertices)
        XCTAssertEqual(points.map(\.x).min() ?? 0, 0, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.x).max() ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.y).min() ?? 0, 0, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.y).max() ?? 0, 4, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.z).min() ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(points.map(\.z).max() ?? 0, 9, accuracy: 1e-9)
        // 円錐の頂点は上
        let cone = ObjectShape.make(.cone)
        XCTAssertEqual(ObjectGeometry.faces(of: cone).flatMap(\.vertices).map(\.z).max() ?? 0, cone.height, accuracy: 1e-9)
        // はじめの色は赤、不透明度0.4
        XCTAssertEqual(box.color, "#FF0000")
        XCTAssertEqual(box.opacity, 0.4)
    }

    func testRotationDirections() {
        // ヨー90°: 前 → 右(上から見て時計回り)
        close(ObjectGeometry.rotate(ObjectPoint(0, 1, 0), yaw: 90, pitch: 0, roll: 0), ObjectPoint(1, 0, 0))
        // ピッチ90°: 前 → 上
        close(ObjectGeometry.rotate(ObjectPoint(0, 1, 0), yaw: 0, pitch: 90, roll: 0), ObjectPoint(0, 0, 1))
        // ロール90°: 右 → 下
        close(ObjectGeometry.rotate(ObjectPoint(1, 0, 0), yaw: 0, pitch: 0, roll: 90), ObjectPoint(0, 0, -1))
    }

    func testPlacementHeadingScaleAndHeight() {
        // 前(y)の点は、向き90°(東)・倍率2・地面から5mで、東へ2m・高さ5m
        close(ObjectGeometry.placed(ObjectPoint(0, 1, 0), heading: 90, scale: 2, heightAboveGround: 5), ObjectPoint(2, 0, 5))
        // 右(x)の点は、向き0°(北)のとき東
        close(ObjectGeometry.placed(ObjectPoint(1, 0, 0), heading: 0, scale: 1, heightAboveGround: 0), ObjectPoint(1, 0, 0))
        // 足元の形: 4×4の箱は、倍率2で面積が4倍。向きを変えても面積は同じ
        let object = ScopeObject(name: "箱", shapes: [ObjectShape(kind: .box, width: 4, depth: 4, height: 2, color: "#FF0000", opacity: 0.4)])
        func area(_ hull: [SIMD2<Double>]) -> Double {
            abs(hull.indices.reduce(0) { sum, i in
                let a = hull[i], b = hull[(i + 1) % hull.count]
                return sum + a.x * b.y - b.x * a.y
            }) / 2
        }
        XCTAssertEqual(area(ObjectGeometry.footprint(of: object, heading: 0, scale: 1)), 16, accuracy: 1e-6)
        XCTAssertEqual(area(ObjectGeometry.footprint(of: object, heading: 0, scale: 2)), 64, accuracy: 1e-6)
        XCTAssertEqual(area(ObjectGeometry.footprint(of: object, heading: 33, scale: 1)), 16, accuracy: 1e-6)
        XCTAssertEqual(ObjectGeometry.footprint(of: object, heading: 0, scale: 1).count, 4)
        let extent = ObjectGeometry.extent(of: object)
        XCTAssertEqual(extent.height, 2, accuracy: 1e-9)
    }
}

final class ObjectRendererTests: XCTestCase {
    private let facingNorth = CameraAttitude(m11: 0, m12: -1, m13: 0, m21: 0, m22: 0, m23: 1, m31: -1, m32: 0, m33: 0)
    private let size = CGSize(width: 375, height: 667)
    private let tangents = (horizontal: 0.6, vertical: 1.0)
    private let user = GeoPoint(35, 139)

    private func input(north: Double, heightAboveGround: Double = 0, scale: Double = 1) -> ObjectDrawInput {
        let object = ScopeObject(name: "箱", shapes: [ObjectShape(kind: .box, width: 10, depth: 10, height: 10, color: "#FF0000", opacity: 0.4)])
        let point = GeoMath.offset(user, east: 0, north: north)
        let placement = ObjectPlacement(objectID: object.id, name: "箱", latitude: point.latitude, longitude: point.longitude,
                                        heightAboveGround: heightAboveGround, scale: scale, groundElevation: 0, elevationState: .fetched)
        return ObjectDrawInput.make(placements: [placement], objects: [object], user: user, observerAltitude: 1.5, handHeight: 1.5)
    }

    func testFacesAreDrawnFarFirst() {
        let layout = ObjectRenderer.layout(input(north: 100), attitude: facingNorth, tangents: tangents, size: size)
        XCTAssertTrue(layout.rings.isEmpty)
        XCTAssertEqual(layout.faces.count, 6)
        for i in 0..<(layout.faces.count - 1) {
            XCTAssertGreaterThanOrEqual(layout.faces[i].depth, layout.faces[i + 1].depth)
        }
        // 一番遠い面(奥の面)は105m、一番近い面(手前の面)は95m
        XCTAssertEqual(layout.faces.first?.depth ?? 0, 105, accuracy: 0.5)
        XCTAssertEqual(layout.faces.last?.depth ?? 0, 95, accuracy: 0.5)
        XCTAssertEqual(layout.labels.count, 1)
        // タップで当たる
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        XCTAssertNotNil(ObjectRenderer.hit(center, layout: layout))
    }

    func testFarObjectBecomesRingAndBehindIsSkipped() {
        let far = ObjectRenderer.layout(input(north: 20_000), attitude: facingNorth, tangents: tangents, size: size)
        XCTAssertTrue(far.faces.isEmpty)
        XCTAssertEqual(far.rings.count, 1)
        XCTAssertEqual(far.rings.first?.target.distance ?? 0, 20_000, accuracy: 50)
        let behind = ObjectRenderer.layout(input(north: -100), attitude: facingNorth, tangents: tangents, size: size)
        XCTAssertTrue(behind.faces.isEmpty)
        XCTAssertTrue(behind.rings.isEmpty)
    }

    func testHeightAndScaleAreReflected() {
        func top(_ layout: ObjectRenderer.Layout) -> CGFloat { layout.faces.flatMap(\.points).map(\.y).min() ?? 0 }
        func bottom(_ layout: ObjectRenderer.Layout) -> CGFloat { layout.faces.flatMap(\.points).map(\.y).max() ?? 0 }
        let ground = ObjectRenderer.layout(input(north: 200), attitude: facingNorth, tangents: tangents, size: size)
        let raised = ObjectRenderer.layout(input(north: 200, heightAboveGround: 30), attitude: facingNorth, tangents: tangents, size: size)
        let bigger = ObjectRenderer.layout(input(north: 200, scale: 2), attitude: facingNorth, tangents: tangents, size: size)
        // 地面から上げると、画面の上に動く(下端も上)
        XCTAssertLessThan(bottom(raised), bottom(ground))
        // 倍率2で、上下の大きさがほぼ2倍
        XCTAssertEqual(bottom(bigger) - top(bigger), (bottom(ground) - top(ground)) * 2, accuracy: (bottom(ground) - top(ground)) * 0.2)
        // 足元は地面の高さ(目の高さ1.5mより下なので、画面の中心より下)
        XCTAssertGreaterThan(bottom(ground), size.height / 2)
    }
}

final class ObjectCodecTests: XCTestCase {
    func testRoundTrip() throws {
        var shape = ObjectShape.make(.cylinder, color: "#00FF88", opacity: 0.7)
        shape.yaw = 15
        shape.x = 1.25
        let object = ScopeObject(name: "円柱の塔", shapes: [shape, ObjectShape.make(.cone)])
        let json = ObjectCodec.encode(object)
        guard case .success(let parsed) = ObjectCodec.parse(json) else { return XCTFail("読めるはず") }
        XCTAssertEqual(parsed.name, object.name)
        XCTAssertEqual(parsed.shapes.count, 2)
        XCTAssertEqual(parsed.shapes[0].kind, .cylinder)
        XCTAssertEqual(parsed.shapes[0].color, "#00FF88")
        XCTAssertEqual(parsed.shapes[0].opacity, 0.7)
        XCTAssertEqual(parsed.shapes[0].yaw, 15)
        XCTAssertEqual(parsed.shapes[0].x, 1.25)
        XCTAssertEqual(parsed.shapes[1].kind, .cone)
        // 省略した項目は初期値(赤、不透明度0.4)
        guard case .success(let minimal) = ObjectCodec.parse(#"{"name":"箱","shapes":[{"kind":"box","height":30}]}"#) else { return XCTFail("読めるはず") }
        XCTAssertEqual(minimal.shapes[0].color, "#FF0000")
        XCTAssertEqual(minimal.shapes[0].opacity, 0.4)
        XCTAssertEqual(minimal.shapes[0].height, 30)
    }

    func testErrors() {
        guard case .failure(let issues) = ObjectCodec.parse(#"{"format":1,"type":"scope-object","name":"x","shapes":[{"kind":"torus"},{"kind":"box","width":-1,"color":"red"}]}"#) else {
            return XCTFail("誤りがあるはず")
        }
        XCTAssertEqual(Set(issues.map(\.path)), ["shapes[0].kind", "shapes[1].width", "shapes[1].color"])
        guard case .failure(let empty) = ObjectCodec.parse(#"{"name":"","shapes":[]}"#) else { return XCTFail("誤りがあるはず") }
        XCTAssertEqual(Set(empty.map(\.path)), ["name", "shapes"])
        guard case .failure = ObjectCodec.parse("[]") else { return XCTFail("配列は読めない") }
    }

    func testEditingAndHistory() {
        var object = ScopeObject(name: "家", shapes: [ObjectShape.make(.box, color: "#3366FF", opacity: 0.8)])
        var history = ObjectEditHistory()
        history.record(object)
        let added = ObjectShapeEditing.add(.pyramid, to: &object)
        // 追加した形は、最後の形の色を引き継ぎ、上に積む
        XCTAssertEqual(object.shapes.last?.color, "#3366FF")
        XCTAssertEqual(object.shapes.last?.z ?? 0, object.shapes[0].height, accuracy: 1e-9)
        let copy = ObjectShapeEditing.duplicate(added!, in: &object)
        XCTAssertEqual(object.shapes.count, 3)
        XCTAssertEqual(object.shapes[2].id, copy)
        ObjectShapeEditing.move(copy!, by: -2, in: &object)
        XCTAssertEqual(object.shapes[0].id, copy)
        let next = ObjectShapeEditing.delete(copy!, in: &object)
        XCTAssertEqual(object.shapes.count, 2)
        XCTAssertEqual(next, object.shapes[0].id)
        ObjectShapeEditing.applyToAll(color: "#FFFFFF", opacity: 0.5, in: &object)
        XCTAssertTrue(object.shapes.allSatisfy { $0.color == "#FFFFFF" && $0.opacity == 0.5 })
        // 元に戻す・やり直し
        let edited = object
        let undone = history.undo(edited)
        XCTAssertEqual(undone?.shapes.count, 1)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo(undone!), edited)
        XCTAssertFalse(history.canRedo)
    }

    @MainActor
    func testStoreSavesAndLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("objects.json")
        let store = ObjectStore(fileURL: url, elevation: nil)
        let object = ScopeObject(name: "塔", shapes: [ObjectShape.make(.box)])
        store.save(object)
        let placement = try XCTUnwrap(store.place(objectID: object.id, latitude: 35, longitude: 139))
        XCTAssertEqual(placement.name, "塔")
        store.setHidden(placement.id, hidden: true)
        XCTAssertTrue(store.visiblePlacements.isEmpty)
        XCTAssertTrue(store.drawItems().isEmpty)
        store.setHidden(placement.id, hidden: false)
        XCTAssertEqual(store.drawItems().count, 1)
        // 名前を変えると、置いたものの名前も変わる
        var renamed = object
        renamed.name = "赤い塔"
        store.save(renamed)
        let reloaded = ObjectStore(fileURL: url, elevation: nil)
        XCTAssertEqual(reloaded.objects.map(\.name), ["赤い塔"])
        XCTAssertEqual(reloaded.placements.map(\.name), ["赤い塔"])
        reloaded.deleteObject(object.id)
        XCTAssertTrue(reloaded.placements.isEmpty)
    }

    func testGeneratorRetriesInvalidJSON() async throws {
        var answers = [
            #"{"name":"塔","shapes":[{"kind":"tower"}]}"#,
            "```json\n{\"format\":1,\"type\":\"scope-object\",\"name\":\"赤い塔\",\"shapes\":[{\"kind\":\"box\",\"width\":4,\"depth\":4,\"height\":30}]}\n```",
        ]
        var requests: [ClaudeRequest] = []
        let outcome = try await ObjectGenerator.run(description: "高さ30mの赤い塔", model: "claude-haiku-5-5", thinking: false) { request in
            requests.append(request)
            return ClaudeCallResult(response: ClaudeResponse(text: answers.removeFirst(), usage: ClaudeUsage(input: 1, output: 1),
                                                             stopReason: "end_turn", model: nil), cost: 0)
        }
        XCTAssertEqual(outcome.attempts, 2)
        XCTAssertEqual(outcome.object?.name, "赤い塔")
        XCTAssertEqual(outcome.object?.shapes.first?.height, 30)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].cachesSystem)
    }
}

/// 景色の範囲の拡張: 遠い距離での丸みの計算、粗いタイルの山頂の補い、範囲とデータ量
final class SceneryRangeTests: XCTestCase {
    /// 球の上で厳密に計算した仰角(大気の屈折は、地球の半径を大きくして扱う)
    private func exactAngle(target: Double, observer: Double, distance: Double) -> Double {
        let radius = WaypointElevation.earthRadius / (1 - WaypointElevation.refraction)
        let theta = distance / radius
        return atan2((radius + target) * cos(theta) - (radius + observer), (radius + target) * sin(theta)) * 180 / .pi
    }

    func testCurvatureIsAccurateBeyond300km() {
        for distance in [100_000.0, 200_000, 300_000, 350_000, 400_000] {
            for (target, observer) in [(0.0, 2.0), (3776, 10), (3000, 500)] {
                let approx = WaypointElevation.angle(targetAltitude: target, observerAltitude: observer, distance: distance)
                XCTAssertEqual(approx, exactAngle(target: target, observer: observer, distance: distance), accuracy: 0.001,
                               "\(distance) \(target) \(observer)")
            }
        }
        // 富士山は、海抜10mから300kmでは地平線の下(見かけの低下は約5.3km)
        XCTAssertLessThan(WaypointElevation.angle(targetAltitude: 3776, observerAltitude: 10, distance: 300_000), 0)
        XCTAssertEqual(WaypointElevation.curvatureDrop(distance: 300_000), 6_145, accuracy: 10)
    }

    func testCoarseTilesArePatchedWithPeaks() {
        // 地面は平ら(粗いタイルで山が消えた状態)。東へ250kmに3776mの山頂
        let lat = 35.0, lon = 139.0
        let peakLon = lon + 250_000 / (111_195 * cos(lat * .pi / 180))
        struct Flat: TerrainSampling {
            func sample(latitude: Double, longitude: Double, distance: Double) -> TerrainGrid.Sample { .elevation(0) }
        }
        let peak = SkylinePeak(latitude: lat, longitude: peakLon, elevation: 3776)
        let eye = 2000.0
        let plain = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: eye, radius: 300_000, terrain: Flat()).skyline
        let patched = SkylineCalculator.compute(latitude: lat, longitude: lon, eye: eye, radius: 300_000, terrain: Flat(), peaks: [peak]).skyline
        let distance = WaypointMath.distance(fromLatitude: lat, longitude: lon, toLatitude: lat, longitude: peakLon)
        // 同じ緯度の東の点でも、大円の方角は90°より少し小さい
        let bearing = WaypointMath.bearing(fromLatitude: lat, longitude: lon, toLatitude: lat, longitude: peakLon)
        let expected = WaypointElevation.angle(targetAltitude: 3776, observerAltitude: eye, distance: distance)
        // 方角の刻み(0.5°)の分だけ山頂から横にずれるので、円すいの斜面の分だけ低い
        XCTAssertEqual(patched.horizonAngle(atBearing: bearing) ?? -90, expected, accuracy: 0.1)
        XCTAssertLessThan(plain.horizonAngle(atBearing: bearing) ?? 0, expected - 0.3)
        // 山頂から離れた方角は変わらない
        XCTAssertEqual(patched.horizonAngle(atBearing: 0) ?? 0, plain.horizonAngle(atBearing: 0) ?? 1, accuracy: 0.0001)
        // 近く(30km以内)の山頂は補わない(細かいタイルで足りる)
        let nearPeak = SkylinePeak(latitude: lat + 0.1, longitude: lon, elevation: 3000)
        XCTAssertEqual(SkylineCalculator.rayPeaks([nearPeak], latitude: lat, longitude: lon, radius: 300_000, step: 0.5, count: 720)
            .allSatisfy { $0.isEmpty }, true)
    }

    func testWideRangeTilesAndEstimates() {
        XCTAssertEqual(SceneryRadius.choices, [30, 50, 100, 150, 200, 300, 350])
        XCTAssertEqual(SceneryRadius.clamped(350), 350)
        XCTAssertEqual(SceneryRadius.initial, 100)
        XCTAssertEqual(TerrainGrid.zoom(forDistance: 150_000), 8)
        XCTAssertEqual(TerrainGrid.zoom(forDistance: 300_000), 7)
        let wide = SceneryTileStore.needed(latitude: 35.68, longitude: 139.77, radius: 350_000, includesVector: true)
        XCTAssertTrue(wide.contains { $0.kind == .dem && $0.key.z == 7 })
        XCTAssertTrue(wide.contains { $0.kind == .dem && $0.key.z == 8 })
        // 水部と注記は100kmまで(半径が広くても増えない)
        let near = SceneryTileStore.needed(latitude: 35.68, longitude: 139.77, radius: 100_000, includesVector: true)
        XCTAssertEqual(wide.filter { $0.kind == .vector }.count, near.filter { $0.kind == .vector }.count)
        // データ量の目安は、範囲を広げると増える(350kmでも10MB未満)
        let estimates = SceneryRadius.choices.map {
            SceneryTileStore.estimatedBytes(latitude: 35.68, longitude: 139.77, radius: Double($0) * 1000)
        }
        XCTAssertEqual(estimates, estimates.sorted())
        XCTAssertLessThan(estimates.last ?? 0, 10_000_000)
    }
}

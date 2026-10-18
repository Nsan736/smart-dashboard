import SceneKit
import XCTest
@testable import SmartDashboard

/// オブジェクトの向き: 正面(+y)が、プレビュー・地図の足元の輪郭・カメラ表示(すべての形・粗い形・箱)・置いたときの向きで一致する
final class ObjectOrientationTests: XCTestCase {
    private let facingNorth = CameraAttitude(m11: 0, m12: -1, m13: 0, m21: 0, m22: 0, m23: 1, m31: -1, m32: 0, m33: 0)
    private let size = CGSize(width: 375, height: 667)
    private let tangents = (horizontal: 0.6, vertical: 1.0)
    private let user = GeoPoint(35, 139)

    /// 4m の箱と、その正面(+y)の先にだけ付けた板。左右と前後が非対称
    private var frontBoard: ScopeObject {
        let body = ObjectShape(kind: .box, width: 4, depth: 4, height: 4, color: "#FF0000", opacity: 0.4)
        var board = ObjectShape(kind: .plane, width: 2, depth: 0.1, height: 2, color: "#0000FF", opacity: 0.4)
        board.y = 3
        board.z = 1
        return ScopeObject(name: "正面に板", shapes: [body, board])
    }

    @MainActor
    func testPreviewNodesMatchGeometry() {
        let angles: [(Double, Double, Double)] = [(0, 0, 0), (90, 0, 0), (30, 20, -15), (-120, 45, 60)]
        for kind in [ObjectShapeKind.box, .plane] {
            for (yaw, pitch, roll) in angles {
                var shape = ObjectShape(kind: kind, width: 3, depth: 2, height: 5, color: "#FF0000", opacity: 0.4)
                shape.x = 1.5
                shape.y = -2
                shape.z = 0.5
                shape.yaw = yaw
                shape.pitch = pitch
                shape.roll = roll
                let node = ObjectPreviewView.node(shape, selected: false)
                let units = ObjectGeometry.unitFaces(kind).flatMap { $0 }
                let points = ObjectGeometry.faces(of: shape).flatMap(\.vertices)
                XCTAssertEqual(units.count, points.count)
                for (unit, point) in zip(units, points) {
                    // SceneKit の部品の中の点(大きさ1): x=幅、y=高さ、z=後ろ(前の逆)
                    let world = node.simdTransform * SIMD4<Float>(Float(unit.x), Float(unit.z), Float(-unit.y), 1)
                    let expected = ObjectPreviewView.scenePoint(point)
                    XCTAssertEqual(world.x, expected.x, accuracy: 1e-3, "\(kind) \(yaw) \(pitch) \(roll)")
                    XCTAssertEqual(world.y, expected.y, accuracy: 1e-3, "\(kind) \(yaw) \(pitch) \(roll)")
                    XCTAssertEqual(world.z, expected.z, accuracy: 1e-3, "\(kind) \(yaw) \(pitch) \(roll)")
                }
            }
        }
    }

    @MainActor
    func testPreviewFrontIsBlueMarkSide() {
        let object = frontBoard
        // 正面の板は、SceneKit の −z(前)の側。青い印も同じ側(正面の一番前より先)に置く
        let board = ObjectPreviewView.node(object.shapes[1], selected: false)
        XCTAssertLessThan(board.simdPosition.z, 0)
        XCTAssertEqual(ObjectPreviewView.frontY(of: object), 3, accuracy: 1e-9)
        XCTAssertLessThan(ObjectPreviewView.scenePoint(ObjectPoint(0, ObjectPreviewView.frontY(of: object) + 1.6, 0)).z, board.simdPosition.z)
        // 右(+x)は SceneKit でも +x、上(+z)は +y
        XCTAssertEqual(ObjectPreviewView.scenePoint(ObjectPoint(1, 0, 0)), SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(ObjectPreviewView.scenePoint(ObjectPoint(0, 0, 1)), SIMD3<Float>(0, 1, 0))
    }

    func testFootprintFrontFollowsHeading() {
        let object = frontBoard
        // 向き0°: 正面は北(北へ3m、南へ2m)
        let north = ObjectGeometry.footprint(of: object, heading: 0, scale: 1)
        XCTAssertEqual(north.map(\.y).max() ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(north.map(\.y).min() ?? 0, -2, accuracy: 1e-9)
        XCTAssertEqual(north.map(\.x).max() ?? 0, 2, accuracy: 1e-9)
        // 向き90°: 正面は東
        let east = ObjectGeometry.footprint(of: object, heading: 90, scale: 1)
        XCTAssertEqual(east.map(\.x).max() ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(east.map(\.x).min() ?? 0, -2, accuracy: 1e-9)
        // 向き270°: 正面は西
        let west = ObjectGeometry.footprint(of: object, heading: 270, scale: 1)
        XCTAssertEqual(west.map(\.x).min() ?? 0, -3, accuracy: 1e-9)
        XCTAssertEqual(west.map(\.x).max() ?? 0, 2, accuracy: 1e-9)
        // 向き180°: 正面は南
        let south = ObjectGeometry.footprint(of: object, heading: 180, scale: 1)
        XCTAssertEqual(south.map(\.y).min() ?? 0, -3, accuracy: 1e-9)
    }

    func testCameraVectorFrontFollowsHeading() {
        let front = ObjectPoint(0, 3, 1)
        func placement(_ heading: Double) -> ObjectPlacement {
            ObjectPlacement(objectID: UUID(), name: "板", latitude: 35, longitude: 139, heading: heading)
        }
        // 基準の座標系は x=北、y=西、z=上
        let north = ObjectRenderer.vector(front, placement: placement(0), base: (0, 0), groundRelative: 0)
        XCTAssertEqual(north.x, 3, accuracy: 1e-9)
        XCTAssertEqual(north.y, 0, accuracy: 1e-9)
        let east = ObjectRenderer.vector(front, placement: placement(90), base: (0, 0), groundRelative: 0)
        XCTAssertEqual(east.x, 0, accuracy: 1e-9)
        XCTAssertEqual(east.y, -3, accuracy: 1e-9)
        XCTAssertEqual(east.z, 1, accuracy: 1e-9)
    }

    /// 北へ distance m に、向き heading で置いた板付きの箱を、北を向いて見たときの配置
    private func layout(distance: Double, heading: Double) -> (ObjectRenderer.Layout, UUID) {
        let object = frontBoard
        let point = GeoMath.offset(user, east: 0, north: distance)
        let placement = ObjectPlacement(objectID: object.id, name: "板", latitude: point.latitude, longitude: point.longitude,
                                        heading: heading, groundElevation: 0, elevationState: .fetched)
        let input = ObjectDrawInput.make(placements: [placement], objects: [object], user: user, observerAltitude: 1.5, handHeight: 1.5)
        return (ObjectRenderer.layout(input, attitude: facingNorth, tangents: tangents, size: size), placement.id)
    }

    func testCameraLevelsAgreeOnFront() {
        // 画面での半径は約 1531/距離 pt(80pt以上=すべて、25pt以上=粗い形、10pt以上=箱)
        for (distance, level) in [(12.0, ObjectLOD.full), (40, .medium), (100, .box)] {
            for heading in [90.0, 270] {
                let (result, id) = layout(distance: distance, heading: heading)
                XCTAssertEqual(result.levels[id], level, "\(distance)m")
                let xs = result.faces.flatMap(\.points).map(\.x)
                guard let minX = xs.min(), let maxX = xs.max() else { return XCTFail("面がない \(distance)m") }
                // オブジェクトは真北。正面(3m)の側が、反対の側(2m)より画面の中央から遠くまで出る
                let right = maxX - size.width / 2
                let left = size.width / 2 - minX
                if heading == 90 {
                    XCTAssertGreaterThan(right, left * 1.2, "向き90°は正面が東(右) \(level) \(distance)m")
                } else {
                    XCTAssertGreaterThan(left, right * 1.2, "向き270°は正面が西(左) \(level) \(distance)m")
                }
            }
        }
    }

    func testRotateAllKeepsShapeAndTurnsFront() {
        var object = frontBoard
        var tilted = ObjectShape(kind: .box, width: 1, depth: 2, height: 3, color: "#00FF00", opacity: 0.4)
        tilted.x = 1
        tilted.y = -1
        tilted.z = 2
        tilted.yaw = 20
        tilted.pitch = 30
        tilted.roll = -10
        object.shapes.append(tilted)
        let original = object
        ObjectShapeEditing.rotateAll(by: -90, in: &object)
        // 頂点は、もとの頂点を上から見て反時計回りに90°回したもの
        let before = ObjectGeometry.faces(of: original).flatMap(\.vertices)
        let after = ObjectGeometry.faces(of: object).flatMap(\.vertices)
        for (a, b) in zip(before, after) {
            let expected = ObjectGeometry.rotate(a, yaw: -90, pitch: 0, roll: 0)
            XCTAssertEqual(b.x, expected.x, accuracy: 1e-4)
            XCTAssertEqual(b.y, expected.y, accuracy: 1e-4)
            XCTAssertEqual(b.z, expected.z, accuracy: 1e-4)
        }
        // +x(右)に作った正面を +y に戻す例: 正面の板は左(−x)へ
        XCTAssertEqual(object.shapes[1].x, -3, accuracy: 1e-9)
        XCTAssertEqual(object.shapes[1].y, 0, accuracy: 1e-9)
        XCTAssertEqual(object.shapes[1].yaw, -90, accuracy: 1e-9)
        // 4回回すと、もとに戻る
        for _ in 0..<3 { ObjectShapeEditing.rotateAll(by: -90, in: &object) }
        for (a, b) in zip(original.shapes, object.shapes) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
            XCTAssertEqual(remainder(a.yaw - b.yaw, 360), 0, accuracy: 1e-6)
        }
    }

    func testPromptStatesAxes() {
        let prompt = ObjectGenerator.basePrompt
        XCTAssertTrue(prompt.contains("+y がオブジェクトの正面"))
        XCTAssertTrue(prompt.contains("向き0°なら +y は北"))
        XCTAssertTrue(prompt.contains("+x はオブジェクトの右"))
        XCTAssertTrue(prompt.contains("内装"))
        XCTAssertTrue(prompt.contains("完全に隠れる形は作らない"))
        XCTAssertTrue(prompt.contains("全体の輪郭"))
        XCTAssertTrue(prompt.contains("「とても細かい」のときは特に"))
        XCTAssertTrue(ObjectGenerator.searchPrompt.contains("<dimensions>"))
        XCTAssertTrue(ObjectGenerator.searchPrompt.contains("館内の案内"))
        XCTAssertEqual(ObjectDetail.initial, .veryDetailed)
    }
}

/// 隠れた形の判定と、調べた寸法の一覧の読み取り
final class ObjectQualityTests: XCTestCase {
    private func shape(_ kind: ObjectShapeKind, _ w: Double, _ d: Double, _ h: Double, x: Double = 0, y: Double = 0, z: Double = 0,
                       yaw: Double = 0) -> ObjectShape {
        var shape = ObjectShape(kind: kind, width: w, depth: d, height: h, color: "#FF0000", opacity: 0.4)
        shape.x = x
        shape.y = y
        shape.z = z
        shape.yaw = yaw
        return shape
    }

    private func hidden(_ shapes: [ObjectShape]) -> [Int] {
        ObjectGeometry.hiddenShapeIndices(of: ScopeObject(name: "t", shapes: shapes))
    }

    func testShapesInsideBoxAreHidden() {
        let outer = shape(.box, 10, 10, 10)
        // 中に完全に入っている箱・円柱・板
        XCTAssertEqual(hidden([outer, shape(.box, 2, 2, 2, z: 4), shape(.cylinder, 3, 3, 8, z: 1), shape(.plane, 4, 0, 3, y: 4.9, z: 2)]), [1, 2, 3])
        // 少しでもはみ出すもの、外の面に貼った板、面がちょうど重なるものは対象にしない
        XCTAssertEqual(hidden([outer, shape(.box, 2, 2, 2, x: 4.5, z: 4)]), [])
        XCTAssertEqual(hidden([outer, shape(.plane, 4, 0, 3, y: 5, z: 2)]), [])
        XCTAssertEqual(hidden([outer, shape(.box, 4, 4, 4, z: 0)]), [])
        // 同じ形が2つ重なっていても、どちらも隠れた形にしない
        XCTAssertEqual(hidden([outer, outer]), [])
        // 板の中には入らない
        XCTAssertEqual(hidden([shape(.plane, 10, 0, 10), shape(.box, 1, 1, 1, z: 4)]), [])
        // 入れ物が中のものより後でも判定する
        XCTAssertEqual(hidden([shape(.box, 2, 2, 2, z: 4), outer]), [0])
    }

    func testRotatedContainer() {
        // 幅10・奥行き2の箱を45°回したもの。長い向きの中は隠れる、それ以外ははみ出す
        let outer = shape(.box, 10, 2, 10, yaw: 45)
        let along = ObjectGeometry.rotate(ObjectPoint(4, 0, 0), yaw: 45, pitch: 0, roll: 0)
        let across = ObjectGeometry.rotate(ObjectPoint(0, 4, 0), yaw: 45, pitch: 0, roll: 0)
        XCTAssertEqual(hidden([outer, shape(.box, 0.5, 0.5, 0.5, x: along.x, y: along.y, z: 4)]), [1])
        XCTAssertEqual(hidden([outer, shape(.box, 0.5, 0.5, 0.5, x: across.x, y: across.y, z: 4)]), [])
        // 中のものが回っていても、角で判定する(回すと角が外に出る)
        XCTAssertEqual(hidden([shape(.box, 10, 2, 10), shape(.box, 9, 1, 2, z: 4)]), [1])
        XCTAssertEqual(hidden([shape(.box, 10, 2, 10), shape(.box, 9, 1, 2, z: 4, yaw: 45)]), [])
    }

    func testRoundContainers() {
        // 円柱(直径10): 6m 角の箱は入る(角まで4.24m)、7.5m 角は角が出る
        let cylinder = shape(.cylinder, 10, 10, 10)
        XCTAssertEqual(hidden([cylinder, shape(.box, 6, 6, 2, z: 4)]), [1])
        XCTAssertEqual(hidden([cylinder, shape(.box, 7.5, 7.5, 2, z: 4)]), [])
        // 球(直径10、中心の高さ5)
        let sphere = shape(.sphere, 10, 10, 10)
        XCTAssertEqual(hidden([sphere, shape(.box, 2, 2, 2, z: 4)]), [1])
        XCTAssertEqual(hidden([sphere, shape(.box, 2, 2, 2, z: 8)]), [])
        // 円錐(底の直径10、高さ10): 底の近くは入り、先の近くは出る
        let cone = shape(.cone, 10, 10, 10)
        XCTAssertEqual(hidden([cone, shape(.box, 1, 1, 1, z: 0.5)]), [1])
        XCTAssertEqual(hidden([cone, shape(.box, 1, 1, 1, z: 8)]), [])
        let pyramid = shape(.pyramid, 10, 10, 10)
        XCTAssertEqual(hidden([pyramid, shape(.box, 6, 6, 2, z: 1)]), [1])
        XCTAssertEqual(hidden([pyramid, shape(.box, 6, 6, 2, z: 5)]), [])
    }

    func testRemovingShapes() {
        let object = ScopeObject(name: "t", shapes: [shape(.box, 10, 10, 10), shape(.box, 2, 2, 2, z: 4), shape(.box, 1, 1, 1, z: 1)])
        let indices = ObjectGeometry.hiddenShapeIndices(of: object)
        XCTAssertEqual(indices, [1, 2])
        let removed = ObjectGeometry.removingShapes(indices, from: object)
        XCTAssertEqual(removed.shapes.map(\.id), [object.shapes[0].id])
        XCTAssertEqual(removed.name, object.name)
        XCTAssertEqual(ObjectGeometry.removingShapes([], from: object), object)
        // 1つも残らないときは、そのまま
        XCTAssertEqual(ObjectGeometry.removingShapes([0, 1, 2], from: object).shapes.count, 3)
    }

    func testDimensionsParse() {
        let answer = "<dimensions>\n全高: 634m\n- 第1展望台の高さ：350m\n・足元の断面: 三角形(1辺 約68m)\n\n外壁の色\n</dimensions>\n"
            + #"{"format":1,"type":"scope-object","name":"塔","shapes":[{"kind":"box"}]}"#
        let items = ObjectDimensions.parse(answer)
        XCTAssertEqual(items.map(\.label), ["全高", "第1展望台の高さ", "足元の断面", "外壁の色"])
        XCTAssertEqual(items.map(\.value), ["634m", "350m", "三角形(1辺 約68m)", ""])
        XCTAssertEqual(items.map(\.id), [0, 1, 2, 3])
        let rest = ObjectDimensions.removing(answer)
        XCTAssertFalse(rest.contains("dimensions"))
        guard case .success(let object) = ObjectCodec.parse(ToolGenerator.extractJSON(rest)) else { return XCTFail("JSON が読めない") }
        XCTAssertEqual(object.name, "塔")
        // 一覧がなければ空で、答えはそのまま
        XCTAssertEqual(ObjectDimensions.parse(#"{"name":"a"}"#), [])
        XCTAssertEqual(ObjectDimensions.removing(#"{"name":"a"}"#), #"{"name":"a"}"#)
    }

    func testDimensionsEdgeCases() {
        // 閉じる印がないときは、JSON の前まで
        let unclosed = "<dimensions>\n全高: 333m\n" + #"{"format":1,"type":"scope-object","name":"塔","shapes":[{"kind":"box"}]}"#
        XCTAssertEqual(ObjectDimensions.parse(unclosed).map(\.label), ["全高"])
        XCTAssertTrue(ObjectDimensions.removing(unclosed).hasPrefix("{"))
        // 一覧の中の「{」で、JSON を取り違えない
        let braces = "<dimensions>\n断面: {三角形}\n</dimensions>" + #"{"format":1,"type":"scope-object","name":"塔","shapes":[{"kind":"box"}]}"#
        guard case .success = ObjectCodec.parse(ToolGenerator.extractJSON(ObjectDimensions.removing(braces))) else { return XCTFail("JSON が読めない") }
        // 20行まで、1項目80文字まで
        let many = "<dimensions>\n" + (0..<30).map { "項目\($0): \($0)m" }.joined(separator: "\n") + "\n</dimensions>"
        XCTAssertEqual(ObjectDimensions.parse(many).count, ObjectDimensions.maxItems)
        let long = "<dimensions>\n高さ: " + String(repeating: "あ", count: 200) + "\n</dimensions>"
        XCTAssertEqual(ObjectDimensions.parse(long).first?.value.count, ObjectDimensions.maxLength)
    }

    func testGeneratorReportsDimensionsAndHiddenShapes() async throws {
        let json = #"{"format":1,"type":"scope-object","name":"塔","shapes":[{"kind":"box","width":10,"depth":10,"height":10},{"kind":"box","width":2,"depth":2,"height":2,"z":4}]}"#
        let outcome = try await ObjectGenerator.run(description: "塔", detail: .veryDetailed, webSearch: true, model: "m", thinking: false) { _ in
            ClaudeCallResult(response: ClaudeResponse(text: "<dimensions>\n全高: 10m\n</dimensions>\n" + json, usage: ClaudeUsage(input: 100, output: 50),
                                                      stopReason: "end_turn", model: "m"),
                             cost: 0.01)
        }
        XCTAssertEqual(outcome.dimensions.map(\.label), ["全高"])
        XCTAssertEqual(outcome.dimensions.first?.value, "10m")
        XCTAssertEqual(outcome.hiddenShapes, [1])
        XCTAssertEqual(outcome.object?.shapes.count, 2)
    }
}

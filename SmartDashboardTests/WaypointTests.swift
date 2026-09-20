import CoreGraphics
import XCTest
@testable import SmartDashboard

/// ウェイポイント: 方位角と距離、画面上の位置への変換、印の大きさ、座標の貼り付けの解析
final class WaypointTests: XCTestCase {
    /// 端末を縦向きに立てて、背面カメラを真北に向けたときの回転行列。
    /// 基準の座標系(x=北、y=西、z=上)で、画面の右=東、画面の上=上、カメラ=北。
    private let facingNorth = CameraAttitude(m11: 0, m12: -1, m13: 0, m21: 0, m22: 0, m23: 1, m31: -1, m32: 0, m33: 0)
    private let screen = CGSize(width: 375, height: 667)

    private var tangents: (horizontal: Double, vertical: Double) {
        WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: screen)
    }

    func testBearingAndDistance() {
        // 東京駅 → 東京タワー: 南西に約3.2km
        let bearing = WaypointMath.bearing(fromLatitude: 35.681236, longitude: 139.767125, toLatitude: 35.658581, longitude: 139.745433)
        let distance = WaypointMath.distance(fromLatitude: 35.681236, longitude: 139.767125, toLatitude: 35.658581, longitude: 139.745433)
        XCTAssertEqual(bearing, 217.9, accuracy: 0.1)
        XCTAssertEqual(distance, 3191.5, accuracy: 1)
        XCTAssertEqual(WaypointMath.summary(bearing: bearing, distance: distance), "南西 3.2km")
        // 東京駅 → 大阪駅: 西南西に約403km
        XCTAssertEqual(WaypointMath.bearing(fromLatitude: 35.681236, longitude: 139.767125, toLatitude: 34.702485, longitude: 135.495951), 255.6, accuracy: 0.1)
        XCTAssertEqual(WaypointMath.distance(fromLatitude: 35.681236, longitude: 139.767125, toLatitude: 34.702485, longitude: 135.495951), 403_058, accuracy: 100)
        // 真北と真東
        XCTAssertEqual(WaypointMath.bearing(fromLatitude: 35, longitude: 139, toLatitude: 36, longitude: 139), 0, accuracy: 0.001)
        XCTAssertEqual(WaypointMath.bearing(fromLatitude: 0, longitude: 139, toLatitude: 0, longitude: 140), 90, accuracy: 0.001)
        XCTAssertEqual(WaypointMath.distance(fromLatitude: 35, longitude: 139, toLatitude: 35, longitude: 139), 0, accuracy: 0.001)
    }

    func testCompassPointsAndTexts() {
        XCTAssertEqual(WaypointMath.compassPoint(0), "北")
        XCTAssertEqual(WaypointMath.compassPoint(22.4), "北")
        XCTAssertEqual(WaypointMath.compassPoint(44), "北東")
        XCTAssertEqual(WaypointMath.compassPoint(225), "南西")
        XCTAssertEqual(WaypointMath.compassPoint(337.5), "北")
        XCTAssertEqual(WaypointMath.compassPoint(-90), "西")
        XCTAssertEqual(WaypointMath.distanceText(850), "850m")
        XCTAssertEqual(WaypointMath.distanceText(2300), "2.3km")
        XCTAssertEqual(WaypointMath.distanceText(120_400), "120km")
        // コンパス表示の「右へ◯°/左へ◯°」。0度/360度の境目をまたいでも正しい
        XCTAssertEqual(WaypointMath.difference(from: 350, to: 10), 20, accuracy: 0.001)
        XCTAssertEqual(WaypointMath.difference(from: 10, to: 350), -20, accuracy: 0.001)
        XCTAssertEqual(WaypointMath.difference(from: 90, to: 270), 180, accuracy: 0.001)
    }

    func testInnerCircleSizeFollowsLogOfDistance() {
        // 10m以下で95%、15km以上で10%(それより遠くても小さくしない)
        XCTAssertEqual(WaypointMarkStyle.innerFraction(distance: 3), 0.95)
        XCTAssertEqual(WaypointMarkStyle.innerFraction(distance: 10), 0.95)
        XCTAssertEqual(WaypointMarkStyle.innerFraction(distance: 15_000), 0.10)
        XCTAssertEqual(WaypointMarkStyle.innerFraction(distance: 800_000), 0.10)
        // 間は距離の桁ごとに一定の量だけ変わる
        let f100 = WaypointMarkStyle.innerFraction(distance: 100)
        let f1000 = WaypointMarkStyle.innerFraction(distance: 1000)
        XCTAssertEqual(f100, 0.6824, accuracy: 0.001)
        XCTAssertEqual(f1000, 0.4148, accuracy: 0.001)
        XCTAssertEqual(0.95 - f100, f100 - f1000, accuracy: 0.0001)
        // 近いほど大きい。リングの内側に収まる
        XCTAssertGreaterThan(WaypointMarkStyle.innerDiameter(distance: 50), WaypointMarkStyle.innerDiameter(distance: 5000))
        XCTAssertLessThan(WaypointMarkStyle.innerDiameter(distance: 1), WaypointMarkStyle.ringDiameter - WaypointMarkStyle.ringLineWidth * 2)
    }

    func testAttitudeFromRotationMatrix() {
        XCTAssertEqual(facingNorth.forward, Vector3(x: 1, y: 0, z: 0))
        XCTAssertEqual(facingNorth.up, Vector3(x: 0, y: 0, z: 1))
        XCTAssertEqual(facingNorth.right, Vector3(x: 0, y: -1, z: 0))
        XCTAssertEqual(facingNorth.azimuth, 0, accuracy: 0.001)
        XCTAssertEqual(facingNorth.elevation, 0, accuracy: 0.001)
        // 東を向いたとき(カメラ=東=−y)
        let facingEast = CameraAttitude(right: Vector3(x: -1, y: 0, z: 0), up: Vector3(x: 0, y: 0, z: 1), forward: Vector3(x: 0, y: -1, z: 0))
        XCTAssertEqual(facingEast.azimuth, 90, accuracy: 0.001)
        // 平滑化: 重み1なら新しい値、重み0なら元のまま。長さは1に保つ
        XCTAssertEqual(facingNorth.smoothed(toward: facingEast, weight: 1), facingEast)
        XCTAssertEqual(facingNorth.smoothed(toward: facingEast, weight: 0), facingNorth)
        let halfway = facingNorth.smoothed(toward: facingEast, weight: 0.5)
        XCTAssertEqual(halfway.forward.length, 1, accuracy: 0.0001)
        XCTAssertEqual(halfway.azimuth, 45, accuracy: 0.001)
    }

    func testFieldOfViewOnScreen() {
        // 縦長の画面(iPhone SE 第2世代)に 16:9 の映像をいっぱいに表示: 縦は映像の全体、横は切り取られる
        XCTAssertEqual(tangents.vertical, tan(30 * Double.pi / 180), accuracy: 0.0001)
        XCTAssertEqual(tangents.horizontal, tan(30 * Double.pi / 180) * 375 / 667, accuracy: 0.0001)
        // 映像より横に広い画面: 横は映像の短辺の全体、縦は切り取られる
        let square = WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: CGSize(width: 400, height: 400))
        XCTAssertEqual(square.horizontal, tan(30 * Double.pi / 180) * 9 / 16, accuracy: 0.0001)
        XCTAssertEqual(square.vertical, square.horizontal, accuracy: 0.0001)
    }

    func testProjectionInsideAndOutsideOfView() throws {
        // 正面(真北)の地点は画面の中央
        let center = try XCTUnwrap(WaypointProjection.point(bearing: 0, attitude: facingNorth, tangents: tangents, viewSize: screen))
        XCTAssertEqual(center.x, 187.5, accuracy: 0.01)
        XCTAssertEqual(center.y, 333.5, accuracy: 0.01)
        // 右に10度は画面の右寄り、左に10度は左寄り(左右対称)
        let right = try XCTUnwrap(WaypointProjection.point(bearing: 10, attitude: facingNorth, tangents: tangents, viewSize: screen))
        let left = try XCTUnwrap(WaypointProjection.point(bearing: 350, attitude: facingNorth, tangents: tangents, viewSize: screen))
        XCTAssertEqual(right.x, 289.35, accuracy: 0.05)
        XCTAssertEqual(left.x, 85.65, accuracy: 0.05)
        XCTAssertEqual(right.y, 333.5, accuracy: 0.01)
        // 画角の外(右に20度)、真横、後ろは表示しない
        XCTAssertNil(WaypointProjection.point(bearing: 20, attitude: facingNorth, tangents: tangents, viewSize: screen))
        XCTAssertNil(WaypointProjection.point(bearing: 90, attitude: facingNorth, tangents: tangents, viewSize: screen))
        XCTAssertNil(WaypointProjection.point(bearing: 180, attitude: facingNorth, tangents: tangents, viewSize: screen))
        // カメラを20度上に向けると、地平線上の地点は画面の下に動く
        let rad = 20 * Double.pi / 180
        let tiltedUp = CameraAttitude(right: Vector3(x: 0, y: -1, z: 0), up: Vector3(x: -sin(rad), y: 0, z: cos(rad)),
                                      forward: Vector3(x: cos(rad), y: 0, z: sin(rad)))
        XCTAssertEqual(tiltedUp.elevation, 20, accuracy: 0.001)
        let lower = try XCTUnwrap(WaypointProjection.point(bearing: 0, attitude: tiltedUp, tangents: tangents, viewSize: screen))
        XCTAssertEqual(lower.y, 543.74, accuracy: 0.05)
        // 40度上に向けると、地平線は画面の外
        let rad40 = 40 * Double.pi / 180
        let tiltedMore = CameraAttitude(right: Vector3(x: 0, y: -1, z: 0), up: Vector3(x: -sin(rad40), y: 0, z: cos(rad40)),
                                        forward: Vector3(x: cos(rad40), y: 0, z: sin(rad40)))
        XCTAssertNil(WaypointProjection.point(bearing: 0, attitude: tiltedMore, tangents: tangents, viewSize: screen))
    }

    func testTargetsAreOrderedFarToNear() {
        let near = Waypoint(name: "近い", latitude: 35.682, longitude: 139.767)
        let far = Waypoint(name: "遠い", latitude: 34.702485, longitude: 135.495951)
        var pinned = Waypoint(name: "ピン留め", latitude: 35.658581, longitude: 139.745433)
        let targets = WaypointTarget.make([near, far, pinned], latitude: 35.681236, longitude: 139.767125)
        // 遠い地点から描くので、近い地点が手前になる
        XCTAssertEqual(targets.map(\.waypoint.name), ["遠い", "ピン留め", "近い"])
        // ホームのカード: ピン留めがなければ一番近い地点、あればピン留めした地点
        XCTAssertEqual(WaypointStore.featured([near, far, pinned], latitude: 35.681236, longitude: 139.767125)?.waypoint.name, "近い")
        pinned.isPinned = true
        XCTAssertEqual(WaypointStore.featured([near, far, pinned], latitude: 35.681236, longitude: 139.767125)?.waypoint.name, "ピン留め")
        XCTAssertNil(WaypointStore.featured([], latitude: 35, longitude: 139))
    }

    func testPinAndReorder() {
        let a = Waypoint(name: "A", latitude: 0, longitude: 0)
        let b = Waypoint(name: "B", latitude: 0, longitude: 0)
        let c = Waypoint(name: "C", latitude: 0, longitude: 0)
        // ピン留めは1つだけ。同じ地点をもう一度選ぶと外れる
        let first = WaypointStore.togglingPin([a, b, c], id: b.id)
        XCTAssertEqual(first.map(\.isPinned), [false, true, false])
        let second = WaypointStore.togglingPin(first, id: c.id)
        XCTAssertEqual(second.map(\.isPinned), [false, false, true])
        XCTAssertEqual(WaypointStore.togglingPin(second, id: c.id).map(\.isPinned), [false, false, false])
        // 並べ替え(List の onMove と同じ意味)
        XCTAssertEqual(WaypointStore.moved([a, b, c], fromOffsets: IndexSet(integer: 0), toOffset: 3).map(\.name), ["B", "C", "A"])
        XCTAssertEqual(WaypointStore.moved([a, b, c], fromOffsets: IndexSet(integer: 2), toOffset: 0).map(\.name), ["C", "A", "B"])
        XCTAssertEqual(WaypointStore.moved([a, b, c], fromOffsets: IndexSet(integer: 1), toOffset: 1).map(\.name), ["A", "B", "C"])
    }

    func testCoordinateParsing() throws {
        let plain = try XCTUnwrap(WaypointCoordinateParser.parse("35.68, 139.76"))
        XCTAssertEqual(plain.latitude, 35.68)
        XCTAssertEqual(plain.longitude, 139.76)
        // 地図アプリからコピーした形(かっこ付き、空白区切り、全角)
        XCTAssertEqual(WaypointCoordinateParser.parse("(35.681236, 139.767125)")?.longitude, 139.767125)
        XCTAssertEqual(WaypointCoordinateParser.parse("35.68 139.76")?.latitude, 35.68)
        XCTAssertEqual(WaypointCoordinateParser.parse("３５．６８，１３９．７６")?.longitude, 139.76)
        XCTAssertEqual(WaypointCoordinateParser.parse(" -33.8568,151.2153\n")?.latitude, -33.8568)
        // 数が2つでない、範囲の外、数でないものは受け付けない
        XCTAssertNil(WaypointCoordinateParser.parse("35.68"))
        XCTAssertNil(WaypointCoordinateParser.parse("35.68, 139.76, 10"))
        XCTAssertNil(WaypointCoordinateParser.parse("91, 10"))
        XCTAssertNil(WaypointCoordinateParser.parse("35.68, 181"))
        XCTAssertNil(WaypointCoordinateParser.parse("1.2.3, 4"))
        XCTAssertNil(WaypointCoordinateParser.parse("東京駅"))
        XCTAssertNil(WaypointCoordinateParser.parse(""))
    }

    func testHeadingQuality() {
        XCTAssertEqual(HeadingQuality.make(accuracy: nil), .unknown)
        XCTAssertEqual(HeadingQuality.make(accuracy: 10), .good(10))
        XCTAssertFalse(HeadingQuality.make(accuracy: 10).needsCalibration)
        // 精度が悪い、または無効なときは、8の字の案内を出す
        XCTAssertTrue(HeadingQuality.make(accuracy: 35).needsCalibration)
        XCTAssertTrue(HeadingQuality.make(accuracy: -1).needsCalibration)
        XCTAssertEqual(HeadingQuality.make(accuracy: 35).text, "方位の精度: ±35°")
    }
}

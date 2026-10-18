import XCTest
@testable import SmartDashboard

/// カメラ表示の投影: 方角どおりの場所に描かれるか、地点・電車・山・オブジェクトが同じ投影で同じ場所に来るか
final class ProjectionTests: XCTestCase {
    private let size = CGSize(width: 375, height: 667)
    private let tangents = (horizontal: 0.6, vertical: 1.0)
    private let user = GeoPoint(35.68, 139.76)

    /// 背面カメラの方角・仰角の姿勢(傾きなし)。CMRotationMatrix と同じ形の値から作る
    private func camera(azimuth: Double, elevation: Double = 0) -> CameraAttitude {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        let forward = Vector3(x: cos(e) * cos(a), y: -cos(e) * sin(a), z: sin(e))
        let right = Vector3(x: cos(a + .pi / 2), y: -sin(a + .pi / 2), z: 0)
        let up = Vector3.cross(right, forward)
        return CameraAttitude(m11: right.x, m12: right.y, m13: right.z, m21: up.x, m22: up.y, m23: up.z,
                              m31: -forward.x, m32: -forward.y, m33: -forward.z)
    }

    /// 現在地から、方角 bearing へ distance m の点
    private func point(bearing: Double, distance: Double) -> GeoPoint {
        let rad = bearing * .pi / 180
        return GeoMath.offset(user, east: distance * sin(rad), north: distance * cos(rad))
    }

    private func project(_ target: GeoPoint, attitude: CameraAttitude) -> CGPoint? {
        let bearing = WaypointMath.bearing(fromLatitude: user.latitude, longitude: user.longitude,
                                           toLatitude: target.latitude, longitude: target.longitude)
        return WaypointProjection.point(bearing: bearing, attitude: attitude, tangents: tangents, viewSize: size)
    }

    func testCardinalPointsAreAtCenterWhenFacingThem() {
        for (name, bearing) in [("北", 0.0), ("東", 90), ("南", 180), ("西", 270)] {
            let target = point(bearing: bearing, distance: 500)
            let projected = project(target, attitude: camera(azimuth: bearing))
            XCTAssertEqual(projected?.x ?? -1, size.width / 2, accuracy: 0.5, name)
            XCTAssertEqual(projected?.y ?? -1, size.height / 2, accuracy: 0.5, name)
            // 反対を向いたら描かない(カメラの後ろ)
            XCTAssertNil(project(target, attitude: camera(azimuth: bearing + 180)), name)
            // 90°横を向いたら、画面の外
            XCTAssertNil(project(target, attitude: camera(azimuth: bearing + 90)), name)
        }
    }

    func testNortheastIsRightOfNorthAndNorthwestIsLeft() {
        let north = camera(azimuth: 0)
        let northeast = project(point(bearing: 20, distance: 500), attitude: north)
        let northwest = project(point(bearing: 340, distance: 500), attitude: north)
        XCTAssertGreaterThan(northeast?.x ?? 0, size.width / 2 + 50)
        XCTAssertLessThan(northwest?.x ?? .infinity, size.width / 2 - 50)
        XCTAssertEqual(northeast?.y ?? 0, size.height / 2, accuracy: 0.5)
        // 45°の北東は、画角(左右に約31°)の外なので描かない
        XCTAssertNil(project(point(bearing: 45, distance: 500), attitude: north))
        // 北東を向けば中央
        XCTAssertEqual(project(point(bearing: 45, distance: 500), attitude: camera(azimuth: 45))?.x ?? -1, size.width / 2, accuracy: 0.5)
        // 上にあるものは中央より上
        let above = WaypointProjection.point(bearing: 0, elevation: 10, attitude: north, tangents: tangents, viewSize: size)
        XCTAssertLessThan(above?.y ?? .infinity, size.height / 2)
    }

    func testCompassRoseUsesSameProjection() {
        // 北を向くと「北」が中央、「東」は画面の外
        let north = ScopeCompassRose.marks(attitude: camera(azimuth: 0), tangents: tangents, size: size)
        XCTAssertEqual(north.map(\.name), ["北"])
        XCTAssertEqual(north.first?.point.x ?? -1, size.width / 2, accuracy: 1e-6)
        // 方角20°を向くと、「北」は左、「北東」は右
        let turned = ScopeCompassRose.marks(attitude: camera(azimuth: 20), tangents: tangents, size: size)
        let northMark = turned.first { $0.name == "北" }
        let northeastMark = turned.first { $0.name == "北東" }
        XCTAssertLessThan(northMark?.point.x ?? .infinity, size.width / 2)
        XCTAssertGreaterThan(northeastMark?.point.x ?? 0, size.width / 2)
        // 東を向くと「東」が中央
        let east = ScopeCompassRose.marks(attitude: camera(azimuth: 90), tangents: tangents, size: size)
        XCTAssertEqual(east.first { $0.name == "東" }?.point.x ?? -1, size.width / 2, accuracy: 1e-6)
        XCTAssertTrue(ScopeCompassRose.marks(attitude: camera(azimuth: 90), tangents: tangents, size: size).allSatisfy { $0.isCardinal == ($0.name.count == 1) })
        // 中央の文字
        XCTAssertEqual(ScopeCompassRose.centerText(azimuth: 123), "中央 123° → 南東(135°)の印が右に12°")
        XCTAssertEqual(ScopeCompassRose.centerText(azimuth: 350), "中央 350° → 北(0°)の印が右に10°")
        XCTAssertEqual(ScopeCompassRose.centerText(azimuth: 95), "中央 95° → 東(90°)の印が左に5°")
        XCTAssertEqual(ScopeCompassRose.centerText(azimuth: 270), "中央 270° → 西(270°)が中央")
        XCTAssertFalse(ScopeCompassRose.horizon(attitude: camera(azimuth: 0), tangents: tangents, size: size).isEmpty)
    }

    func testLocationErrorTurnsNearbyDirections() {
        // 位置の誤差 10m で 100m 先は約6°、誤差 100m で 50m 先は方向が決まらない
        XCTAssertEqual(ScopeLocationCheck.bearingUncertainty(accuracy: 10, distance: 100), asin(0.1) * 180 / .pi, accuracy: 1e-9)
        XCTAssertEqual(ScopeLocationCheck.bearingUncertainty(accuracy: 100, distance: 50), 180)
        XCTAssertNotNil(ScopeLocationCheck.warning(accuracy: 5, isReduced: true, nearest: 5_000))
        XCTAssertNotNil(ScopeLocationCheck.warning(accuracy: 30, isReduced: false, nearest: 50))
        XCTAssertNil(ScopeLocationCheck.warning(accuracy: 5, isReduced: false, nearest: 500))
        XCTAssertNil(ScopeLocationCheck.warning(accuracy: nil, isReduced: false, nearest: 50))
    }

    func testWaypointTrainMountainAndObjectLandOnSamePoint() {
        // 現在地から方角60°・300m、地面(標高0)の点を、方角50°を向いたカメラで見る。目の高さは1.5m
        let distance = 300.0
        let target = point(bearing: 60, distance: distance)
        let attitude = camera(azimuth: 50)
        let eye = 1.5

        // 地点
        let mark = ScopeMark(id: "p", name: "地点", latitude: target.latitude, longitude: target.longitude, color: .red, altitude: 0)
        let waypointTarget = ScopeTarget.make([mark], latitude: user.latitude, longitude: user.longitude, observerAltitude: eye)[0]
        let waypoint = WaypointProjection.point(bearing: waypointTarget.bearing, elevation: waypointTarget.elevationAngle,
                                                attitude: attitude, tangents: tangents, viewSize: size)

        // 電車の車両の箱(その点を中心に、下の面を地面に置いた箱の、下の面の中心)
        let corners = ScopeTrainGeometry.corners(center: target, bearing: 0, base: -eye, user: user)
        let bottom = corners.prefix(4)
        let bottomCenter = Vector3(x: bottom.map(\.x).reduce(0, +) / 4, y: bottom.map(\.y).reduce(0, +) / 4, z: bottom.map(\.z).reduce(0, +) / 4)
        let train = ScopeTrainRenderer.project(bottomCenter, attitude: attitude, tangents: tangents, size: size)
        let trainPoint = ScopeTrainRenderer.project(ScopeTrainRenderer.vector(target, up: -eye, user: user), attitude: attitude,
                                                    tangents: tangents, size: size)

        // 山(景色)
        let entry = MountainCatalog.Entry(index: 0, name: "山", peak: "", elevation: 0, latitude: target.latitude, longitude: target.longitude,
                                          prefecture: "")
        let mountain = SceneryMountain(entry: entry, bearing: waypointTarget.bearing, distance: waypointTarget.distance,
                                       angle: WaypointElevation.angle(targetAltitude: 0, observerAltitude: eye, distance: waypointTarget.distance),
                                       visibility: .visible, priority: 1)
        let scene = SceneryScene(latitude: user.latitude, longitude: user.longitude, eye: eye, radius: 100_000, skyline: nil, ridges: [],
                                 mountains: [mountain], water: [], labels: [], coverage: 1, computedAt: Date())
        let scenery = SceneryRenderer.layout(scene: scene, options: SceneryDrawOptions(layers: [.mountains], showsHiddenMountains: true),
                                             attitude: attitude, tangents: tangents, size: size).mountains.first?.point

        // オブジェクト(置いた所の地面の点)
        let placement = ObjectPlacement(objectID: UUID(), name: "物", latitude: target.latitude, longitude: target.longitude,
                                        groundElevation: 0, elevationState: .fetched)
        let base = GeoMath.local(target, origin: user)
        let ground = ObjectRenderer.ground(placement, observerAltitude: eye, handHeight: eye) - eye
            - WaypointElevation.curvatureDrop(distance: distance)
        let object = ScopeTrainRenderer.project(ObjectRenderer.vector(ObjectPoint(0, 0, 0), placement: placement, base: base, groundRelative: ground),
                                                attitude: attitude, tangents: tangents, size: size)

        guard let waypoint else { return XCTFail("地点が画面に入らない") }
        // 方角は10°右なので、中央より右、地面なので中央より下
        XCTAssertGreaterThan(waypoint.x, size.width / 2 + 50)
        XCTAssertGreaterThan(waypoint.y, size.height / 2)
        for (name, other) in [("電車の箱", train), ("電車の点", trainPoint), ("山", scenery), ("オブジェクト", object)] {
            XCTAssertEqual(other?.x ?? -1, waypoint.x, accuracy: 1, name)
            XCTAssertEqual(other?.y ?? -1, waypoint.y, accuracy: 1, name)
        }
    }
}

import CoreGraphics
import XCTest
@testable import SmartDashboard

/// スコープの電車: 対象の路線と列車の選び方(距離、本数の上限、近い順)、接近中の判定、車両の箱の形
final class ScopeTrainTests: XCTestCase {
    private let user = GeoPoint(35.6812, 139.7671)

    private func train(_ id: String, distance: Double, railway: String = "r", kind: RailwayKind = .subway,
                       approaching: Bool = false) -> ScopeTrain {
        ScopeTrain(id: id, railwayID: railway, lineName: "浅草線", colorHex: "#FF535F", number: "1", trainType: "急行", destination: "西馬込",
                   delay: .timetable, kind: kind, cars: 8, along: 100, speed: 10, forward: true, head: user, heading: 0,
                   distance: distance, isApproaching: approaching, isStopped: false, computedAt: Date(timeIntervalSince1970: 1000))
    }

    /// 現在地から東へ east m、北へ north m の点を結ぶ線
    private func line(_ points: [(east: Double, north: Double)]) -> GeoPath {
        GeoPath(points.map { GeoMath.offset(user, east: $0.east, north: $0.north) })
    }

    func testRailwayKindsAndDefaultCars() {
        XCTAssertEqual(RailwayKind.classify(railwayID: "odpt.Railway:Toei.Arakawa", name: "東京さくらトラム（都電荒川線）"), .tram)
        XCTAssertEqual(RailwayKind.classify(railwayID: "odpt.Railway:Toei.NipporiToneri", name: "日暮里・舎人ライナー"), .guideway)
        XCTAssertEqual(RailwayKind.classify(railwayID: "odpt.Railway:TamaMonorail.TamaMonorail", name: "多摩モノレール"), .monorail)
        XCTAssertEqual(RailwayKind.classify(railwayID: "odpt.Railway:Yurikamome.Yurikamome", name: "ゆりかもめ"), .guideway)
        XCTAssertEqual(RailwayKind.classify(railwayID: "odpt.Railway:TokyoMetro.Ginza", name: "銀座線"), .subway)
        XCTAssertEqual(RailwayKind.classify(railwayID: "odpt.Railway:Toei.Asakusa", name: "浅草線"), .subway)
        XCTAssertEqual(RailwayKind.classify(railwayID: "odpt.Railway:MIR.TsukubaExpress", name: "つくばエクスプレス"), .railway)
        XCTAssertEqual(RailwayKind.subway.defaultCars, 10)
        XCTAssertEqual(RailwayKind.monorail.defaultCars, 4)
        XCTAssertEqual(RailwayKind.guideway.defaultCars, 6)
        XCTAssertEqual(RailwayKind.tram.defaultCars, 1)
    }

    func testTargetRailways() {
        // a: 現在地から北へ500m(東西の線)、b: 北へ5km、c: 線路の形がない
        let a = line([(-2000, 500), (2000, 500)])
        let b = line([(-2000, 5000), (2000, 5000)])
        let available: [(id: String, path: GeoPath?)] = [("a", a), ("b", b), ("c", nil)]
        // 登録した路線: 時刻表を保存している路線のうち、登録したもの(並びは保存の順)
        XCTAssertEqual(ScopeTrainSelection.railways(target: .registered, registered: ["c", "a", "x"], available: available, user: user, radius: 3000),
                       ["a", "c"])
        // 近くを通る路線: 線までの距離が範囲の中のもの
        XCTAssertEqual(ScopeTrainSelection.railways(target: .nearby, registered: [], available: available, user: user, radius: 3000), ["a"])
        XCTAssertEqual(ScopeTrainSelection.railways(target: .nearby, registered: [], available: available, user: user, radius: 6000), ["a", "b"])
        XCTAssertEqual(ScopeTrainSelection.railways(target: .nearby, registered: [], available: available, user: user, radius: 400), [])
        // 現在地が分からなければ、近くを通る路線は決められない
        XCTAssertEqual(ScopeTrainSelection.railways(target: .nearby, registered: [], available: available, user: nil, radius: 3000), [])
    }

    func testNearestTrainsUpToTheLimit() {
        let list = [train("far", distance: 2500), train("near", distance: 300), train("middle", distance: 900), train("tie", distance: 300)]
        XCTAssertEqual(ScopeTrainSelection.nearest(list, limit: 3).map(\.id), ["near", "tie", "middle"])
        XCTAssertEqual(ScopeTrainSelection.nearest(list, limit: 20).count, 4)
        XCTAssertTrue(ScopeTrainSelection.nearest(list, limit: 0).isEmpty)
    }

    func testApproaching() {
        let south = GeoMath.offset(user, east: 0, north: -800)
        // 南にいて、北へ向かって走る列車は近づいてくる
        XCTAssertTrue(ScopeTrainSelection.isApproaching(heading: 0, train: south, user: user, isStopped: false))
        XCTAssertTrue(ScopeTrainSelection.isApproaching(heading: 60, train: south, user: user, isStopped: false))
        // 南へ向かって走る列車は遠ざかる
        XCTAssertFalse(ScopeTrainSelection.isApproaching(heading: 180, train: south, user: user, isStopped: false))
        // 横に並んで走る(真横を通り過ぎた)列車は、ちょうど90度で近づいていない
        XCTAssertFalse(ScopeTrainSelection.isApproaching(heading: 100, train: south, user: user, isStopped: false))
        // 止まっている列車と、向きが分からない列車は「接近中」にしない
        XCTAssertFalse(ScopeTrainSelection.isApproaching(heading: 0, train: south, user: user, isStopped: true))
        XCTAssertFalse(ScopeTrainSelection.isApproaching(heading: nil, train: south, user: user, isStopped: false))
    }

    func testSpeedForSmoothMotion() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ScopeTrainSelection.speed(previousAlong: 100, previousTime: t0, along: 115, time: t0.addingTimeInterval(1), isStopped: false), 15)
        XCTAssertEqual(ScopeTrainSelection.speed(previousAlong: 115, previousTime: t0, along: 100, time: t0.addingTimeInterval(1), isStopped: false), -15)
        XCTAssertEqual(ScopeTrainSelection.speed(previousAlong: 100, previousTime: t0, along: 115, time: t0.addingTimeInterval(1), isStopped: true), 0)
        XCTAssertEqual(ScopeTrainSelection.speed(previousAlong: nil, previousTime: nil, along: 115, time: t0, isStopped: false), 0)
        // 飛びすぎ(別の区間に移った)と、間隔が長すぎるときは0
        XCTAssertEqual(ScopeTrainSelection.speed(previousAlong: 0, previousTime: t0, along: 500, time: t0.addingTimeInterval(1), isStopped: false), 0)
        XCTAssertEqual(ScopeTrainSelection.speed(previousAlong: 0, previousTime: t0, along: 50, time: t0.addingTimeInterval(10), isStopped: false), 0)
        // 描く時刻の分だけ先へ進める(1.5秒まで)
        let moving = train("a", distance: 100)
        XCTAssertEqual(moving.headAlong(at: moving.computedAt.addingTimeInterval(0.5)), 105)
        XCTAssertEqual(moving.headAlong(at: moving.computedAt.addingTimeInterval(10)), 115)
        XCTAssertEqual(moving.headAlong(at: moving.computedAt.addingTimeInterval(-1)), 100)
    }

    func testCaption() {
        // 高さのデータがない列車は、地面の高さに置き「高さは目安」
        XCTAssertEqual(train("a", distance: 1234, approaching: true).caption, "急 西馬込行 1.2km 高さは目安・接近中・地下鉄")
        XCTAssertEqual(train("a", distance: 850, kind: .railway).caption, "急 西馬込行 850m 高さは目安")
        // 高架: 高低差を出す。地下と分かっている地下鉄には「地下鉄」と添えない
        var elevated = train("a", distance: 350, kind: .railway, approaching: true)
        elevated.section = .elevated
        elevated.heightIsEstimate = false
        elevated.heightDifference = 8.2
        XCTAssertEqual(elevated.caption, "急 西馬込行 350m ↑8m 接近中")
        var underground = train("a", distance: 1234)
        underground.section = .underground
        underground.heightIsEstimate = false
        underground.heightDifference = -15.4
        XCTAssertEqual(underground.caption, "急 西馬込行 1.2km 地下 ↓15m")
        XCTAssertEqual(underground.heightCaption, "地下 ↓15m")
        // 自分の高さが分からない地下の列車
        underground.heightDifference = nil
        underground.heightIsEstimate = true
        XCTAssertEqual(underground.caption, "急 西馬込行 1.2km 地下 高さは目安・地下鉄")
    }

    func testCarCenters() {
        // 先頭から後ろへ20mずつ(線の始点から終点へ向かうときは、後ろは始点の側)
        XCTAssertEqual(ScopeTrainGeometry.carCenters(headAlong: 500, forward: true, cars: 3, pathLength: 1000), [490, 470, 450])
        XCTAssertEqual(ScopeTrainGeometry.carCenters(headAlong: 500, forward: false, cars: 3, pathLength: 1000), [510, 530, 550])
        // 線の外に出る車両は入れない
        XCTAssertEqual(ScopeTrainGeometry.carCenters(headAlong: 30, forward: true, cars: 4, pathLength: 1000), [20, 0])
        XCTAssertEqual(ScopeTrainGeometry.carCenters(headAlong: 500, forward: true, cars: 0, pathLength: 1000), [490])
    }

    func testCarBoxAndVisibleFaces() {
        // 100m北で、東を向いた車両。自分は地面から1.5mの高さ(箱の下は −1.5m)
        let center = GeoMath.offset(user, east: 0, north: 100)
        let corners = ScopeTrainGeometry.corners(center: center, bearing: 90, base: -1.5, user: user)
        XCTAssertEqual(corners.count, 8)
        // 長さ20m(東西)、幅2.8m(南北)、高さ3.5m
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        XCTAssertEqual(xs.max()! - xs.min()!, 2.8, accuracy: 0.01)
        XCTAssertEqual(ys.max()! - ys.min()!, 20, accuracy: 0.01)
        XCTAssertEqual(corners[4].z - corners[0].z, 3.5, accuracy: 0.0001)
        XCTAssertEqual(corners.map(\.x).reduce(0, +) / 8, 100, accuracy: 0.1)
        // 見えるのは、こちら(南)を向いた側面だけ(屋根は目より上、前と後ろは横から見えない)
        XCTAssertEqual(ScopeTrainGeometry.visibleFaces(corners), [.right])
        // 丘の上から見下ろすと、屋根も見える
        let below = ScopeTrainGeometry.corners(center: center, bearing: 90, base: -30, user: user)
        XCTAssertEqual(ScopeTrainGeometry.visibleFaces(below), [.right, .top])
        // 線路の先に立って正面から見ると、前の面が見える
        let ahead = ScopeTrainGeometry.corners(center: GeoMath.offset(user, east: -100, north: 0), bearing: 90, base: -1.5, user: user)
        XCTAssertEqual(ScopeTrainGeometry.visibleFaces(ahead), [.front])
    }

    func testProjectionAndHit() throws {
        let facingNorth = CameraAttitude(m11: 0, m12: -1, m13: 0, m21: 0, m22: 0, m23: 1, m31: -1, m32: 0, m33: 0)
        let size = CGSize(width: 375, height: 667)
        let tangents = WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: size)
        // 正面(北)100mの目の高さは、画面の中央
        let center = try XCTUnwrap(ScopeTrainRenderer.project(Vector3(x: 100, y: 0, z: 0), attitude: facingNorth, tangents: tangents, size: size))
        XCTAssertEqual(center.x, size.width / 2, accuracy: 0.5)
        XCTAssertEqual(center.y, size.height / 2, accuracy: 0.5)
        // 画面の外でも位置は返す(はみ出す部分は Canvas が切り取る)。後ろ側は返さない。
        XCTAssertNotNil(ScopeTrainRenderer.project(Vector3(x: 100, y: -100, z: 0), attitude: facingNorth, tangents: tangents, size: size))
        XCTAssertNil(ScopeTrainRenderer.project(Vector3(x: -100, y: 0, z: 0), attitude: facingNorth, tangents: tangents, size: size))
        XCTAssertNil(ScopeTrainRenderer.project(Vector3(x: 0.5, y: 0, z: 0), attitude: facingNorth, tangents: tangents, size: size))

        func item(_ id: String, _ point: CGPoint, _ distance: Double) -> ScopeTrainRenderer.Item {
            ScopeTrainRenderer.Item(id: id, distance: distance, kind: .ring(center: point, inner: 10, arrow: nil), color: .red, isDelayed: false,
                                    outline: .black, outlineWidth: 1, labelAnchor: point, hitPoint: point, caption: "")
        }
        let items = [item("far", CGPoint(x: 100, y: 100), 900), item("near", CGPoint(x: 104, y: 100), 200), item("other", CGPoint(x: 300, y: 300), 100)]
        // 同じくらいの位置なら、近い列車
        XCTAssertEqual(ScopeTrainRenderer.hit(CGPoint(x: 102, y: 100), items: items), "near")
        XCTAssertEqual(ScopeTrainRenderer.hit(CGPoint(x: 300, y: 320), items: items), "other")
        XCTAssertNil(ScopeTrainRenderer.hit(CGPoint(x: 200, y: 200), items: items))
    }

    func testCarCompositionFromTimetable() throws {
        let json = #"""
        [{"owl:sameAs":"odpt.TrainTimetable:X.A.1.Weekday","odpt:trainNumber":"1","odpt:calendar":"odpt.Calendar:Weekday","odpt:carComposition":6,
          "odpt:trainTimetableObject":[{"odpt:departureTime":"10:00","odpt:departureStation":"odpt.Station:X.A.S1"},
                                       {"odpt:arrivalTime":"10:03","odpt:arrivalStation":"odpt.Station:X.A.S2"}]},
         {"owl:sameAs":"odpt.TrainTimetable:X.A.2.Weekday","odpt:trainNumber":"2","odpt:calendar":"odpt.Calendar:Weekday",
          "odpt:trainTimetableObject":[{"odpt:departureTime":"11:00","odpt:departureStation":"odpt.Station:X.A.S1"},
                                       {"odpt:arrivalTime":"11:03","odpt:arrivalStation":"odpt.Station:X.A.S2"}]}]
        """#
        let tables = try ODPTClient.decode([ODPTTrainTimetable].self, from: Data(json.utf8))
        let schedule = LineSchedule(railwayID: "odpt.Railway:X.A", downloadedAt: Date(), orderedStationIDs: ["odpt.Station:X.A.S1", "odpt.Station:X.A.S2"],
                                    timetables: tables, trainTypeNames: [:], stationNames: [:])
        XCTAssertEqual(schedule.trains.map(\.cars), [6, nil])
        // 以前に保存した時刻表(両数の項目がない)も読める
        let decoded = try JSONDecoder().decode(LineSchedule.self, from: JSONEncoder().encode(schedule))
        XCTAssertEqual(decoded.trains.map(\.cars), [6, nil])
    }
}

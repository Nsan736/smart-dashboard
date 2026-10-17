import CoreGraphics
import XCTest
@testable import SmartDashboard

/// スコープの地点: 表示・非表示、地点の高さ、仰角と地球の丸みの補正、自分の高さの選び方、標高APIの読み取り
final class WaypointHeightTests: XCTestCase {
    /// 端末を縦向きに立てて、背面カメラを真北に向けたとき(WaypointTests と同じ)
    private let facingNorth = CameraAttitude(m11: 0, m12: -1, m13: 0, m21: 0, m22: 0, m23: 1, m31: -1, m32: 0, m33: 0)
    private let screen = CGSize(width: 375, height: 667)

    // MARK: - 保存済みの地点の引き継ぎ

    func testDecodesWaypointsSavedByOlderVersions() throws {
        let old = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"東京タワー","latitude":35.658581,"longitude":139.745433,"colorIndex":2,"memo":"","isPinned":true}]"#
        let list = try JSONDecoder().decode([Waypoint].self, from: Data(old.utf8))
        let waypoint = try XCTUnwrap(list.first)
        XCTAssertEqual(waypoint.name, "東京タワー")
        XCTAssertTrue(waypoint.isPinned)
        // 保存済みの地点は「表示」、標高は「未設定」として引き継ぐ
        XCTAssertFalse(waypoint.isHidden)
        XCTAssertNil(waypoint.groundElevation)
        XCTAssertEqual(waypoint.elevationState, .unset)
        XCTAssertEqual(waypoint.heightAboveGround, 0)
        XCTAssertNil(waypoint.altitude)

        // 新しい項目は保存して読み直せる。知らない状態の値は未設定として読む。
        var edited = waypoint
        edited.isHidden = true
        edited.groundElevation = 18.5
        edited.elevationState = .fetched
        edited.heightAboveGround = 250
        let decoded = try JSONDecoder().decode(Waypoint.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(decoded, edited)
        XCTAssertEqual(decoded.altitude, 268.5)
        let unknown = #"{"name":"A","latitude":0,"longitude":0,"elevationState":"somethingNew"}"#
        XCTAssertEqual(try JSONDecoder().decode(Waypoint.self, from: Data(unknown.utf8)).elevationState, .unset)
    }

    // MARK: - 表示・非表示

    func testFilterAndFeaturedSkipHiddenWaypoints() {
        var near = Waypoint(name: "近い", latitude: 35.682, longitude: 139.767)
        let middle = Waypoint(name: "中くらい", latitude: 35.69, longitude: 139.77)
        let far = Waypoint(name: "遠い", latitude: 34.702485, longitude: 135.495951)
        near.isHidden = true
        let all = [near, middle, far]
        XCTAssertEqual(WaypointListFilter.apply(all, filter: .visible).map(\.name), ["中くらい", "遠い"])
        XCTAssertEqual(WaypointListFilter.apply(all, filter: .all).count, 3)
        // 一番近い地点は、表示中の地点から選ぶ
        XCTAssertEqual(WaypointStore.featured(all, latitude: 35.681236, longitude: 139.767125)?.waypoint.name, "中くらい")
        // ピン留めした地点は、非表示でもピン留めのまま(カードに「非表示中」と出す)
        var pinned = far
        pinned.isPinned = true
        pinned.isHidden = true
        XCTAssertEqual(WaypointStore.featured([near, middle, pinned], latitude: 35.681236, longitude: 139.767125)?.waypoint.name, "遠い")
        // 全部非表示で、ピン留めもなければ出さない
        var hiddenMiddle = middle
        hiddenMiddle.isHidden = true
        XCTAssertNil(WaypointStore.featured([near, hiddenMiddle], latitude: 35.681236, longitude: 139.767125))
    }

    func testMovingAWaypointResetsItsElevation() {
        var old = Waypoint(name: "A", latitude: 35.0, longitude: 139.0, groundElevation: 100, elevationState: .fetched)
        var moved = old
        moved.latitude = 35.01
        // 場所を変えたら、取得した標高は取り直す
        XCTAssertNil(WaypointStore.updating(old, with: moved).groundElevation)
        XCTAssertEqual(WaypointStore.updating(old, with: moved).elevationState, .unset)
        // 同じ編集で標高を手で入れ直したときは、その値を使う
        moved.groundElevation = 250
        moved.elevationState = .manual
        XCTAssertEqual(WaypointStore.updating(old, with: moved).groundElevation, 250)
        // 場所を変えなければ、そのまま
        var renamed = old
        renamed.name = "B"
        XCTAssertEqual(WaypointStore.updating(old, with: renamed), renamed)
        // 手で入れた標高のまま場所だけ変えたら、取り直す
        old.elevationState = .manual
        var movedManual = old
        movedManual.longitude = 139.01
        XCTAssertEqual(WaypointStore.updating(old, with: movedManual).elevationState, .unset)
    }

    // MARK: - 地点の高さと仰角

    func testCurvatureDrop() {
        // 距離²÷(2×地球の半径)×(1−屈折の係数0.13)
        XCTAssertEqual(WaypointElevation.curvatureDrop(distance: 1000), 0.0683, accuracy: 0.0001)
        XCTAssertEqual(WaypointElevation.curvatureDrop(distance: 10_000), 6.828, accuracy: 0.001)
        XCTAssertEqual(WaypointElevation.curvatureDrop(distance: 100_000), 682.78, accuracy: 0.01)
    }

    func testElevationAngles() {
        // 近い地点: 1km先のタワーの展望台(標高18m+地面から250m)を、地面(標高3m)で手の高さ1.5mから見上げる
        XCTAssertEqual(WaypointElevation.angle(targetAltitude: 268, observerAltitude: 4.5, distance: 1000), 14.758, accuracy: 0.001)
        // 遠い山: 100km先の山頂(3776m)を、標高40mから。地球の丸みで約683m低く見え、補正なしの2.14度より低い
        XCTAssertEqual(WaypointElevation.angle(targetAltitude: 3776, observerAltitude: 40, distance: 100_000), 1.7488, accuracy: 0.0001)
        // 自分より低い地点: 標高600mの丘から、2km先の標高10mの地点を見下ろす
        XCTAssertEqual(WaypointElevation.angle(targetAltitude: 10, observerAltitude: 600, distance: 2000), -16.443, accuracy: 0.001)
        // 同じ高さでも、50km先は地球の丸みで少し下に見える
        XCTAssertEqual(WaypointElevation.angle(targetAltitude: 100, observerAltitude: 100, distance: 50_000), -0.1956, accuracy: 0.0001)
        // 距離0でも割り算にならない(1mとみなす)
        XCTAssertEqual(WaypointElevation.angle(targetAltitude: 101, observerAltitude: 100, distance: 0), 45, accuracy: 0.01)
    }

    func testTargetsUseHeightOnlyWhenKnownAndEnabled() throws {
        let tower = ScopeMark(id: "tower", name: "タワー", latitude: 35.6586, longitude: 139.7454, color: .red, altitude: 268)
        let unknown = ScopeMark(id: "unknown", name: "未設定", latitude: 35.66, longitude: 139.75, color: .blue)
        let targets = ScopeTarget.make([tower, unknown], latitude: 35.6676, longitude: 139.7454, observerAltitude: 4.5)
        let towerTarget = try XCTUnwrap(targets.first { $0.id == "tower" })
        XCTAssertEqual(towerTarget.heightDifference ?? 0, 263.5, accuracy: 0.001)
        XCTAssertEqual(towerTarget.elevationAngle,
                       WaypointElevation.angle(targetAltitude: 268, observerAltitude: 4.5, distance: towerTarget.distance), accuracy: 0.0001)
        XCTAssertGreaterThan(towerTarget.elevationAngle, 10)
        // 標高が未設定の地点は、地平線の高さ(仰角0)で、高低差も出さない
        let unknownTarget = try XCTUnwrap(targets.first { $0.id == "unknown" })
        XCTAssertEqual(unknownTarget.elevationAngle, 0)
        XCTAssertNil(unknownTarget.heightDifference)
        // 「高さを反映する」がオフなら仰角は0(高低差の表示は残す)
        let flat = ScopeTarget.make([tower], latitude: 35.6676, longitude: 139.7454, observerAltitude: 4.5, usesHeight: false)
        XCTAssertEqual(flat.first?.elevationAngle, 0)
        XCTAssertNotNil(flat.first?.heightDifference)
        // 自分の高さが分からなければ、どちらも出さない
        XCTAssertEqual(ScopeTarget.make([tower], latitude: 35.6676, longitude: 139.7454).first?.elevationAngle, 0)
    }

    func testProjectionWithElevation() throws {
        let tangents = WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: screen)
        let level = try XCTUnwrap(WaypointProjection.point(bearing: 0, attitude: facingNorth, tangents: tangents, viewSize: screen))
        XCTAssertEqual(level.y, screen.height / 2, accuracy: 0.5)
        // 見上げる地点は画面の上へ、見下ろす地点は下へ。tan(仰角) が縦の半分の正接の半分なら、上から1/4の位置。
        let halfway = atan(tangents.vertical / 2) * 180 / .pi
        let up = try XCTUnwrap(WaypointProjection.point(bearing: 0, elevation: halfway, attitude: facingNorth, tangents: tangents, viewSize: screen))
        XCTAssertEqual(up.y, screen.height / 4, accuracy: 0.5)
        XCTAssertEqual(up.x, screen.width / 2, accuracy: 0.5)
        let down = try XCTUnwrap(WaypointProjection.point(bearing: 0, elevation: -halfway, attitude: facingNorth, tangents: tangents, viewSize: screen))
        XCTAssertEqual(down.y, screen.height * 3 / 4, accuracy: 0.5)
        // 画面の上の外(見上げすぎ)は描かない
        XCTAssertNil(WaypointProjection.point(bearing: 0, elevation: 60, attitude: facingNorth, tangents: tangents, viewSize: screen))
    }

    // MARK: - 自分の高さ

    func testObserverHeightSource() {
        // 地面の標高+手の高さ
        XCTAssertEqual(ObserverHeight.resolve(source: .groundPlusHand, gpsAltitude: 40, groundElevation: 18.5, handHeight: 1.5),
                       ObserverHeight(meters: 20, method: .ground))
        // 地面の標高が取れないときはGPSの高度
        XCTAssertEqual(ObserverHeight.resolve(source: .groundPlusHand, gpsAltitude: 40, groundElevation: nil, handHeight: 1.5),
                       ObserverHeight(meters: 40, method: .gps))
        // GPSの高度を選んだときは、地面の標高があってもGPS
        XCTAssertEqual(ObserverHeight.resolve(source: .gps, gpsAltitude: 40, groundElevation: 18.5, handHeight: 1.5),
                       ObserverHeight(meters: 40, method: .gps))
        XCTAssertNil(ObserverHeight.resolve(source: .gps, gpsAltitude: nil, groundElevation: 18.5, handHeight: 1.5))
        XCTAssertNil(ObserverHeight.resolve(source: .groundPlusHand, gpsAltitude: nil, groundElevation: nil, handHeight: 1.5))
        XCTAssertEqual(ObserverHeight(meters: 20, method: .ground).text(handHeight: 1.5, source: .groundPlusHand),
                       "自分の高さ 20m(地面の標高+手の高さ1.5m)")
        XCTAssertEqual(ObserverHeight(meters: 40, method: .gps).text(handHeight: 1.5, source: .groundPlusHand),
                       "自分の高さ 40m(GPSの高度。地面の標高が取れないため)")
    }

    func testGroundElevationIsReusedWithin100m() {
        let ground = GroundElevation(latitude: 35.0, longitude: 139.0, elevation: 20, fetchedAt: Date())
        XCTAssertTrue(ElevationStore.isNear(ground, latitude: 35.0005, longitude: 139.0))
        XCTAssertFalse(ElevationStore.isNear(ground, latitude: 35.001, longitude: 139.0))
    }

    // MARK: - 表示の文字

    func testHeightTexts() {
        XCTAssertEqual(WaypointMath.heightText(120.4), "↑120m")
        XCTAssertEqual(WaypointMath.heightText(-35.6), "↓36m")
        XCTAssertEqual(WaypointMath.heightText(0.3), "高さ同じ")
        XCTAssertEqual(WaypointMath.distanceText(2300, heightDifference: 120), "2.3km ↑120m")
        XCTAssertEqual(WaypointMath.distanceText(850, heightDifference: nil), "850m")
        let tower = Waypoint(name: "タワー", latitude: 0, longitude: 0, groundElevation: 18.5, elevationState: .fetched, heightAboveGround: 250)
        XCTAssertEqual(WaypointHeightText.summary(tower), "標高 18.5m + 地面から250m = 269m")
        XCTAssertEqual(WaypointHeightText.difference(waypoint: tower, observerHeight: 20), "↑249m")
        XCTAssertNil(WaypointHeightText.difference(waypoint: tower, observerHeight: nil))
        let sea = Waypoint(name: "海", latitude: 0, longitude: 0, elevationState: .noData)
        XCTAssertTrue(WaypointHeightText.summary(sea).contains("データはありません"))
        XCTAssertEqual(WaypointHeightText.parse("２５０"), 250)
        XCTAssertEqual(WaypointHeightText.parse("−3.5"), -3.5)
        XCTAssertNil(WaypointHeightText.parse(""))
        XCTAssertNil(WaypointHeightText.parse("abc"))
    }

    // MARK: - 国土地理院の標高API

    func testParseElevationResponses() throws {
        // 2026-10-17 に確認した応答の形
        XCTAssertEqual(try GSIElevationAPI.parse(Data(#"{"elevation":18.5,"hsrc":"1m（レーザ）"}"#.utf8)),
                       .value(18.5, source: "1m（レーザ）"))
        XCTAssertEqual(try GSIElevationAPI.parse(Data(#"{"elevation":3770.6,"hsrc":"5m（写真測量）"}"#.utf8)), .value(3770.6, source: "5m（写真測量）"))
        // 海上・国外: 200 で「-----」
        XCTAssertEqual(try GSIElevationAPI.parse(Data(#"{"elevation":"-----","hsrc":"-----"}"#.utf8)), .noData)
        XCTAssertEqual(try GSIElevationAPI.parse(Data(#"{"elevation":"12.3","hsrc":"10m"}"#.utf8)), .value(12.3, source: "10m"))
        XCTAssertThrowsError(try GSIElevationAPI.parse(Data(#"{"error":"x"}"#.utf8)))
        XCTAssertThrowsError(try GSIElevationAPI.parse(Data("<html>".utf8)))

        let url = GSIElevationAPI.url(latitude: 35.658581, longitude: 139.745433)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "lon" }?.value, "139.745433")
        XCTAssertEqual(items.first { $0.name == "lat" }?.value, "35.658581")
        XCTAssertEqual(items.first { $0.name == "outtype" }?.value, "JSON")
        // 受信量は「スコープ」に数える(地図タイルとは分ける)
        XCTAssertEqual(UsageCategory.from(url: url), .scope)
        XCTAssertEqual(UsageCategory.from(url: URL(string: "https://cyberjapandata.gsi.go.jp/xyz/pale/10/909/403.png")), .mapTiles)
    }
}

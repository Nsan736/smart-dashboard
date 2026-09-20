import XCTest
@testable import SmartDashboard

/// スコープ: 名前の変更に伴う保存データの引き継ぎ、周辺の施設の並べ替え、次の曲がり角の切り替え、経路から外れたかの判定
final class ScopeTests: XCTestCase {
    // MARK: - 保存データの引き継ぎ

    func testSavedDataFromWaypointEraIsKept() throws {
        // タブの並び: 以前の値 "waypoint" のまま読めて、表示名だけが「スコープ」になる
        let order = TabOrder.decode(["home", "weather", "waypoint", "train", "exchange", "sensors", "timer", "settings"])
        XCTAssertEqual(order[2], .waypoint)
        XCTAssertEqual(order[2].title, "スコープ")
        XCTAssertEqual(TabOrder.barTabs(order), [.home, .weather, .waypoint, .train])
        XCTAssertEqual(AppTab.waypoint.rawValue, "waypoint")
        // ホームのカード: 以前の値 "waypoint" の表示・非表示と並びを引き継ぐ
        let layout = HomeLayout.decode(Data(#"{"order":["waypoint","weather"],"hidden":["exchange"]}"#.utf8))
        XCTAssertEqual(layout.order.first, .waypoint)
        XCTAssertTrue(layout.shows(.waypoint))
        XCTAssertEqual(HomeCardKind.waypoint.title, "スコープ")
        // 登録した地点: v0.8 の頃に保存した waypoints.json がそのまま読める
        let json = #"[{"id":"2F1C0B7E-4C5A-4D8B-9F65-0A1B2C3D4E5F","name":"駐車場","latitude":35.68,"longitude":139.76,"colorIndex":3,"memo":"B2","isPinned":true}]"#
        let waypoints = try JSONDecoder().decode([Waypoint].self, from: Data(json.utf8))
        XCTAssertEqual(waypoints.first?.name, "駐車場")
        XCTAssertEqual(waypoints.first?.isPinned, true)
        // 地点は、共通の印(カメラ表示・コンパス表示)に変換できる
        let mark = ScopeMark(try XCTUnwrap(waypoints.first))
        XCTAssertEqual(mark.id, "2F1C0B7E-4C5A-4D8B-9F65-0A1B2C3D4E5F")
        XCTAssertEqual(mark.color, WaypointPalette.color(3))
    }

    @MainActor
    func testScopeSettingsDefaultsAndPersistence() {
        let name = "ScopeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: "waypoint.showsHeading")
        let settings = AppSettings(defaults: defaults)
        // 以前の設定(向いている方角の表示)は、そのまま引き継ぐ
        XCTAssertTrue(settings.waypointShowsHeading)
        XCTAssertEqual(settings.nearbyRadius, 500)
        XCTAssertEqual(settings.nearbyCategories, NearbyCategory.allCases)
        settings.nearbyRadius = 2000
        settings.nearbyCategories = [.restroom, .convenience] + NearbyCategory.allCases.filter { $0 != .restroom && $0 != .convenience }
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.nearbyRadius, 2000)
        XCTAssertEqual(restored.nearbyCategories.prefix(2), [.restroom, .convenience])
    }

    // MARK: - 周辺の施設

    private func place(_ name: String, _ distance: Double, latitude: Double = 35.68, longitude: Double = 139.76) -> NearbyPlace {
        NearbyPlace(id: "\(name)-\(distance)", name: name, latitude: latitude, longitude: longitude, category: .convenience,
                    address: nil, phone: nil, url: nil, distance: distance, bearing: 0)
    }

    func testNearbyPlacesAreSortedFilteredAndDeduplicated() {
        let places = [place("C店", 480), place("A店", 120), place("遠い店", 650), place("B店", 300, latitude: 35.681),
                      place("A店", 121), place("A店", 400, latitude: 35.684)]
        let arranged = NearbyPlace.arranged(places, radius: 500)
        // 範囲(500m)の外は除き、近い順。同じ名前でほぼ同じ位置のものは1つにする(離れた同名の店は別の店として残す)
        XCTAssertEqual(arranged.map(\.name), ["A店", "B店", "A店", "C店"])
        XCTAssertEqual(arranged.map(\.distance), [120, 300, 400, 480])
        XCTAssertTrue(NearbyPlace.arranged([], radius: 500).isEmpty)
    }

    func testNearbyCategoryOrderAndRadius() {
        XCTAssertEqual(NearbyCategory.normalizedOrder(nil), NearbyCategory.allCases)
        let order = NearbyCategory.normalizedOrder(["park", "removed", "restroom", "park"])
        XCTAssertEqual(order.prefix(2), [.park, .restroom])
        XCTAssertEqual(Set(order), Set(NearbyCategory.allCases))
        XCTAssertEqual(order.count, NearbyCategory.allCases.count)
        // 探す範囲は初期値500m、最大2km
        XCTAssertEqual(NearbyRadius.initial, 500)
        XCTAssertEqual(NearbyRadius.choices.max(), 2000)
        XCTAssertEqual(NearbyRadius.clamped(1000), 1000)
        XCTAssertEqual(NearbyRadius.clamped(5000), 500)
    }

    func testNearbyCacheIsReusedOnlyWhenCloseAndFresh() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func reuse(age: TimeInterval, latitude: Double, radius: Int) -> Bool {
            NearbyCachePolicy.canReuse(cachedAt: now.addingTimeInterval(-age), cachedLatitude: 35.68, cachedLongitude: 139.76, cachedRadius: 500,
                                       now: now, latitude: latitude, longitude: 139.76, radius: radius)
        }
        XCTAssertTrue(reuse(age: 60, latitude: 35.68, radius: 500))
        // 約55m動いただけなら使い回す。約220m動いたら探し直す
        XCTAssertTrue(reuse(age: 60, latitude: 35.6805, radius: 500))
        XCTAssertFalse(reuse(age: 60, latitude: 35.682, radius: 500))
        // 5分を過ぎたら探し直す。範囲を変えたときも探し直す
        XCTAssertFalse(reuse(age: 301, latitude: 35.68, radius: 500))
        XCTAssertFalse(reuse(age: 60, latitude: 35.68, radius: 1000))
    }

    // MARK: - 経路

    /// 北へ200m進み、右折して東へ200m進む経路。1度の緯度は約111.2km。
    private func plan() -> RoutePlan {
        let lat0 = 35.0
        let lon0 = 139.0
        let north200 = lat0 + 200 / 111_194.9
        let east200 = lon0 + 200 / (111_194.9 * cos(35.0 * Double.pi / 180))
        return RoutePlan(
            destination: ScopeDestination(name: "目的地", latitude: north200, longitude: east200),
            points: [RoutePoint(latitude: lat0, longitude: lon0), RoutePoint(latitude: north200, longitude: lon0), RoutePoint(latitude: north200, longitude: east200)],
            turns: [RouteTurn(id: 0, instructions: "北に進む", latitude: lat0, longitude: lon0, distance: 200),
                    RouteTurn(id: 1, instructions: "右折する", latitude: north200, longitude: lon0, distance: 200),
                    RouteTurn(id: 2, instructions: "目的地は右側です", latitude: north200, longitude: east200, distance: 0)],
            distance: 400, expectedTravelTime: 300, fetchedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private func north(_ meters: Double) -> Double { 35.0 + meters / 111_194.9 }
    private func east(_ meters: Double) -> Double { 139.0 + meters / (111_194.9 * cos(35.0 * Double.pi / 180)) }

    func testNextTurnAdvancesWhenClose() {
        var navigator = RouteNavigator(plan: plan())
        // 出発点の案内は、出発点にいるので飛ばす。最初に向かうのは右折の曲がり角
        XCTAssertEqual(navigator.nextTurn?.id, 1)
        navigator.update(latitude: north(160), longitude: 139.0)
        XCTAssertEqual(navigator.nextTurn?.id, 1)
        XCTAssertEqual(navigator.distanceToNext ?? 0, 40, accuracy: 0.5)
        XCTAssertEqual(navigator.guidanceText, "次：あと40mで 右折する")
        XCTAssertFalse(navigator.isOffRoute)
        // 曲がり角の15m以内に入ったら、次へ切り替える
        navigator.update(latitude: north(190), longitude: 139.0)
        XCTAssertEqual(navigator.nextTurn?.id, 2)
        XCTAssertEqual(navigator.distanceToNext ?? 0, 200, accuracy: 1)
        // 目的地に近づいたら到着
        navigator.update(latitude: north(200), longitude: east(190))
        XCTAssertTrue(navigator.hasArrived)
        XCTAssertNil(navigator.nextTurn)
        XCTAssertEqual(navigator.guidanceText, "目的地(目的地)の近くです")
    }

    func testOffRouteDetection() {
        var navigator = RouteNavigator(plan: plan())
        // 経路の線から30m東: まだ経路の上とみなす
        navigator.update(latitude: north(100), longitude: east(30))
        XCTAssertFalse(navigator.isOffRoute)
        // 60m西: 経路から外れた
        navigator.update(latitude: north(100), longitude: east(-60))
        XCTAssertTrue(navigator.isOffRoute)
        // 戻れば解除される
        navigator.update(latitude: north(100), longitude: east(5))
        XCTAssertFalse(navigator.isOffRoute)
        // 線までの距離: 角の内側(北東)にいるときは、近いほうの辺までの距離
        let distance = RouteGeometry.distanceToPath(from: RoutePoint(latitude: north(180), longitude: east(40)), path: plan().points)
        XCTAssertEqual(distance ?? 0, 20, accuracy: 0.5)
        XCTAssertNil(RouteGeometry.distanceToPath(from: RoutePoint(latitude: 35, longitude: 139), path: []))
    }

    func testRouteTextsAndRefetchInterval() {
        XCTAssertEqual(RouteText.duration(300), "約5分")
        XCTAssertEqual(RouteText.duration(20), "約1分")
        XCTAssertEqual(RouteText.duration(3900), "約1時間5分")
        XCTAssertEqual(RouteText.duration(7200), "約2時間")
        XCTAssertEqual(plan().summaryText, "約5分・400m")
        // 経路の取り直しは、最短の間隔(20秒)を空ける
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(RouteStore.canRefetch(lastFetchedAt: nil, now: now))
        XCTAssertFalse(RouteStore.canRefetch(lastFetchedAt: now.addingTimeInterval(-10), now: now))
        XCTAssertTrue(RouteStore.canRefetch(lastFetchedAt: now.addingTimeInterval(-20), now: now))
    }

    func testRouteMarksOrderFarToNear() {
        let marks = [ScopeMark(id: "destination", name: "目的地", latitude: north(200), longitude: east(200), color: .red),
                     ScopeMark(id: "turn", name: "次の曲がり角", latitude: north(200), longitude: 139.0, color: .yellow)]
        let targets = ScopeTarget.make(marks, latitude: north(160), longitude: 139.0)
        // 遠いもの(目的地)から描き、近い曲がり角が手前になる
        XCTAssertEqual(targets.map(\.id), ["destination", "turn"])
        XCTAssertEqual(targets[1].distance, 40, accuracy: 0.5)
        XCTAssertEqual(targets[1].bearing, 0, accuracy: 0.5)
    }
}

import XCTest
@testable import SmartDashboard

/// タブの並び順(保存と、「その他」に入るものの判定)と、カメラの起動時間の表示
final class TabOrderTests: XCTestCase {
    func testInitialOrderPutsWaypointInTheBar() {
        // 初期の並びは「ホーム/天気/ウェイポイント/電車/その他」。為替は「その他」の中
        XCTAssertEqual(TabOrder.barTabs(TabOrder.initial), [.home, .weather, .waypoint, .train])
        XCTAssertEqual(TabOrder.moreTabs(TabOrder.initial), [.exchange, .sensors, .tools, .settings])
        XCTAssertTrue(TabOrder.isInMore(.exchange, order: TabOrder.initial))
        XCTAssertFalse(TabOrder.isInMore(.waypoint, order: TabOrder.initial))
        // 保存がなければ(これまでの利用者のアップデート直後も)初期の並び
        XCTAssertEqual(TabOrder.decode(nil), TabOrder.initial)
    }

    func testDecodeDropsUnknownAndAppendsMissing() {
        let order = TabOrder.decode(["sensors", "removedTab", "home", "sensors"])
        XCTAssertEqual(order.prefix(2), [.sensors, .home])
        XCTAssertEqual(order.count, AppTab.allCases.count)
        XCTAssertEqual(Set(order), Set(AppTab.allCases))
        // 足りないタブは、初期の並びの順で末尾に足す
        XCTAssertEqual(Array(order.dropFirst(2)), [.weather, .waypoint, .train, .exchange, .tools, .settings])
        XCTAssertEqual(TabOrder.barTabs(order), [.sensors, .home, .weather, .waypoint])
        XCTAssertTrue(TabOrder.isInMore(.train, order: order))
        XCTAssertEqual(TabOrder.decode([]), TabOrder.initial)
    }

    @MainActor
    func testOrderIsSavedAndRestored() {
        let name = "TabOrderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.tabOrder, TabOrder.initial)
        var order = settings.tabOrder
        order.swapAt(2, 4)
        settings.tabOrder = order
        let restored = AppSettings(defaults: defaults).tabOrder
        XCTAssertEqual(restored, order)
        XCTAssertEqual(TabOrder.barTabs(restored), [.home, .weather, .exchange, .train])
        XCTAssertTrue(TabOrder.isInMore(.waypoint, order: restored))
    }

    func testCameraTimingText() {
        let first = CameraStartTiming(authorization: 0.004, configuration: 0.212, startRunning: 0.655, reusedConfiguration: false)
        XCTAssertEqual(first.total, 0.871, accuracy: 0.0001)
        XCTAssertEqual(first.text, "合計 871ms(許可の確認 4ms、設定 212ms、映像の開始 655ms)")
        let second = CameraStartTiming(authorization: 0.001, configuration: 0, startRunning: 0.4, reusedConfiguration: true)
        XCTAssertEqual(second.text, "合計 401ms(許可の確認 1ms、設定 使い回し、映像の開始 400ms)")
    }
}

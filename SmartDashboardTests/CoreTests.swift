import XCTest
@testable import SmartDashboard

final class RefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let wifi = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: false, isWiFi: true)
    private let cellular = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: false, isWiFi: false)
    private let lowData = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: true, isWiFi: true)
    private let wired = NetworkStatus(isOnline: true, isExpensive: false, isConstrained: false, isWiFi: false)
    private let offline = NetworkStatus(isOnline: false, isExpensive: false, isConstrained: false, isWiFi: false)

    func testFreshCacheIsNotRefreshed() {
        let policy = RefreshPolicy(wifiOnly: false)
        let fetched = now.addingTimeInterval(-29 * 60)
        XCTAssertEqual(policy.autoDecision(kind: .weather, fetchedAt: fetched, now: now, network: wifi), .fresh)
    }

    func testStaleCacheIsRefreshedOnWiFi() {
        let policy = RefreshPolicy(wifiOnly: false)
        let fetched = now.addingTimeInterval(-31 * 60)
        XCTAssertEqual(policy.autoDecision(kind: .weather, fetchedAt: fetched, now: now, network: wifi), .refresh)
        XCTAssertEqual(policy.autoDecision(kind: .weather, fetchedAt: nil, now: now, network: wifi), .refresh)
    }

    func testExchangeIsDaily() {
        let policy = RefreshPolicy(wifiOnly: false)
        XCTAssertEqual(policy.autoDecision(kind: .exchange, fetchedAt: now.addingTimeInterval(-23 * 3600), now: now, network: wifi), .fresh)
        XCTAssertEqual(policy.autoDecision(kind: .exchange, fetchedAt: now.addingTimeInterval(-25 * 3600), now: now, network: wifi), .refresh)
    }

    func testBlockedOnExpensiveOrConstrained() {
        let policy = RefreshPolicy(wifiOnly: false)
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: cellular), .blockedByExpensive)
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: lowData), .blockedByConstrained)
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: offline), .offline)
    }

    func testWiFiOnly() {
        XCTAssertEqual(RefreshPolicy(wifiOnly: true).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: wired), .blockedByWiFiOnly)
        XCTAssertEqual(RefreshPolicy(wifiOnly: false).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: wired), .refresh)
    }

    func testFutureTimestampIsTreatedAsStale() {
        let policy = RefreshPolicy(wifiOnly: false)
        XCTAssertEqual(policy.autoDecision(kind: .weather, fetchedAt: now.addingTimeInterval(3600), now: now, network: wifi), .refresh)
    }

    func testManualRefresh() {
        let policy = RefreshPolicy(wifiOnly: true)
        XCTAssertEqual(policy.manualDecision(network: cellular), .refresh)
        XCTAssertEqual(policy.manualDecision(network: offline), .offline)
    }
}

final class DiskCacheTests: XCTestCase {
    private struct Sample: Codable, Equatable {
        let name: String
        let value: Double
    }

    func testSaveLoadRemove() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = DiskCache(directory: dir)
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let empty = await cache.load(Sample.self, key: "a/b:c")
        XCTAssertNil(empty)

        try await cache.save(Sample(name: "x", value: 1.5), key: "a/b:c", fetchedAt: fetchedAt)
        let loaded = await cache.load(Sample.self, key: "a/b:c")
        XCTAssertEqual(loaded, CachedValue(value: Sample(name: "x", value: 1.5), fetchedAt: fetchedAt))
        let size = await cache.totalSize()
        XCTAssertGreaterThan(size, 0)

        await cache.removeAll()
        let removed = await cache.load(Sample.self, key: "a/b:c")
        XCTAssertNil(removed)
    }
}

@MainActor
final class DataUsageStoreTests: XCTestCase {
    func testTodayAndMonthTotals() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var components = DateComponents(year: 2026, month: 9, day: 19, hour: 12)
        var current = Calendar.current.date(from: components)!
        let store = DataUsageStore(fileURL: url, now: { current })

        store.add(1000)
        store.add(500)
        XCTAssertEqual(store.today, 1500)

        components.day = 20
        current = Calendar.current.date(from: components)!
        store.add(200)
        XCTAssertEqual(store.today, 200)
        XCTAssertEqual(store.thisMonth, 1700)

        components.month = 10
        components.day = 1
        current = Calendar.current.date(from: components)!
        XCTAssertEqual(store.today, 0)
        XCTAssertEqual(store.thisMonth, 0)
    }
}

final class FormattersTests: XCTestCase {
    func testAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Formatters.age(of: now.addingTimeInterval(-30), now: now), "たった今")
        XCTAssertEqual(Formatters.age(of: now.addingTimeInterval(-12 * 60), now: now), "12分前")
        XCTAssertEqual(Formatters.age(of: now.addingTimeInterval(-3 * 3600), now: now), "3時間前")
        XCTAssertEqual(Formatters.age(of: now.addingTimeInterval(-2 * 86400), now: now), "2日前")
        XCTAssertEqual(Formatters.ageLabel(nil), "未取得")
    }
}

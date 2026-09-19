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

    func testMobileRefreshesButLowDataModeDoesNot() {
        let policy = RefreshPolicy(wifiOnly: false)
        // モバイル通信でも、最短の更新間隔を過ぎていれば自動更新する
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: cellular), .refresh)
        XCTAssertEqual(policy.autoDecision(kind: .rainNowcast, fetchedAt: now.addingTimeInterval(-11 * 60), now: now, network: cellular), .refresh)
        XCTAssertEqual(policy.autoDecision(kind: .rainNowcast, fetchedAt: now.addingTimeInterval(-9 * 60), now: now, network: cellular), .fresh)
        // 省データモードでは止める(モバイル通信でもWi-Fiでも)
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: lowData), .blockedByConstrained)
        let cellularLowData = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: true, isWiFi: false)
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: cellularLowData), .blockedByConstrained)
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: offline), .offline)
        // 回線の状態が分かるまでは自動更新しない
        XCTAssertEqual(policy.autoDecision(kind: .trainInfo, fetchedAt: nil, now: now, network: .unknown), .blockedByConstrained)
    }

    func testWiFiOnly() {
        XCTAssertEqual(RefreshPolicy(wifiOnly: true).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: wired), .blockedByWiFiOnly)
        XCTAssertEqual(RefreshPolicy(wifiOnly: true).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: cellular), .blockedByWiFiOnly)
        XCTAssertEqual(RefreshPolicy(wifiOnly: true).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: wifi), .refresh)
        // テザリング(Wi-Fiだが従量制)はモバイル通信として扱う
        let hotspot = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: false, isWiFi: true)
        XCTAssertEqual(RefreshPolicy(wifiOnly: true).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: hotspot), .blockedByWiFiOnly)
        XCTAssertEqual(RefreshPolicy(wifiOnly: false).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: wired), .refresh)
    }

    func testFutureTimestampIsTreatedAsStale() {
        let policy = RefreshPolicy(wifiOnly: false)
        XCTAssertEqual(policy.autoDecision(kind: .weather, fetchedAt: now.addingTimeInterval(3600), now: now, network: wifi), .refresh)
    }

    func testCellularLimit() {
        let limited = RefreshPolicy(wifiOnly: false, cellularLimitReached: true)
        XCTAssertEqual(limited.autoDecision(kind: .weather, fetchedAt: nil, now: now, network: cellular), .blockedByCellularLimit)
        XCTAssertEqual(RefreshPolicy(wifiOnly: false, cellularLimitReached: false).autoDecision(kind: .weather, fetchedAt: nil, now: now, network: cellular), .refresh)
        // Wi-Fiでは上限を超えていても自動更新する
        XCTAssertEqual(limited.autoDecision(kind: .weather, fetchedAt: nil, now: now, network: wifi), .refresh)
        XCTAssertEqual(limited.manualDecision(network: cellular), .refresh)
        XCTAssertNotNil(RefreshDecision.blockedByCellularLimit.note)
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

        var changes = 0
        store.onChange = { changes += 1 }
        store.add(UsageRecord(bytes: 1000, link: .wifi, category: .weather))
        store.add(UsageRecord(bytes: 500, link: .cellular, category: .weather))
        store.add(UsageRecord(bytes: 0, link: .cellular, category: .train))
        XCTAssertEqual(store.today(), 1500)
        XCTAssertEqual(store.today(.wifi), 1000)
        XCTAssertEqual(store.today(.cellular), 500)
        XCTAssertEqual(changes, 2)

        components.day = 20
        current = Calendar.current.date(from: components)!
        store.add(UsageRecord(bytes: 200, link: .cellular, category: .radar))
        store.addGeocodeRequest()
        XCTAssertEqual(store.today(), 200)
        XCTAssertEqual(store.thisMonth(), 1700)
        XCTAssertEqual(store.thisMonth(.cellular), 700)
        XCTAssertEqual(store.thisMonth(.cellular, .radar), 200)
        XCTAssertEqual(store.thisMonth(.wifi, .weather), 1000)
        XCTAssertEqual(store.thisMonth(.wifi, .radar), 0)
        XCTAssertEqual(store.geocodeRequestsThisMonth, 1)

        components.month = 10
        components.day = 1
        current = Calendar.current.date(from: components)!
        XCTAssertEqual(store.today(), 0)
        XCTAssertEqual(store.thisMonth(), 0)
    }

    func testLegacyRecordsAreKeptAsUnknownLink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("data-usage.json")
        try Data("{\"2026-09-18\":1200,\"2026-09-19\":300}".utf8).write(to: legacy)
        let current = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 12))!
        let store = DataUsageStore(fileURL: dir.appendingPathComponent("data-usage-v2.json"), legacyFileURL: legacy, now: { current })
        XCTAssertEqual(store.today(.unknown), 300)
        XCTAssertEqual(store.thisMonth(.unknown), 1500)
        XCTAssertEqual(store.thisMonth(.unknown, .legacy), 1500)
        XCTAssertEqual(store.thisMonth(.wifi), 0)

        store.add(UsageRecord(bytes: 50, link: .wifi, category: .exchange))
        XCTAssertEqual(store.today(), 350)
        XCTAssertEqual(store.today(.wifi), 50)
    }

    func testCategoryAndLinkDetection() {
        XCTAssertEqual(UsageCategory.from(host: "api.open-meteo.com"), .weather)
        XCTAssertEqual(UsageCategory.from(host: "open.er-api.com"), .exchange)
        XCTAssertEqual(UsageCategory.from(host: "api-public.odpt.org"), .train)
        XCTAssertEqual(UsageCategory.from(host: "api.odpt.org"), .train)
        XCTAssertEqual(UsageCategory.from(host: "www.jma.go.jp"), .radar)
        XCTAssertEqual(UsageCategory.from(host: "cyberjapandata.gsi.go.jp"), .mapTiles)
        XCTAssertEqual(UsageCategory.from(host: nil), .other)
        XCTAssertEqual(MeteredHTTPClient.link(isCellular: false, isExpensive: false), .wifi)
        XCTAssertEqual(MeteredHTTPClient.link(isCellular: true, isExpensive: true), .cellular)
        XCTAssertEqual(MeteredHTTPClient.link(isCellular: false, isExpensive: true), .cellular)
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

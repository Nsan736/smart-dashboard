import Foundation
import Observation

/// アプリ全体で共有する依存をまとめる
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let network: NetworkMonitor
    let usage: DataUsageStore
    @ObservationIgnored let cache: DiskCache
    @ObservationIgnored let http: HTTPClient
    @ObservationIgnored let keychain: KeychainStore

    /// 各データの最終更新時刻(設定画面に表示する)
    private(set) var lastFetched: [DataKind: Date] = [:]
    private(set) var cacheSize: Int64 = 0

    init() {
        let support = DiskCache.defaultDirectory("SmartDashboard")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let usage = DataUsageStore(fileURL: support.appendingPathComponent("data-usage.json"))
        self.usage = usage
        settings = AppSettings()
        network = NetworkMonitor()
        cache = DiskCache(directory: support.appendingPathComponent("cache", isDirectory: true))
        keychain = KeychainStore()
        http = MeteredHTTPClient { [weak usage] bytes in
            Task { @MainActor in usage?.add(bytes) }
        }
        for kind in DataKind.allCases {
            let t = UserDefaults.standard.double(forKey: Self.lastFetchedKey(kind))
            if t > 0 { lastFetched[kind] = Date(timeIntervalSince1970: t) }
        }
    }

    func markFetched(_ kind: DataKind, at date: Date = Date()) {
        lastFetched[kind] = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastFetchedKey(kind))
    }

    /// 起動時とフォアグラウンド復帰時に呼ぶ。古くなったデータだけを各Storeが取得する。
    func refreshStaleData() async {
        await updateCacheSize()
    }

    func clearCache() async {
        await cache.removeAll()
        for kind in DataKind.allCases {
            UserDefaults.standard.removeObject(forKey: Self.lastFetchedKey(kind))
        }
        lastFetched = [:]
        await updateCacheSize()
    }

    func updateCacheSize() async {
        cacheSize = await cache.totalSize()
    }

    private static func lastFetchedKey(_ kind: DataKind) -> String { "lastFetched.\(kind.rawValue)" }
}

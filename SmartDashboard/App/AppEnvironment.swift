import Foundation
import Observation

/// 各データの最終更新時刻(設定画面に表示する)
@MainActor
@Observable
final class FetchLog {
    private(set) var lastFetched: [DataKind: Date] = [:]

    init() {
        for kind in DataKind.allCases {
            let t = UserDefaults.standard.double(forKey: Self.key(kind))
            if t > 0 { lastFetched[kind] = Date(timeIntervalSince1970: t) }
        }
    }

    func mark(_ kind: DataKind, at date: Date = Date()) {
        lastFetched[kind] = date
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.key(kind))
    }

    func reset() {
        for kind in DataKind.allCases { UserDefaults.standard.removeObject(forKey: Self.key(kind)) }
        lastFetched = [:]
    }

    private static func key(_ kind: DataKind) -> String { "lastFetched.\(kind.rawValue)" }
}

/// アプリ全体で共有する依存をまとめる
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let network: NetworkMonitor
    let usage: DataUsageStore
    let fetchLog: FetchLog
    let weather: WeatherStore
    let exchange: ExchangeStore
    let timers: TimerStore
    @ObservationIgnored let cache: DiskCache
    @ObservationIgnored let http: HTTPClient
    @ObservationIgnored let keychain: KeychainStore

    private(set) var cacheSize: Int64 = 0

    init() {
        let support = DiskCache.defaultDirectory("SmartDashboard")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let usage = DataUsageStore(fileURL: support.appendingPathComponent("data-usage.json"))
        let settings = AppSettings()
        let network = NetworkMonitor()
        let fetchLog = FetchLog()
        let cache = DiskCache(directory: support.appendingPathComponent("cache", isDirectory: true))
        let http = MeteredHTTPClient { [weak usage] bytes in
            Task { @MainActor in usage?.add(bytes) }
        }
        self.usage = usage
        self.settings = settings
        self.network = network
        self.fetchLog = fetchLog
        self.cache = cache
        self.http = http
        keychain = KeychainStore()
        timers = TimerStore()
        weather = WeatherStore(
            api: OpenMeteoClient(http: http), cache: cache, settings: settings, network: network,
            location: LocationProvider(), onFetched: { fetchLog.mark(.weather, at: $0) })
        exchange = ExchangeStore(
            api: ERAPIClient(http: http), cache: cache, settings: settings, network: network,
            onFetched: { fetchLog.mark(.exchange, at: $0) })
    }

    /// 起動時とフォアグラウンド復帰時に呼ぶ。古くなったデータだけを各Storeが取得する。
    func refreshStaleData() async {
        timers.resume()
        await weather.refreshIfStale()
        await exchange.refreshIfStale()
        await updateCacheSize()
    }

    func clearCache() async {
        await cache.removeAll()
        fetchLog.reset()
        weather.clearMemory()
        exchange.clearMemory()
        await updateCacheSize()
    }

    func updateCacheSize() async {
        cacheSize = await cache.totalSize()
    }
}

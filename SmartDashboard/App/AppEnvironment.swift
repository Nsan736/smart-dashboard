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
    let trains: TrainStore
    let tiles: TileDownloader
    let radar: RadarStore
    @ObservationIgnored let cache: DiskCache
    @ObservationIgnored let http: HTTPClient
    @ObservationIgnored let keychain: KeychainStore
    @ObservationIgnored let location: LocationProvider

    private(set) var cacheSize: Int64 = 0
    private(set) var hasODPTToken = false

    init() {
        let support = DiskCache.defaultDirectory("SmartDashboard")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let usage = DataUsageStore(fileURL: support.appendingPathComponent("data-usage-v2.json"),
                                   legacyFileURL: support.appendingPathComponent("data-usage.json"))
        let settings = AppSettings()
        let network = NetworkMonitor()
        let fetchLog = FetchLog()
        let cache = DiskCache(directory: support.appendingPathComponent("cache", isDirectory: true))
        let http = MeteredHTTPClient { [weak usage] record in
            Task { @MainActor in usage?.add(record) }
        }
        settings.monthlyCellularBytes = usage.thisMonth(.cellular)
        usage.onChange = { [weak usage] in
            guard let usage else { return }
            let bytes = usage.thisMonth(.cellular)
            if settings.monthlyCellularBytes != bytes { settings.monthlyCellularBytes = bytes }
        }
        self.usage = usage
        self.settings = settings
        self.network = network
        self.fetchLog = fetchLog
        self.cache = cache
        self.http = http
        let keychain = KeychainStore()
        self.keychain = keychain
        trains = TrainStore(
            api: ODPTClient(http: http, tokenProvider: { keychain.string(for: KeychainAccount.odptToken) }),
            cache: cache,
            timetableStorage: DiskCache(directory: support.appendingPathComponent("timetables", isDirectory: true)),
            settings: settings, network: network,
            hasToken: { !(keychain.string(for: KeychainAccount.odptToken) ?? "").isEmpty },
            onFetched: { fetchLog.mark($0, at: $1) })
        timers = TimerStore()
        let location = LocationProvider()
        self.location = location
        let tiles = TileDownloader(store: TileStore(root: TileStore.defaultRoot()), http: http, settings: settings, network: network)
        self.tiles = tiles
        let radarLoader = RadarTileLoader(http: http, root: RadarTileLoader.defaultRoot())
        radar = RadarStore(http: http, network: network, loader: radarLoader)
        weather = WeatherStore(
            api: OpenMeteoClient(http: http), cache: cache, settings: settings, network: network,
            location: location, placeNames: PlaceNameResolver(onRequest: { [weak usage] in usage?.addGeocodeRequest() }),
            onCurrentLocation: { latitude, longitude in
                // 地図を保存する最初の登録エリア(現在地から半径20km)を一度だけ作る
                guard !settings.didCreateDefaultTileArea, settings.tileAreas.isEmpty else { return }
                settings.didCreateDefaultTileArea = true
                settings.tileAreas = [TileArea(name: "現在地周辺", latitude: latitude, longitude: longitude, radiusKm: 20)]
                tiles.evaluate(isForeground: true)
            },
            onFetched: { fetchLog.mark(.weather, at: $0) })
        exchange = ExchangeStore(
            api: ERAPIClient(http: http), cache: cache, settings: settings, network: network,
            onFetched: { fetchLog.mark(.exchange, at: $0) })
        hasODPTToken = !(keychain.string(for: KeychainAccount.odptToken) ?? "").isEmpty
    }

    /// 起動時とフォアグラウンド復帰時に呼ぶ。古くなったデータだけを各Storeが取得する。
    func refreshStaleData() async {
        timers.resume()
        tiles.evaluate(isForeground: true)
        await weather.refreshIfStale()
        await exchange.refreshIfStale()
        await trains.refreshInfoIfStale()
        await updateCacheSize()
    }

    func clearCache() async {
        await cache.removeAll()
        fetchLog.reset()
        weather.clearMemory()
        exchange.clearMemory()
        trains.clearCachedInfo()
        let radarLoader = radar.loader
        await Task.detached(priority: .utility) { radarLoader.removeAll() }.value
        await updateCacheSize()
    }

    /// トークンはKeychainだけに保存する。空文字なら削除する。
    @discardableResult
    func setODPTToken(_ token: String) -> Bool {
        let ok = keychain.set(token, for: KeychainAccount.odptToken)
        hasODPTToken = !(keychain.string(for: KeychainAccount.odptToken) ?? "").isEmpty
        return ok
    }

    func updateCacheSize() async {
        cacheSize = await cache.totalSize()
    }
}

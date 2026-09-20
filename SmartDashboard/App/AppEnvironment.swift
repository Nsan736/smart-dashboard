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
    let rain: RainNowcastStore
    let live: TrainLiveStore
    /// 電車タブの表示の状態。地図と路線図で共有する。
    let trainDisplay: TrainDisplayState
    let warnings: WarningStore
    let quakes: QuakeStore
    let pressure: PressureRecorder
    let pressureHistory: PressureHistoryStore
    let waypoints: WaypointStore
    /// 背面カメラ。セッションの設定を使い回すため、アプリ全体で1つ。
    let camera = CameraController()
    let keeper: BackgroundKeeper
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
        let trainStore = TrainStore(
            api: ODPTClient(http: http, tokenProvider: { keychain.string(for: KeychainAccount.odptToken) }),
            cache: cache,
            timetableStorage: DiskCache(directory: support.appendingPathComponent("timetables", isDirectory: true)),
            shapeStorage: DiskCache(directory: support.appendingPathComponent("railway-shapes", isDirectory: true)),
            settings: settings, network: network,
            hasToken: { !(keychain.string(for: KeychainAccount.odptToken) ?? "").isEmpty },
            onFetched: { fetchLog.mark($0, at: $1) })
        trains = trainStore
        timers = TimerStore()
        trainDisplay = TrainDisplayState()
        let location = LocationProvider()
        self.location = location
        live = TrainLiveStore(
            api: ODPTClient(http: http, tokenProvider: { keychain.string(for: KeychainAccount.odptToken) }),
            storage: DiskCache(directory: support.appendingPathComponent("train-schedules", isDirectory: true)),
            settings: settings, network: network, trains: trainStore, location: location,
            onFetched: { fetchLog.mark(.trainDelay, at: $0) })
        let tiles = TileDownloader(store: TileStore(root: TileStore.defaultRoot()), http: http, settings: settings, network: network)
        self.tiles = tiles
        let radarLoader = RadarTileLoader(http: http, root: RadarTileLoader.defaultRoot())
        radar = RadarStore(http: http, network: network, loader: radarLoader)
        rain = RainNowcastStore(http: http, cache: cache, settings: settings, network: network, loader: radarLoader,
                                onFetched: { fetchLog.mark(.rainNowcast, at: $0) })
        let placeNames = PlaceNameResolver(onRequest: { [weak usage] in usage?.addGeocodeRequest() })
        warnings = WarningStore(http: http, cache: cache, settings: settings, network: network, placeNames: placeNames,
                                onFetched: { fetchLog.mark(.warning, at: $0) })
        quakes = QuakeStore(http: http, cache: cache, settings: settings, network: network,
                            onFetched: { fetchLog.mark(.quake, at: $0) })
        let recorder = PressureRecorder(directory: support.appendingPathComponent("pressure", isDirectory: true),
                                        legacyFileURL: support.appendingPathComponent("pressure-log.json"))
        pressure = recorder
        let pressureHistory = PressureHistoryStore(http: http, fileURL: support.appendingPathComponent("pressure-history.json"),
                                                   settings: settings, network: network,
                                                   onFetched: { fetchLog.mark(.pressureHistory, at: $0) })
        self.pressureHistory = pressureHistory
        waypoints = WaypointStore(fileURL: support.appendingPathComponent("waypoints.json"))
        let keeper = BackgroundKeeper(settings: settings)
        self.keeper = keeper
        keeper.onStateChange = { [weak recorder] state in
            // バックグラウンドで止まったら、気圧計も止める
            if state != .running, recorder?.isInBackground == true { recorder?.stop() }
        }
        weather = WeatherStore(
            api: OpenMeteoClient(http: http), cache: cache, settings: settings, network: network,
            location: location, placeNames: placeNames,
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
        // 天気を取得するたびに、気圧の1時間値(過去24時間〜今後24時間)を追記する。通信は増えない。
        weather.onSnapshot = { [weak pressureHistory] snapshot in
            pressureHistory?.ingest(snapshot)
        }
    }

    /// 起動時とフォアグラウンド復帰時に呼ぶ。古くなったデータだけを各Storeが取得する。
    func refreshStaleData() async {
        timers.resume()
        tiles.evaluate(isForeground: true)
        // ホームで非表示にしたカードのデータは取得しない(各タブを開いたときは、そのタブが取得する)
        let layout = settings.homeLayout
        if layout.needsWeather { await weather.refreshIfStale() } else { await weather.loadCacheIfNeeded() }
        if layout.needsRain { await refreshRainIfStale() }
        if layout.needsWarnings { await refreshWarningsIfStale() }
        if layout.needsQuakes { await quakes.refreshIfStale() } else { await quakes.loadCacheIfNeeded() }
        if layout.needsExchange { await exchange.refreshIfStale() }
        if layout.needsTrainInfo { await trains.refreshInfoIfStale() }
        await updateCacheSize()
    }

    /// 天気を取得した地点について、直近1時間の雨(ナウキャスト)を更新する。最短10分間隔。
    func refreshRainIfStale() async {
        guard let snapshot = weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
        await rain.refreshIfStale(latitude: latitude, longitude: longitude)
    }

    /// 天気を取得した地点の市区町村について、警報・注意報を更新する。最短10分間隔。
    func refreshWarningsIfStale() async {
        await warnings.loadCacheIfNeeded()
        guard let snapshot = weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
        await warnings.refreshIfStale(latitude: latitude, longitude: longitude)
    }

    func refreshWarningsManually() async {
        guard let snapshot = weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
        await warnings.refreshManually(latitude: latitude, longitude: longitude)
    }

    /// 現在地(天気を取得した地点)の都道府県名。地震の「この都道府県の震度」に使う。地名のキャッシュから読むだけで通信しない。
    var currentPrefecture: String? { warnings.cached?.value.area.prefecture }

    /// 気圧のグラフ用の予報(Open-Meteo の1時間値)
    var pressureForecast: [PressureForecastPoint] {
        let saved = pressureHistory.forecastPoints
        if !saved.isEmpty { return saved }
        return (weather.cached?.value.hourly ?? []).compactMap { hour in
            hour.pressure.map { PressureForecastPoint(time: hour.time, hPa: $0) }
        }
    }

    /// フォアグラウンドに入ったとき。気圧の記録を始め、バックグラウンドの記録が続いていたかを判定する。
    func didBecomeActive() {
        pressure.isInBackground = false
        keeper.didBecomeActive(samples: pressure.samples)
        pressure.start()
        keeper.evaluate()
    }

    /// フォアグラウンドを離れたとき。バックグラウンドで記録する設定でなければ、気圧計を止める。
    func didEnterBackground() {
        pressure.isInBackground = true
        keeper.evaluate()
        keeper.didEnterBackground()
        if !keeper.isRunning { pressure.stop() }
    }

    func refreshRainManually() async {
        guard let snapshot = weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
        await rain.refreshManually(latitude: latitude, longitude: longitude)
    }

    /// 雨の要約。0〜60分はナウキャスト、その先と、ナウキャストが使えないときは予報モデル。
    func rainOutlook(now: Date = Date()) -> RainOutlook? {
        guard let snapshot = weather.cached?.value else { return nil }
        var nowcast: RainNowcast?
        if let value = rain.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude,
           RainNowcastStore.covers(value, latitude: latitude, longitude: longitude) {
            nowcast = value
        }
        return RainOutlook.make(nowcast: nowcast, modelSlots: snapshot.upcomingRain(now: now), now: now)
    }

    func clearCache() async {
        await cache.removeAll()
        fetchLog.reset()
        weather.clearMemory()
        exchange.clearMemory()
        rain.clearMemory()
        warnings.clearMemory()
        quakes.clearMemory()
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

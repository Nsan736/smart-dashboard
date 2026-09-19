import CoreLocation
import Foundation
import Observation

enum RainNowcastConfig {
    /// 判定に使うズーム。ナウキャストのタイルで最も細かい。
    static let zoom = 10
    /// これ以上離れたら、キャッシュが新しくても取得し直す
    static let reuseDistance: CLLocationDistance = 500
}

/// 現在地の直近1時間の雨を、気象庁の高解像度降水ナウキャストのタイルから判定する。
/// タイルのキャッシュはレーダー画面と共有する(同じ basetime なら再取得しない)。
@MainActor
@Observable
final class RainNowcastStore {
    private(set) var cached: CachedValue<RainNowcast>?
    private(set) var isLoading = false
    /// 取得できなかったとき(表示用)。他の機能には影響させない。
    private(set) var lastFetchFailed = false

    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let loader: RadarTileLoader
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let cacheKey = "rainNowcast"

    init(http: HTTPClient, cache: DiskCache, settings: AppSettings, network: NetworkMonitor,
         loader: RadarTileLoader, onFetched: @escaping @MainActor (Date) -> Void) {
        self.http = http
        self.cache = cache
        self.settings = settings
        self.network = network
        self.loader = loader
        self.onFetched = onFetched
    }

    func loadCacheIfNeeded() async {
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                self.cached = await self.cache.load(RainNowcast.self, key: Self.cacheKey)
            }
        }
        await loadTask?.value
    }

    func clearMemory() {
        cached = nil
        loadTask = nil
    }

    /// その地点のキャッシュとして使えるか
    nonisolated static func covers(_ nowcast: RainNowcast, latitude: Double, longitude: Double) -> Bool {
        CLLocation(latitude: nowcast.latitude, longitude: nowcast.longitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude)) < RainNowcastConfig.reuseDistance
    }

    /// 自動更新。最短10分間隔で、従量制の回線などでは行わない。
    func refreshIfStale(latitude: Double, longitude: Double) async {
        await loadCacheIfNeeded()
        let usable = cached.map { Self.covers($0.value, latitude: latitude, longitude: longitude) } ?? false
        let decision = settings.refreshPolicy.autoDecision(
            kind: .rainNowcast, fetchedAt: usable ? cached?.fetchedAt : nil, now: Date(), network: network.status)
        if decision == .refresh { await fetch(latitude: latitude, longitude: longitude) }
    }

    func refreshManually(latitude: Double, longitude: Double) async {
        await loadCacheIfNeeded()
        guard network.status.isOnline else { return }
        await fetch(latitude: latitude, longitude: longitude)
    }

    private func fetch(latitude: Double, longitude: Double) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let observedList = try JSONDecoder().decode([RadarTargetTime].self, from: try await http.get(RadarTimeline.observedURL))
            guard let observed = RadarTimeline.latestObserved(observedList) else {
                lastFetchFailed = true
                return
            }
            var frames = [observed]
            if let data = try? await http.get(RadarTimeline.forecastURL),
               let list = try? JSONDecoder().decode([RadarTargetTime].self, from: data) {
                frames += RadarTimeline.forecasts(list, after: observed)
            }
            let position = TileMath.pixel(latitude: latitude, longitude: longitude, z: RainNowcastConfig.zoom)
            var points: [RainNowcast.Point] = []
            for frame in frames {
                guard let date = frame.date,
                      let data = try? await loader.data(frame: frame, tile: position.tile),
                      let level = RainPixelReader.level(in: data, x: position.x, y: position.y) else {
                    // 実況が読めなければ全体を失敗にする。予測の一部だけなら飛ばす。
                    if !frame.isForecast {
                        lastFetchFailed = true
                        return
                    }
                    continue
                }
                points.append(RainNowcast.Point(time: date, isForecast: frame.isForecast, level: level))
            }
            let nowcast = RainNowcast(latitude: latitude, longitude: longitude, points: points)
            let now = Date()
            cached = CachedValue(value: nowcast, fetchedAt: now)
            lastFetchFailed = false
            try? await cache.save(nowcast, key: Self.cacheKey, fetchedAt: now)
            onFetched(now)
        } catch {
            lastFetchFailed = true
        }
    }
}

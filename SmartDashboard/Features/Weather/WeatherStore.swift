import Foundation
import Observation

@MainActor
@Observable
final class WeatherStore {
    private(set) var cached: CachedValue<WeatherSnapshot>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 自動更新を見送った理由(表示用)
    private(set) var autoRefreshNote: String?

    @ObservationIgnored private let api: WeatherAPI
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let placeNames: PlaceNameResolver
    @ObservationIgnored private let onCurrentLocation: @MainActor (Double, Double) -> Void
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let cacheKey = "weather"

    init(api: WeatherAPI, cache: DiskCache, settings: AppSettings, network: NetworkMonitor,
         location: LocationProvider, placeNames: PlaceNameResolver,
         onCurrentLocation: @escaping @MainActor (Double, Double) -> Void,
         onFetched: @escaping @MainActor (Date) -> Void) {
        self.api = api
        self.cache = cache
        self.settings = settings
        self.network = network
        self.location = location
        self.placeNames = placeNames
        self.onCurrentLocation = onCurrentLocation
        self.onFetched = onFetched
    }

    private var currentSourceID: String {
        if settings.weatherUsesCurrentLocation { return "current" }
        return settings.selectedPlace?.id.uuidString ?? "none"
    }

    func loadCacheIfNeeded() async {
        // 同時に呼ばれても読み込みは1回にし、全員が完了を待つ
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                self.cached = await self.cache.load(WeatherSnapshot.self, key: Self.cacheKey)
            }
        }
        await loadTask?.value
    }

    func clearMemory() {
        cached = nil
        loadTask = nil
    }

    /// 起動時・復帰時・地点変更時に呼ぶ。古いときだけ取得する。
    func refreshIfStale() async {
        await loadCacheIfNeeded()
        let sameSource = cached?.value.sourceID == currentSourceID
        let decision = settings.refreshPolicy.autoDecision(
            kind: .weather,
            fetchedAt: sameSource ? cached?.fetchedAt : nil,
            now: Date(),
            network: network.status
        )
        autoRefreshNote = decision.note
        if decision == .refresh { await fetch() }
    }

    func refreshManually() async {
        await loadCacheIfNeeded()
        guard settings.refreshPolicy.manualDecision(network: network.status) == .refresh else {
            errorMessage = "オフラインのため更新できません"
            return
        }
        await fetch()
    }

    private func fetch() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let sourceID = currentSourceID
            let name: String
            let latitude: Double
            let longitude: Double
            if settings.weatherUsesCurrentLocation {
                let loc = try await location.currentLocation()
                latitude = loc.coordinate.latitude
                longitude = loc.coordinate.longitude
                onCurrentLocation(latitude, longitude)
                // 500m以内で取得済みならキャッシュの地名を使う
                name = await placeNames.name(latitude: latitude, longitude: longitude) ?? "現在地"
            } else if let place = settings.selectedPlace {
                name = place.name
                latitude = place.latitude
                longitude = place.longitude
            } else {
                errorMessage = "地点が登録されていません。設定から登録してください。"
                return
            }
            let response = try await api.fetch(latitude: latitude, longitude: longitude)
            let snapshot = WeatherSnapshot(response: response, sourceID: sourceID, placeName: name,
                                           latitude: latitude, longitude: longitude)
            let now = Date()
            cached = CachedValue(value: snapshot, fetchedAt: now)
            try? await cache.save(snapshot, key: Self.cacheKey, fetchedAt: now)
            onFetched(now)
            autoRefreshNote = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension RefreshDecision {
    /// 自動更新を見送った理由の表示文。見送っていなければnil。
    var note: String? {
        switch self {
        case .refresh, .fresh: return nil
        case .offline: return "オフラインのためキャッシュを表示中"
        case .blockedByExpensive: return "従量制の回線のため自動更新を停止中(手動更新は可能)"
        case .blockedByConstrained: return "省データモードのため自動更新を停止中(手動更新は可能)"
        case .blockedByWiFiOnly: return "Wi-Fi以外のため自動更新を停止中(手動更新は可能)"
        }
    }
}

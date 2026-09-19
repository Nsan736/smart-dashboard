import Foundation
import Observation

protocol ExchangeAPI: Sendable {
    func fetchJPY() async throws -> ERAPIResponse
}

struct ERAPIClient: ExchangeAPI {
    let http: HTTPClient

    static let url = URL(string: "https://open.er-api.com/v6/latest/JPY")!

    func fetchJPY() async throws -> ERAPIResponse {
        try Self.decode(try await http.get(Self.url))
    }

    static func decode(_ data: Data) throws -> ERAPIResponse {
        try JSONDecoder().decode(ERAPIResponse.self, from: data)
    }
}

@MainActor
@Observable
final class ExchangeStore {
    private(set) var cached: CachedValue<ExchangeRates>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var autoRefreshNote: String?

    @ObservationIgnored private let api: ExchangeAPI
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let cacheKey = "exchange"

    init(api: ExchangeAPI, cache: DiskCache, settings: AppSettings, network: NetworkMonitor,
         onFetched: @escaping @MainActor (Date) -> Void) {
        self.api = api
        self.cache = cache
        self.settings = settings
        self.network = network
        self.onFetched = onFetched
    }

    func loadCacheIfNeeded() async {
        // 同時に呼ばれても読み込みは1回にし、全員が完了を待つ
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                self.cached = await self.cache.load(ExchangeRates.self, key: Self.cacheKey)
            }
        }
        await loadTask?.value
    }

    func clearMemory() {
        cached = nil
        loadTask = nil
    }

    /// APIの次回更新時刻より前は、取得しても同じ内容なので通信しない
    nonisolated static func isWorthFetching(_ cached: CachedValue<ExchangeRates>?, now: Date) -> Bool {
        guard let cached else { return true }
        return now >= cached.value.nextUpdateAt
    }

    func refreshIfStale() async {
        await loadCacheIfNeeded()
        let now = Date()
        guard Self.isWorthFetching(cached, now: now) else {
            autoRefreshNote = nil
            return
        }
        let decision = settings.refreshPolicy.autoDecision(
            kind: .exchange, fetchedAt: cached?.fetchedAt, now: now, network: network.status)
        autoRefreshNote = decision.note
        if decision == .refresh { await fetch() }
    }

    func refreshManually() async {
        await loadCacheIfNeeded()
        guard settings.refreshPolicy.manualDecision(network: network.status) == .refresh else {
            errorMessage = "オフラインのため更新できません"
            return
        }
        guard Self.isWorthFetching(cached, now: Date()) else {
            errorMessage = nil
            autoRefreshNote = "レートは1日1回の更新です。次回の更新時刻までは通信しません。"
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
            let rates = try ExchangeRates(response: try await api.fetchJPY())
            let now = Date()
            cached = CachedValue(value: rates, fetchedAt: now)
            try? await cache.save(rates, key: Self.cacheKey, fetchedAt: now)
            onFetched(now)
            autoRefreshNote = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

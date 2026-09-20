import Foundation
import Observation

enum QuakeConfig {
    /// 同じ地震に複数の報が出るので、5件を表示するために少し多めに要求する(転送時で約3KB)
    static let requestLimit = 10
}

/// 最近の地震。P2P地震情報の JSON API v2 から、地震情報(コード551)だけを件数を絞って取得する。
@MainActor
@Observable
final class QuakeStore {
    private(set) var cached: CachedValue<QuakeSnapshot>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var autoRefreshNote: String?

    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var didLoad = false

    private static let cacheKey = "p2pquake"

    init(http: HTTPClient, cache: DiskCache, settings: AppSettings, network: NetworkMonitor,
         onFetched: @escaping @MainActor (Date) -> Void) {
        self.http = http
        self.cache = cache
        self.settings = settings
        self.network = network
        self.onFetched = onFetched
    }

    nonisolated static func url(limit: Int = QuakeConfig.requestLimit) -> URL {
        var c = URLComponents(string: "https://api.p2pquake.net/v2/history")!
        c.queryItems = [URLQueryItem(name: "codes", value: "551"), URLQueryItem(name: "limit", value: String(limit))]
        return c.url!
    }

    /// 新しい順に最大5件
    var latest: [Quake] { Array((cached?.value.quakes ?? []).prefix(QuakeList.displayLimit)) }

    func loadCacheIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        cached = await cache.load(QuakeSnapshot.self, key: Self.cacheKey)
    }

    func clearMemory() {
        cached = nil
        didLoad = false
    }

    /// 最短5分間隔
    func refreshIfStale() async {
        await loadCacheIfNeeded()
        let decision = settings.refreshPolicy.autoDecision(kind: .quake, fetchedAt: cached?.fetchedAt, now: Date(), network: network.status)
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
            let items = try P2PQuakeItem.decode(try await http.get(Self.url()))
            let now = Date()
            let quakes = QuakeList.merge(old: cached?.value.quakes ?? [], new: QuakeList.make(items, limit: .max), now: now)
            let snapshot = QuakeSnapshot(quakes: quakes)
            cached = CachedValue(value: snapshot, fetchedAt: now)
            try? await cache.save(snapshot, key: Self.cacheKey, fetchedAt: now)
            onFetched(now)
            autoRefreshNote = nil
        } catch {
            errorMessage = "地震情報を取得できませんでした"
        }
    }
}

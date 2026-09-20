import Foundation
import Observation

/// 気象警報・注意報。天気を取得した地点の市区町村について、気象庁のデータを取得する。
/// 公式のAPIではないので、失敗してもほかの機能に影響させない。
@MainActor
@Observable
final class WarningStore {
    private(set) var cached: CachedValue<WarningSnapshot>?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var autoRefreshNote: String?

    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let placeNames: PlaceNameResolver
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var table: JMAAreaTable?
    @ObservationIgnored private var didLoad = false

    static let failureMessage = "警報・注意報を取得できませんでした（気象庁側の仕様変更の可能性）"
    private static let cacheKey = "jma-warning"

    init(http: HTTPClient, cache: DiskCache, settings: AppSettings, network: NetworkMonitor,
         placeNames: PlaceNameResolver, onFetched: @escaping @MainActor (Date) -> Void) {
        self.http = http
        self.cache = cache
        self.settings = settings
        self.network = network
        self.placeNames = placeNames
        self.onFetched = onFetched
    }

    nonisolated static func url(officeCode: String) -> URL {
        URL(string: "https://www.jma.go.jp/bosai/warning/data/r8/\(officeCode).json")!
    }

    func loadCacheIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        cached = await cache.load(WarningSnapshot.self, key: Self.cacheKey)
    }

    func clearMemory() {
        cached = nil
        didLoad = false
    }

    /// 最短10分間隔。更新のルールは天気などと同じ。
    func refreshIfStale(latitude: Double, longitude: Double) async {
        await loadCacheIfNeeded()
        guard let area = await area(latitude: latitude, longitude: longitude) else { return }
        let sameArea = cached?.value.area == area
        let decision = settings.refreshPolicy.autoDecision(kind: .warning, fetchedAt: sameArea ? cached?.fetchedAt : nil,
                                                           now: Date(), network: network.status)
        autoRefreshNote = decision.note
        if decision == .refresh { await fetch(area) }
    }

    func refreshManually(latitude: Double, longitude: Double) async {
        await loadCacheIfNeeded()
        guard settings.refreshPolicy.manualDecision(network: network.status) == .refresh else {
            errorMessage = "オフラインのため更新できません"
            return
        }
        guard let area = await area(latitude: latitude, longitude: longitude) else { return }
        await fetch(area)
    }

    private func area(latitude: Double, longitude: Double) async -> WarningArea? {
        if table == nil { table = JMAAreaTable.bundled() }
        guard let table else {
            errorMessage = "地域の一覧を読み込めませんでした"
            return nil
        }
        guard let place = await placeNames.place(latitude: latitude, longitude: longitude) else {
            if cached == nil { errorMessage = "現在地の市区町村を取得できませんでした" }
            return nil
        }
        guard let area = WarningAreaResolver.resolve(prefecture: place.prefecture, municipality: place.municipality, table: table) else {
            errorMessage = "この地点(\(place.name))は、警報の地域を決められませんでした"
            return nil
        }
        return area
    }

    private func fetch(_ area: WarningArea) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let data = try await http.get(Self.url(officeCode: area.officeCode))
            let reports = try JMAWarningReport.decode(data)
            let snapshot = WarningSnapshot(area: area,
                                           warnings: WarningExtractor.active(reports: reports, areaCodes: area.areaCodes),
                                           reportedAt: WarningExtractor.latestReportDate(reports))
            let now = Date()
            cached = CachedValue(value: snapshot, fetchedAt: now)
            try? await cache.save(snapshot, key: Self.cacheKey, fetchedAt: now)
            onFetched(now)
            autoRefreshNote = nil
        } catch {
            errorMessage = Self.failureMessage
        }
    }
}

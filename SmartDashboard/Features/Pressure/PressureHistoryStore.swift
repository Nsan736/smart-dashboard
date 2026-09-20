import Foundation
import Observation

/// 予報モデルの気圧の履歴(過去約100日〜7日先)を端末に保存する。
/// - 過去の分のまとめての取得は、Wi-Fiなど従量制でない回線のときだけ自動。モバイル通信では手動だけ
/// - 以後は、天気の更新(過去24時間を含む)のたびに追記する。空白が24時間を超えたら、詳細画面を開いたときに足りない分だけを取る
/// - 50km以上離れた地点に変わったら、保存した分を捨てて取り直す
@MainActor
@Observable
final class PressureHistoryStore {
    private(set) var history: PressureHistory?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 7日先までの予報を最後に取得した時刻
    private(set) var outlookFetchedAt: Date?

    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void

    private static let outlookKey = "pressure.outlookFetchedAt"

    init(http: HTTPClient, fileURL: URL, settings: AppSettings, network: NetworkMonitor,
         onFetched: @escaping @MainActor (Date) -> Void) {
        self.http = http
        self.fileURL = fileURL
        self.settings = settings
        self.network = network
        self.onFetched = onFetched
        if let data = try? Data(contentsOf: fileURL) {
            history = try? Self.decoder.decode(PressureHistory.self, from: data)
        }
        let stored = UserDefaults.standard.double(forKey: Self.outlookKey)
        outlookFetchedAt = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    var forecastPoints: [PressureForecastPoint] { history?.forecastPoints ?? [] }

    var storageBytes: Int64 {
        Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// 過去の分が未取得か、空白が大きくて取り直しが必要か
    func needsBackfill(now: Date = Date()) -> Bool {
        history?.needsBackfill(now: now) ?? true
    }

    /// 天気を取得するたびに呼ぶ。1時間値の気圧(過去24時間〜今後24時間)を追記する。通信はしない。
    func ingest(_ snapshot: WeatherSnapshot, now: Date = Date()) {
        guard let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
        let points = snapshot.hourly.compactMap { hour in
            hour.pressure.map { PressureHistory.Point(time: hour.time, hPa: $0) }
        }
        guard !points.isEmpty else { return }
        append(points, latitude: latitude, longitude: longitude, now: now)
    }

    private func append(_ points: [PressureHistory.Point], latitude: Double, longitude: Double, now: Date, backfilled: Bool = false) {
        var base = history ?? .empty(latitude: latitude, longitude: longitude)
        if base.isFar(latitude: latitude, longitude: longitude) {
            base = .empty(latitude: latitude, longitude: longitude)
            setOutlookFetchedAt(nil)
        }
        var merged = base.merged(with: points, now: now)
        if backfilled { merged.backfilledAt = now }
        guard merged != history else { return }
        history = merged
        if let data = try? Self.encoder.encode(merged) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// 過去の分をまとめて取得する。自動では、従量制でも省データでもない回線のときだけ。
    func backfillIfNeeded(latitude: Double, longitude: Double, manual: Bool = false) async {
        let now = Date()
        let relocated = history?.isFar(latitude: latitude, longitude: longitude) ?? false
        guard manual || relocated || needsBackfill(now: now) else { return }
        let status = network.status
        guard status.isOnline else {
            if manual { errorMessage = "オフラインのため取得できません" }
            return
        }
        if !manual, status.isExpensive || status.isConstrained || !status.isWiFi { return }
        await fetch(PressureRequests.backfillURL(latitude: latitude, longitude: longitude, now: now),
                    latitude: latitude, longitude: longitude, backfilled: true)
    }

    /// 詳細画面を開いたときに呼ぶ。足りない過去の分と、7日先までの予報を取得する。最短3時間間隔で、更新のルールはほかと同じ。
    func refreshOutlookIfStale(latitude: Double, longitude: Double) async {
        let relocated = history?.isFar(latitude: latitude, longitude: longitude) ?? false
        let decision = settings.refreshPolicy.autoDecision(kind: .pressureHistory, fetchedAt: relocated ? nil : outlookFetchedAt,
                                                           now: Date(), network: network.status)
        guard decision == .refresh else { return }
        await refreshOutlook(latitude: latitude, longitude: longitude)
    }

    func refreshOutlook(latitude: Double, longitude: Double) async {
        guard network.status.isOnline else {
            errorMessage = "オフラインのため取得できません"
            return
        }
        let pastHours = (history?.isFar(latitude: latitude, longitude: longitude) ?? true) ? 24 : (history?.neededPastHours(now: Date()) ?? 24)
        let ok = await fetch(PressureRequests.outlookURL(latitude: latitude, longitude: longitude, pastHours: pastHours),
                             latitude: latitude, longitude: longitude, backfilled: false)
        if ok { setOutlookFetchedAt(Date()) }
    }

    @discardableResult
    private func fetch(_ url: URL, latitude: Double, longitude: Double, backfilled: Bool) async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let response = try JSONDecoder().decode(OpenMeteoPressureResponse.self, from: try await http.get(url))
            let now = Date()
            append(response.points, latitude: latitude, longitude: longitude, now: now, backfilled: backfilled)
            onFetched(now)
            return true
        } catch {
            errorMessage = "気圧の履歴を取得できませんでした"
            return false
        }
    }

    private func setOutlookFetchedAt(_ date: Date?) {
        outlookFetchedAt = date
        UserDefaults.standard.set(date?.timeIntervalSince1970 ?? 0, forKey: Self.outlookKey)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

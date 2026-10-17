import Foundation
import Observation

/// 国土地理院の標高API(https://cyberjapandata2.gsi.go.jp/general/dem/scripts/getelevation.php)
///
/// 形式(2026-10-17に確認): `?lon=経度&lat=緯度&outtype=JSON` で `{"elevation":18.5,"hsrc":"1m（レーザ）"}`(gzip で約70B)。
/// データがない場所(海上、国外など)も HTTP 200 で、`{"elevation":"-----","hsrc":"-----"}` が返る。
enum GSIElevationAPI {
    enum Result: Equatable {
        /// 標高(m)と、元のデータ(「1m（レーザ）」「5m（写真測量）」「10m」など)
        case value(Double, source: String?)
        /// その場所の標高のデータがない
        case noData
    }

    enum ParseError: Error {
        case invalid
    }

    static let endpoint = URL(string: "https://cyberjapandata2.gsi.go.jp/general/dem/scripts/getelevation.php")!

    static func url(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "lon", value: String(format: "%.6f", longitude)),
            URLQueryItem(name: "lat", value: String(format: "%.6f", latitude)),
            URLQueryItem(name: "outtype", value: "JSON"),
        ]
        return c.url!
    }

    static func parse(_ data: Data) throws -> Result {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let raw = object["elevation"] else {
            throw ParseError.invalid
        }
        let source = (object["hsrc"] as? String).flatMap { $0.hasPrefix("---") ? nil : $0 }
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            return value.isFinite ? .value(value, source: source) : .noData
        }
        if let text = raw as? String {
            // 数字の文字列で返ることもありうるので読んでみる。「-----」はデータなし。
            if let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite { return .value(value, source: source) }
            return .noData
        }
        throw ParseError.invalid
    }
}

/// 現在地の地面の標高(自分の高さに使う)。前回の位置から100m以上動いたときだけ取り直す。
struct GroundElevation: Codable, Equatable {
    /// この距離より動いたら、地面の標高を取り直す
    static let reuseDistance = 100.0

    var latitude: Double
    var longitude: Double
    /// nil はデータがない場所
    var elevation: Double?
    var fetchedAt: Date
}

/// 地点の標高と、自分の地面の標高を、国土地理院の標高APIで取る。通信は HTTPClient を通し、受信量は「スコープ」に数える。
@MainActor
@Observable
final class ElevationStore {
    enum Lookup: Equatable {
        case value(Double)
        case noData
        case failed(String)
    }

    private(set) var ground: GroundElevation?
    private(set) var isFillingWaypoints = false
    /// 標高を取得中の地点
    private(set) var fetching: Set<UUID> = []

    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let waypoints: WaypointStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var groundTask: Task<Void, Never>?

    /// 地点の標高を続けて取るときの間隔(API に負担をかけないように)
    static let interval: UInt64 = 300_000_000
    private static let groundKey = "scope.groundElevation"

    init(http: HTTPClient, network: NetworkMonitor, settings: AppSettings, waypoints: WaypointStore,
         defaults: UserDefaults = .standard, onFetched: @escaping @MainActor (Date) -> Void) {
        self.http = http
        self.network = network
        self.settings = settings
        self.waypoints = waypoints
        self.defaults = defaults
        self.onFetched = onFetched
        if let data = defaults.data(forKey: Self.groundKey) {
            ground = try? JSONDecoder().decode(GroundElevation.self, from: data)
        }
    }

    /// 1地点の標高を問い合わせる
    func lookup(latitude: Double, longitude: Double) async -> Lookup {
        guard network.status.isOnline else { return .failed("オフラインのため取得できません") }
        do {
            let data = try await http.get(GSIElevationAPI.url(latitude: latitude, longitude: longitude))
            onFetched(Date())
            switch try GSIElevationAPI.parse(data) {
            case .value(let value, _): return .value(value)
            case .noData: return .noData
            }
        } catch {
            return .failed("標高を取得できませんでした")
        }
    }

    /// 登録したとき・座標を変えたときに呼ぶ。オフラインなら「未設定」のまま(Wi-Fi接続中に自動で取り直す)。
    func fetchElevation(for id: UUID) async {
        guard !fetching.contains(id), let waypoint = waypoints.waypoints.first(where: { $0.id == id }) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        switch await lookup(latitude: waypoint.latitude, longitude: waypoint.longitude) {
        case .value(let value): waypoints.setElevation(id: id, value: value, state: .fetched)
        case .noData: waypoints.setElevation(id: id, value: nil, state: .noData)
        case .failed: break
        }
    }

    /// 標高が未設定の地点(以前の版で保存した地点、オフラインで登録した地点)を、Wi-Fiなど従量制でない回線のときに取る。
    func fillMissing() async {
        let missing = waypoints.waypoints.filter { $0.elevationState == .unset }.map(\.id)
        guard !missing.isEmpty, !isFillingWaypoints, MapMode.canDownloadTiles(network: network.status) else { return }
        isFillingWaypoints = true
        defer { isFillingWaypoints = false }
        for (index, id) in missing.enumerated() {
            guard MapMode.canDownloadTiles(network: network.status) else { return }
            if index > 0 { try? await Task.sleep(nanoseconds: Self.interval) }
            await fetchElevation(for: id)
        }
    }

    /// 現在地の地面の標高。前回取った位置から100m以内なら、その値を使う。
    func groundElevation(nearLatitude latitude: Double, longitude: Double) -> Double? {
        guard let ground, Self.isNear(ground, latitude: latitude, longitude: longitude) else { return nil }
        return ground.elevation
    }

    nonisolated static func isNear(_ ground: GroundElevation, latitude: Double, longitude: Double) -> Bool {
        WaypointMath.distance(fromLatitude: ground.latitude, longitude: ground.longitude, toLatitude: latitude, longitude: longitude)
            < GroundElevation.reuseDistance
    }

    /// 自分の高さを「地面の標高+手の高さ」で決めるとき、現在地が変わるたびに呼ぶ。100m以上動いたときだけ取り直す。
    /// 自動の通信なので、省データモードや「Wi-Fi時のみ自動更新」の設定に従う。
    func updateGround(latitude: Double, longitude: Double) {
        if let ground, Self.isNear(ground, latitude: latitude, longitude: longitude) { return }
        guard groundTask == nil else { return }
        let decision = settings.refreshPolicy.autoDecision(kind: .elevation, fetchedAt: nil, now: Date(), network: network.status)
        guard decision == .refresh else { return }
        groundTask = Task { [weak self] in
            guard let self else { return }
            defer { self.groundTask = nil }
            let result = await self.lookup(latitude: latitude, longitude: longitude)
            let value: Double?
            switch result {
            case .value(let meters): value = meters
            case .noData: value = nil
            case .failed: return
            }
            let new = GroundElevation(latitude: latitude, longitude: longitude, elevation: value, fetchedAt: Date())
            self.ground = new
            if let data = try? JSONEncoder().encode(new) { self.defaults.set(data, forKey: Self.groundKey) }
        }
    }

    /// 今の設定と値で決めた自分の高さ
    func observerHeight(latitude: Double, longitude: Double, gpsAltitude: Double?) -> ObserverHeight? {
        ObserverHeight.resolve(source: settings.scopeHeightSource, gpsAltitude: gpsAltitude,
                               groundElevation: groundElevation(nearLatitude: latitude, longitude: longitude),
                               handHeight: settings.scopeHandHeight)
    }
}

import Foundation
import Observation

enum TrainStatus: String, Codable {
    case normal
    case delay
    case suspended
    case other

    var label: String {
        switch self {
        case .normal: return "平常"
        case .delay: return "遅延"
        case .suspended: return "見合わせ"
        case .other: return "情報あり"
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .delay: return "clock.badge.exclamationmark.fill"
        case .suspended: return "xmark.octagon.fill"
        case .other: return "info.circle.fill"
        }
    }

    /// odpt:trainInformationStatus は平常時に省略される。
    /// 省略されていて本文だけがある場合は、本文から大まかに判定する。
    static func classify(status: String?, text: String?) -> TrainStatus {
        if let status, !status.isEmpty {
            if status.contains("平常") { return .normal }
            if status.contains("見合わせ") || status.contains("運休") { return .suspended }
            if status.contains("遅延") || status.contains("遅れ") { return .delay }
            return .other
        }
        guard let text, !text.isEmpty else { return .normal }
        if text.contains("ありません") || text.contains("平常") { return .normal }
        if text.contains("見合わせ") { return .suspended }
        if text.contains("遅延") || text.contains("遅れ") { return .delay }
        return .normal
    }
}

/// 開発者向け: 運行情報の直近の応答(生のJSON)。直近の1件だけを保存する。
/// トークンはURLのクエリにだけ含まれ、応答の本文には含まれない。
struct TrainInfoCapture: Codable, Equatable {
    var operatorName: String
    var railwayIDs: [String]
    var body: String
}

/// 経路の検索のために時刻表を保存した路線(運行情報や駅の登録とは別)
struct RouteRailway: Codable, Equatable, Identifiable {
    var operatorID: String
    var railwayID: String
    var name: String

    var id: String { railwayID }
}

struct TrainInfoItem: Codable, Equatable, Identifiable {
    var railwayID: String
    var railwayName: String
    var status: TrainStatus
    var statusText: String?
    var text: String?
    var id: String { railwayID }
}

@MainActor
@Observable
final class TrainStore {
    private(set) var lines: [RegisteredLine] = []
    private(set) var stations: [RegisteredStation] = []
    /// 経路の検索のために時刻表を保存した路線
    private(set) var routeRailways: [RouteRailway] = []
    /// 駅の一覧と乗り換えの関係(経路の検索と、行きたい駅の検索に使う)
    private(set) var directory: TransitDirectory?
    private(set) var isLoadingDirectory = false
    private(set) var directoryError: String?
    /// 駅の一覧に、まだ入れていない事業者(Wi-Fi接続時か、行きたい駅の検索を開いたときに取得する)
    private(set) var directoryPendingOperators: [String] = []
    /// 駅と路線の検索の索引(検出した事業者すべての駅。通信せずに検索する)
    private(set) var stationSearch: StationSearchIndex?
    private(set) var isLoadingStationCatalog = false
    private(set) var stationCatalogError: String?
    /// 駅の一覧をまだ保存していない事業者(モバイル通信では「駅の一覧を取得」のボタンで取得する)
    private(set) var stationCatalogPending: [String] = []
    /// 最近検索して選んだ駅の名前(新しい順)
    private(set) var recentStationSearches: [String] = []
    private(set) var info: CachedValue<[TrainInfoItem]>?
    private(set) var timetables: [UUID: StoredTimetable] = [:]
    /// 地図に描く路線の形。キーは路線ID。
    private(set) var shapes: [String: RailwayShape] = [:]
    private(set) var isLoadingShapes = false
    private(set) var shapeError: String?
    /// 開発者向け: 運行情報の直近の応答
    private(set) var lastCapture: CachedValue<TrainInfoCapture>?
    private(set) var isLoadingInfo = false
    private(set) var downloadingTimetables: Set<UUID> = []
    private(set) var infoError: String?
    private(set) var timetableError: String?
    private(set) var autoRefreshNote: String?

    @ObservationIgnored let api: ODPTAPI
    /// 事業者の検出の結果(事業者を引く、路線で使えるデータを調べる)
    @ObservationIgnored let discovery: OperatorDiscoveryStore
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let timetableStorage: DiskCache
    @ObservationIgnored private let shapeStorage: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let hasToken: @MainActor () -> Bool
    @ObservationIgnored private let onFetched: @MainActor (DataKind, Date) -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// 路線の線(線路の形か、駅を結んだ直線)の作り置き
    @ObservationIgnored private var rideLineCache: (key: String, lines: [String: RideLine]) = ("", [:])
    /// 検索の索引を作った事業者と時刻(同じなら、開くたびに作り直さない)
    @ObservationIgnored private var stationSearchBuilt: (operators: [String], at: Date)?

    private static let infoKey = "trainInfo"
    private static let captureKey = "debug.trainInformation"

    init(api: ODPTAPI, discovery: OperatorDiscoveryStore, cache: DiskCache, timetableStorage: DiskCache, shapeStorage: DiskCache,
         settings: AppSettings, network: NetworkMonitor,
         hasToken: @escaping @MainActor () -> Bool, onFetched: @escaping @MainActor (DataKind, Date) -> Void,
         defaults: UserDefaults = .standard) {
        self.api = api
        self.discovery = discovery
        self.cache = cache
        self.timetableStorage = timetableStorage
        self.shapeStorage = shapeStorage
        self.settings = settings
        self.network = network
        self.hasToken = hasToken
        self.onFetched = onFetched
        self.defaults = defaults
        lines = Self.load([RegisteredLine].self, defaults, Keys.lines) ?? []
        stations = Self.load([RegisteredStation].self, defaults, Keys.stations) ?? []
        routeRailways = Self.load([RouteRailway].self, defaults, Keys.routeRailways) ?? []
        recentStationSearches = defaults.stringArray(forKey: Keys.recentSearches) ?? []
    }

    /// 事業者のすべての駅の保存のキー。v0.9.14 で駅ナンバリングと読み仮名を読むようにしたので、キーを変えて取り直す。
    nonisolated static func operatorStationsKey(_ operatorID: String) -> String {
        "operatorStations2.\(operatorID)"
    }

    func loadIfNeeded() async {
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                self.info = await self.cache.load([TrainInfoItem].self, key: Self.infoKey)
                self.lastCapture = await self.cache.load(TrainInfoCapture.self, key: Self.captureKey)
                for station in self.stations {
                    if let stored = await self.timetableStorage.load(StoredTimetable.self, key: station.id.uuidString) {
                        self.timetables[station.id] = stored.value
                    }
                }
                for railway in self.neededRailways {
                    if let stored = await self.shapeStorage.load(RailwayShape.self, key: railway.railwayID) {
                        self.shapes[railway.railwayID] = stored.value
                    }
                }
            }
        }
        await loadTask?.value
    }

    /// キャッシュ削除のあとに呼ぶ。保存した時刻表は消さない。
    func clearCachedInfo() {
        info = nil
        lastCapture = nil
    }

    // MARK: - 事業者と、路線で使えるデータ

    /// 事業者を引く(検出の結果、なければ予備の定義)。見つからないIDでも、トークンが必要な事業者として返す。
    func operatorInfo(_ id: String) -> TrainOperator {
        discovery.operatorInfo(id)
    }

    /// 路線で使えるデータ。検出していない路線は、すべて使えるものとして扱う(取得して空なら、その旨を表示する)。
    func capabilities(ofRailway id: String) -> ODPTCapabilities {
        discovery.capabilities(ofRailway: id) ?? .assumed
    }

    // MARK: - 登録

    func addLine(_ line: RegisteredLine) {
        guard !lines.contains(where: { $0.railwayID == line.railwayID }) else { return }
        lines.append(line)
        save(lines, Keys.lines)
    }

    func removeLines(ids: [String]) {
        removeLines(at: IndexSet(lines.indices.filter { ids.contains(lines[$0].railwayID) }))
    }

    func removeLines(at offsets: IndexSet) {
        lines.remove(atOffsets: offsets)
        save(lines, Keys.lines)
        if let info {
            let ids = Set(lines.map(\.railwayID))
            self.info = CachedValue(value: info.value.filter { ids.contains($0.railwayID) }, fetchedAt: info.fetchedAt)
        }
        removeUnusedShapes()
    }

    func addStation(_ station: RegisteredStation) {
        stations.append(station)
        save(stations, Keys.stations)
    }

    func removeStations(at offsets: IndexSet) {
        let removed = offsets.map { stations[$0] }
        stations.remove(atOffsets: offsets)
        save(stations, Keys.stations)
        for station in removed {
            timetables[station.id] = nil
            Task { await timetableStorage.remove(key: station.id.uuidString) }
        }
        removeUnusedShapes()
    }

    // MARK: - 路線の形(地図用)

    /// 登録した路線(運行情報の路線と、時刻表の駅がある路線)。遅れはこの路線だけ取得する。
    var registeredRailways: [(operatorID: String, railwayID: String)] {
        var seen = Set<String>()
        let all = lines.map { ($0.operatorID, $0.railwayID) } + stations.map { ($0.operatorID, $0.railwayID) }
        return all.filter { seen.insert($0.1).inserted }.map { (operatorID: $0.0, railwayID: $0.1) }
    }

    /// 地図に描き、列車ごとの時刻表を保存する路線(登録した路線と、経路の検索のために足した路線)
    var neededRailways: [(operatorID: String, railwayID: String)] {
        var seen = Set(registeredRailways.map(\.railwayID))
        let extra = routeRailways.filter { seen.insert($0.railwayID).inserted }.map { (operatorID: $0.operatorID, railwayID: $0.railwayID) }
        return registeredRailways + extra
    }

    /// 路線の表示名(登録した路線、経路の検索のために足した路線、駅の一覧の路線)
    var railwayNames: [String: String] {
        var names = directory?.railwayNames ?? [:]
        for railway in routeRailways { names[railway.railwayID] = railway.name }
        for station in stations { names[station.railwayID] = station.railwayName }
        for line in lines { names[line.railwayID] = line.railwayName }
        return names
    }

    // MARK: - 路線の線(地図・乗車中の判定・列車の位置・デバッグで共通)

    /// 路線の形がある路線の線。同梱した線路の形があればそれを、なければ駅を結んだ直線を使う。路線や名前が変わったときだけ作り直す。
    func rideLines() -> [RideLine] {
        let ids = neededRailways.map(\.railwayID)
        let names = railwayNames
        let key = ids.map { id in "\(id):\(shapes[id]?.stops.count ?? -1):\(names[id] ?? "")" }.joined(separator: ",")
        if key != rideLineCache.key {
            var built: [String: RideLine] = [:]
            for id in ids {
                guard let shape = shapes[id],
                      let line = RideLine.make(shape: shape, name: names[id] ?? ODPTID.tail(id), track: RailwayTrackCatalog.bundled.track(for: id))
                else { continue }
                built[id] = line
            }
            rideLineCache = (key, built)
        }
        return ids.compactMap { rideLineCache.lines[$0] }
    }

    func rideLine(for railwayID: String) -> RideLine? {
        _ = rideLines()
        return rideLineCache.lines[railwayID]
    }

    // MARK: - 経路の検索のための路線

    func addRouteRailways(_ list: [RouteRailway]) {
        var changed = false
        for railway in list where !routeRailways.contains(where: { $0.railwayID == railway.railwayID }) {
            routeRailways.append(railway)
            changed = true
        }
        if changed { save(routeRailways, Keys.routeRailways) }
    }

    func removeRouteRailways(ids: Set<String>) {
        routeRailways.removeAll { ids.contains($0.railwayID) }
        save(routeRailways, Keys.routeRailways)
        removeUnusedShapes()
    }

    // MARK: - 駅の一覧と乗り換えの関係

    /// 経路の検索に使う駅の一覧(乗り換えの関係と緯度経度を含む)を読み込む。事業者ごとに30日間キャッシュする(都営で約13KB)。
    /// 対象は、使っている事業者と、検出した事業者のうち列車ごとの時刻表があるもの(事業者をまたぐ経路のため)。
    /// 使っていない事業者の駅は、手動(行きたい駅の検索を開いたとき)か、従量制でない回線のときだけ取得する。
    func ensureDirectory(manual: Bool) async {
        await loadIfNeeded()
        let used = Set(neededRailways.map(\.operatorID))
        let others = discovery.operators.filter { !used.contains($0.id) && !$0.isFallback && $0.capabilities.trainTimetable }.map(\.id)
        let operators = (used.sorted() + others.sorted()).map { operatorInfo($0) }
        guard !operators.isEmpty, !isLoadingDirectory else { return }
        isLoadingDirectory = true
        defer { isLoadingDirectory = false }
        var stationsList: [TransitStation] = []
        var names: [String: String] = [:]
        var failed = false
        var pending: [String] = []
        for op in operators {
            let key = Self.operatorStationsKey(op.id)
            let cached = await cache.load([ODPTStation].self, key: key)
            let isUsed = used.contains(op.id)
            if !isUsed, cached == nil, !manual, !MapMode.canDownloadTiles(network: network.status) {
                pending.append(op.name)
                continue
            }
            if let list = try? await railways(of: op) {
                for railway in list { names[railway.sameAs] = railway.name }
            }
            if let cached, Date().timeIntervalSince(cached.fetchedAt) < DataKind.railwayCatalog.minimumInterval {
                stationsList += cached.value.compactMap { TransitStation($0) }
                continue
            }
            let decision = manual
                ? settings.refreshPolicy.manualDecision(network: network.status)
                : settings.refreshPolicy.autoDecision(kind: .railwayCatalog, fetchedAt: nil, now: Date(), network: network.status)
            if decision == .refresh, let list = try? await api.stations(ofOperator: op) {
                let now = Date()
                try? await cache.save(list, key: key, fetchedAt: now)
                onFetched(.railwayCatalog, now)
                stationsList += list.compactMap { TransitStation($0) }
            } else if let cached {
                // 古くても、ないよりはよい
                stationsList += cached.value.compactMap { TransitStation($0) }
            } else if isUsed {
                failed = true
            } else {
                pending.append(op.name)
            }
        }
        directoryPendingOperators = pending
        directoryError = failed && stationsList.isEmpty ? "駅の一覧を取得できませんでした" : nil
        if !stationsList.isEmpty { directory = TransitDirectory(stations: stationsList, railwayNames: names) }
    }

    // MARK: - 駅と路線の検索

    /// 検索に使う、検出した事業者すべての駅の一覧を読み込み、索引を作る。事業者ごとに30日間保存する。
    /// 取得は、自動(manual = false)では従量制でない回線(Wi-Fiなど)のときだけ。モバイル通信では「駅の一覧を取得」のボタン(manual = true)。
    /// 事業者はカンマ区切りで10件ずつにまとめて問い合わせる(エンドポイントごと)。
    func ensureStationCatalog(manual: Bool) async {
        await loadIfNeeded()
        await discovery.loadIfNeeded()
        guard !isLoadingStationCatalog else { return }
        let operators = discovery.operators
        let now = Date()
        if !manual, stationSearch != nil, let built = stationSearchBuilt, built.operators == operators.map(\.id),
           now.timeIntervalSince(built.at) < 3600 { return }
        isLoadingStationCatalog = true
        defer { isLoadingStationCatalog = false }
        var lists: [String: [ODPTStation]] = [:]
        var stale: [TrainOperator] = []
        for op in operators {
            if let cached = await cache.load([ODPTStation].self, key: Self.operatorStationsKey(op.id)) {
                lists[op.id] = cached.value
                if now.timeIntervalSince(cached.fetchedAt) >= DataKind.railwayCatalog.minimumInterval { stale.append(op) }
            } else {
                stale.append(op)
            }
        }
        let allowed = manual ? network.status.isOnline : MapMode.canDownloadTiles(network: network.status)
        if !stale.isEmpty, allowed {
            stationCatalogError = nil
            let groups = Dictionary(grouping: stale, by: \.endpoint)
            for endpoint in groups.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let group = groups[endpoint], !(endpoint.requiresToken && !hasToken()) else { continue }
                do {
                    let fetched = try await api.stations(operatorIDs: group.map(\.id), endpoint: endpoint)
                    let byOperator = Dictionary(grouping: fetched) { $0.operatorID ?? ODPTID.operatorID(of: $0.sameAs) ?? "" }
                    let fetchedAt = Date()
                    for op in group {
                        let list = byOperator[op.id] ?? []
                        lists[op.id] = list
                        try? await cache.save(list, key: Self.operatorStationsKey(op.id), fetchedAt: fetchedAt)
                    }
                    onFetched(.railwayCatalog, fetchedAt)
                } catch {
                    stationCatalogError = error.localizedDescription
                }
            }
        }
        stationCatalogPending = operators.filter { lists[$0.id] == nil }.map(\.name)
        // 路線の名前・英語名・色(検出のときの応答か、保存した一覧を使う)
        var railways: [ODPTRailway] = []
        for op in operators where lists[op.id] != nil {
            if let list = try? await railways(of: op, allowFetch: allowed) { railways += list }
        }
        let names = Dictionary(operators.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let catalog = lists
        let railwayList = railways
        stationSearch = await Task.detached(priority: .userInitiated) {
            StationSearchIndex.make(stations: catalog, railways: railwayList, operatorNames: names)
        }.value
        stationSearchBuilt = (operators.map(\.id), Date())
    }

    /// 検索で「登録済み」として先に並べる路線
    var registeredRailwayIDs: Set<String> {
        Set(registeredRailways.map(\.railwayID))
    }

    /// 最近検索して選んだ駅に足す(5件まで)
    func addRecentStationSearch(_ name: String) {
        var list = recentStationSearches.filter { $0 != name }
        list.insert(name, at: 0)
        recentStationSearches = Array(list.prefix(5))
        defaults.set(recentStationSearches, forKey: Keys.recentSearches)
    }

    /// 緯度経度が取れなかった駅(報告用)
    var stationsWithoutCoordinates: [String] {
        shapes.values.flatMap(\.missingStationIDs).sorted()
    }

    /// まだ形を持っていない路線だけを取得する。一度作れば端末に保存し、以後は通信しない。
    /// manual が false のときは自動更新のポリシーに従う(従量制の回線などでは取得しない)。
    func ensureShapes(manual: Bool) async {
        await loadIfNeeded()
        // 駅の位置が提供されていない路線は、取得しても線を描けないので取得しない
        let missing = neededRailways.filter { shapes[$0.railwayID] == nil && capabilities(ofRailway: $0.railwayID).stationLocation }
        guard !missing.isEmpty, !isLoadingShapes else { return }
        let decision = manual
            ? settings.refreshPolicy.manualDecision(network: network.status)
            : settings.refreshPolicy.autoDecision(kind: .railwayCatalog, fetchedAt: nil, now: Date(), network: network.status)
        guard decision == .refresh else { return }
        isLoadingShapes = true
        defer { isLoadingShapes = false }
        shapeError = nil
        for target in missing {
            let op = operatorInfo(target.operatorID)
            do {
                guard let railway = try await railways(of: op).first(where: { $0.sameAs == target.railwayID }) else { continue }
                let list = try await stationsWithCoordinates(of: railway, op: op)
                let shape = RailwayShape.build(railway: railway, stations: list)
                shapes[target.railwayID] = shape
                try? await shapeStorage.save(shape, key: target.railwayID, fetchedAt: Date())
            } catch {
                shapeError = error.localizedDescription
            }
        }
    }

    /// 駅データは30日間キャッシュする。緯度経度を含まない古いキャッシュは使わない。
    private func stationsWithCoordinates(of railway: ODPTRailway, op: TrainOperator) async throws -> [ODPTStation] {
        let key = "stations.\(railway.sameAs)"
        if let cached = await cache.load([ODPTStation].self, key: key),
           Date().timeIntervalSince(cached.fetchedAt) < DataKind.railwayCatalog.minimumInterval,
           cached.value.contains(where: { $0.latitude != nil }) {
            return cached.value
        }
        let list = try await api.stations(ofRailway: railway.sameAs, op: op)
        try? await cache.save(list, key: key, fetchedAt: Date())
        return list
    }

    private func removeUnusedShapes() {
        let needed = Set(neededRailways.map(\.railwayID))
        for id in shapes.keys where !needed.contains(id) {
            shapes[id] = nil
            Task { await shapeStorage.remove(key: id) }
        }
    }

    // MARK: - 運行情報

    /// 運行情報を取得する路線(運行情報が提供されていない路線は除く)
    var infoLines: [RegisteredLine] {
        lines.filter { capabilities(ofRailway: $0.railwayID).trainInformation }
    }

    func refreshInfoIfStale() async {
        await loadIfNeeded()
        guard !infoLines.isEmpty else { return }
        let cachedIDs = Set(info?.value.map(\.railwayID) ?? [])
        let covered = Set(infoLines.map(\.railwayID)).isSubset(of: cachedIDs)
        let decision = settings.refreshPolicy.autoDecision(
            kind: .trainInfo, fetchedAt: covered ? info?.fetchedAt : nil, now: Date(), network: network.status)
        autoRefreshNote = decision.note
        if decision == .refresh { await fetchInfo() }
    }

    func refreshInfoManually() async {
        await loadIfNeeded()
        guard !infoLines.isEmpty else { return }
        guard settings.refreshPolicy.manualDecision(network: network.status) == .refresh else {
            infoError = "オフラインのため更新できません"
            return
        }
        await fetchInfo()
    }

    private func fetchInfo() async {
        guard !isLoadingInfo else { return }
        isLoadingInfo = true
        defer { isLoadingInfo = false }
        infoError = nil
        var items: [TrainInfoItem] = []
        var errors: [String] = []
        // 事業者ごとに1リクエスト。路線はカンマ区切りで絞る。
        let targets = infoLines
        let grouped = Dictionary(grouping: targets, by: \.operatorID)
        for (operatorID, group) in grouped {
            let op = operatorInfo(operatorID)
            do {
                let data = try await api.trainInformationData(op: op, railwayIDs: group.map(\.railwayID))
                // デコードに失敗した応答こそ調べたいので、先に保存する。追加の通信はしない。
                let capture = TrainInfoCapture(operatorName: op.name, railwayIDs: group.map(\.railwayID),
                                               body: String(decoding: data, as: UTF8.self))
                let capturedAt = Date()
                lastCapture = CachedValue(value: capture, fetchedAt: capturedAt)
                try? await cache.save(capture, key: Self.captureKey, fetchedAt: capturedAt)
                let response = try ODPTClient.decode([ODPTTrainInformation].self, from: data)
                items += Self.makeItems(lines: group, response: response)
            } catch {
                errors.append(error.localizedDescription)
                // 失敗した事業者の分は前回の値を残す
                items += info?.value.filter { old in group.contains { $0.railwayID == old.railwayID } } ?? []
            }
        }
        if !errors.isEmpty { infoError = errors.joined(separator: "\n") }
        guard errors.count < grouped.count || grouped.isEmpty else { return }
        let order = targets.map(\.railwayID)
        items.sort { (order.firstIndex(of: $0.railwayID) ?? 0) < (order.firstIndex(of: $1.railwayID) ?? 0) }
        let now = Date()
        info = CachedValue(value: items, fetchedAt: now)
        try? await cache.save(items, key: Self.infoKey, fetchedAt: now)
        onFetched(.trainInfo, now)
        autoRefreshNote = nil
    }

    /// 応答に含まれない路線は「情報なし(平常)」として扱う。
    /// 路線を持たない運行情報(事業者全体のお知らせ)は、その事業者の路線に使う。
    nonisolated static func makeItems(lines: [RegisteredLine], response: [ODPTTrainInformation]) -> [TrainInfoItem] {
        lines.map { line in
            let match = response.first { $0.railway == line.railwayID }
                ?? response.first { $0.railway == nil && $0.operatorID == line.operatorID }
            return TrainInfoItem(
                railwayID: line.railwayID,
                railwayName: line.railwayName,
                status: TrainStatus.classify(status: match?.status?.text, text: match?.text?.text),
                statusText: match?.status?.text,
                text: match?.text?.text
            )
        }
    }

    // MARK: - 路線・駅の一覧(長期間キャッシュする)

    /// allowFetch が false のときは、保存した一覧と検出のときの応答だけを使い、通信しない(なければ空)
    func railways(of op: TrainOperator, allowFetch: Bool = true) async throws -> [ODPTRailway] {
        let key = "railways2.\(op.id)"
        if let cached = await cache.load([ODPTRailway].self, key: key),
           Date().timeIntervalSince(cached.fetchedAt) < DataKind.railwayCatalog.minimumInterval {
            return cached.value
        }
        // 事業者の検出で取得した応答があれば、取り直さない
        if let detected = discovery.railwayData(of: op.id) {
            let list = detected.sorted { $0.name < $1.name }
            try? await cache.save(list, key: key, fetchedAt: discovery.result?.detectedAt ?? Date())
            return list
        }
        guard allowFetch else { return [] }
        let list = try await api.railways(of: op).sorted { $0.name < $1.name }
        let now = Date()
        try? await cache.save(list, key: key, fetchedAt: now)
        onFetched(.railwayCatalog, now)
        return list
    }

    /// 路線の応答に駅名が入っていればそれを使い、なければ odpt:Station を取得する
    func stationList(of railway: ODPTRailway, op: TrainOperator) async throws -> [(id: String, name: String)] {
        if let order = railway.stationOrder, !order.isEmpty, order.allSatisfy({ $0.stationTitle?.text != nil }) {
            return order.sorted { $0.index < $1.index }.map { ($0.station, $0.stationTitle?.text ?? ODPTID.tail($0.station)) }
        }
        let key = "stations.\(railway.sameAs)"
        if let cached = await cache.load([ODPTStation].self, key: key),
           Date().timeIntervalSince(cached.fetchedAt) < DataKind.railwayCatalog.minimumInterval {
            return cached.value.map { ($0.sameAs, $0.name) }
        }
        let list = try await api.stations(ofRailway: railway.sameAs, op: op)
        try? await cache.save(list, key: key, fetchedAt: Date())
        return list.map { ($0.sameAs, $0.name) }
    }

    func directionNames(endpoint: ODPTEndpoint) async -> [String: String] {
        let key = "railDirections.\(endpoint.rawValue)"
        if let cached = await cache.load([ODPTRailDirection].self, key: key),
           Date().timeIntervalSince(cached.fetchedAt) < DataKind.railwayCatalog.minimumInterval {
            return Dictionary(cached.value.map { ($0.sameAs, $0.name) }, uniquingKeysWith: { a, _ in a })
        }
        guard let list = try? await api.railDirections(endpoint: endpoint) else { return [:] }
        try? await cache.save(list, key: key, fetchedAt: Date())
        return Dictionary(list.map { ($0.sameAs, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    func trainTypeNames(of op: TrainOperator) async -> [String: String] {
        let key = "trainTypes.\(op.id)"
        if let cached = await cache.load([ODPTTrainType].self, key: key),
           Date().timeIntervalSince(cached.fetchedAt) < DataKind.railwayCatalog.minimumInterval {
            return Dictionary(cached.value.map { ($0.sameAs, $0.name) }, uniquingKeysWith: { a, _ in a })
        }
        guard let list = try? await api.trainTypes(of: op) else { return [:] }
        try? await cache.save(list, key: key, fetchedAt: Date())
        return Dictionary(list.map { ($0.sameAs, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - 時刻表(手動でのみダウンロードする)

    func downloadTimetable(for station: RegisteredStation) async {
        guard !downloadingTimetables.contains(station.id) else { return }
        let op = operatorInfo(station.operatorID)
        guard capabilities(ofRailway: station.railwayID).stationTimetable else {
            timetableError = "\(station.railwayName)は駅の時刻表が提供されていません"
            return
        }
        guard network.status.isOnline else {
            timetableError = "オフラインのためダウンロードできません"
            return
        }
        downloadingTimetables.insert(station.id)
        defer { downloadingTimetables.remove(station.id) }
        timetableError = nil
        do {
            let tables = try await api.stationTimetables(stationID: station.stationID, directionID: station.directionID, op: op)
            guard !tables.isEmpty else {
                timetableError = "\(station.stationName)(\(station.directionName))の時刻表は提供されていません"
                return
            }
            let typeNames = await trainTypeNames(of: op)
            let destinationIDs = Set(tables.flatMap { $0.objects.compactMap { $0.destinationStation?.first } })
            let stationNames = await resolveStationNames(Array(destinationIDs), op: op)
            let now = Date()
            let stored = StoredTimetable(registrationID: station.id, downloadedAt: now, tables: tables,
                                         trainTypeNames: typeNames, stationNames: stationNames)
            timetables[station.id] = stored
            try await timetableStorage.save(stored, key: station.id.uuidString, fetchedAt: now)
        } catch {
            timetableError = error.localizedDescription
        }
    }

    /// 行先の駅名。キャッシュ済みの路線一覧で引けるものは通信しない。
    /// 他社線の駅は公開エンドポイントでは引けないことがあり、その場合はIDの末尾を表示する。
    func resolveStationNames(_ ids: [String], op: TrainOperator) async -> [String: String] {
        var names: [String: String] = [:]
        if let railways = await cache.load([ODPTRailway].self, key: "railways2.\(op.id)")?.value {
            for order in railways.flatMap({ $0.stationOrder ?? [] }) {
                if let name = order.stationTitle?.text { names[order.station] = name }
            }
        }
        let missing = ids.filter { names[$0] == nil }.sorted()
        guard !missing.isEmpty else { return names }
        let endpoint: ODPTEndpoint = hasToken() ? .authenticated : op.endpoint
        if let list = try? await api.stations(ids: missing, endpoint: endpoint) {
            for station in list { names[station.sameAs] = station.name }
        }
        return names
    }

    // MARK: - 永続化

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private enum Keys {
        static let lines = "train.lines"
        static let stations = "train.stations"
        static let routeRailways = "train.routeRailways"
        static let recentSearches = "train.recentStationSearches"
    }
}

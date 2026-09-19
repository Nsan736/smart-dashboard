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
    private(set) var info: CachedValue<[TrainInfoItem]>?
    private(set) var timetables: [UUID: StoredTimetable] = [:]
    private(set) var isLoadingInfo = false
    private(set) var downloadingTimetables: Set<UUID> = []
    private(set) var infoError: String?
    private(set) var timetableError: String?
    private(set) var autoRefreshNote: String?

    @ObservationIgnored let api: ODPTAPI
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private let timetableStorage: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let hasToken: @MainActor () -> Bool
    @ObservationIgnored private let onFetched: @MainActor (DataKind, Date) -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let infoKey = "trainInfo"

    init(api: ODPTAPI, cache: DiskCache, timetableStorage: DiskCache, settings: AppSettings, network: NetworkMonitor,
         hasToken: @escaping @MainActor () -> Bool, onFetched: @escaping @MainActor (DataKind, Date) -> Void,
         defaults: UserDefaults = .standard) {
        self.api = api
        self.cache = cache
        self.timetableStorage = timetableStorage
        self.settings = settings
        self.network = network
        self.hasToken = hasToken
        self.onFetched = onFetched
        self.defaults = defaults
        lines = Self.load([RegisteredLine].self, defaults, Keys.lines) ?? []
        stations = Self.load([RegisteredStation].self, defaults, Keys.stations) ?? []
    }

    func loadIfNeeded() async {
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                self.info = await self.cache.load([TrainInfoItem].self, key: Self.infoKey)
                for station in self.stations {
                    if let stored = await self.timetableStorage.load(StoredTimetable.self, key: station.id.uuidString) {
                        self.timetables[station.id] = stored.value
                    }
                }
            }
        }
        await loadTask?.value
    }

    /// キャッシュ削除のあとに呼ぶ。保存した時刻表は消さない。
    func clearCachedInfo() {
        info = nil
    }

    // MARK: - 登録

    func addLine(_ line: RegisteredLine) {
        guard !lines.contains(where: { $0.railwayID == line.railwayID }) else { return }
        lines.append(line)
        save(lines, Keys.lines)
    }

    func removeLines(at offsets: IndexSet) {
        lines.remove(atOffsets: offsets)
        save(lines, Keys.lines)
        if let info {
            let ids = Set(lines.map(\.railwayID))
            self.info = CachedValue(value: info.value.filter { ids.contains($0.railwayID) }, fetchedAt: info.fetchedAt)
        }
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
    }

    // MARK: - 運行情報

    func refreshInfoIfStale() async {
        await loadIfNeeded()
        guard !lines.isEmpty else { return }
        let cachedIDs = Set(info?.value.map(\.railwayID) ?? [])
        let covered = Set(lines.map(\.railwayID)).isSubset(of: cachedIDs)
        let decision = settings.refreshPolicy.autoDecision(
            kind: .trainInfo, fetchedAt: covered ? info?.fetchedAt : nil, now: Date(), network: network.status)
        autoRefreshNote = decision.note
        if decision == .refresh { await fetchInfo() }
    }

    func refreshInfoManually() async {
        await loadIfNeeded()
        guard !lines.isEmpty else { return }
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
        let grouped = Dictionary(grouping: lines, by: \.operatorID)
        for (operatorID, group) in grouped {
            guard let op = OperatorCatalog.find(operatorID) else { continue }
            do {
                let response = try await api.trainInformation(op: op, railwayIDs: group.map(\.railwayID))
                items += Self.makeItems(lines: group, response: response)
            } catch {
                errors.append(error.localizedDescription)
                // 失敗した事業者の分は前回の値を残す
                items += info?.value.filter { old in group.contains { $0.railwayID == old.railwayID } } ?? []
            }
        }
        if !errors.isEmpty { infoError = errors.joined(separator: "\n") }
        guard errors.count < grouped.count || grouped.isEmpty else { return }
        let order = lines.map(\.railwayID)
        items.sort { (order.firstIndex(of: $0.railwayID) ?? 0) < (order.firstIndex(of: $1.railwayID) ?? 0) }
        let now = Date()
        info = CachedValue(value: items, fetchedAt: now)
        try? await cache.save(items, key: Self.infoKey, fetchedAt: now)
        onFetched(.trainInfo, now)
        autoRefreshNote = nil
    }

    /// 応答に含まれない路線は「情報なし(平常)」として扱う
    nonisolated static func makeItems(lines: [RegisteredLine], response: [ODPTTrainInformation]) -> [TrainInfoItem] {
        lines.map { line in
            let match = response.first { $0.railway == line.railwayID }
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

    func railways(of op: TrainOperator) async throws -> [ODPTRailway] {
        let key = "railways.\(op.id)"
        if let cached = await cache.load([ODPTRailway].self, key: key),
           Date().timeIntervalSince(cached.fetchedAt) < DataKind.railwayCatalog.minimumInterval {
            return cached.value
        }
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

    private func trainTypeNames(of op: TrainOperator) async -> [String: String] {
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
        guard let op = OperatorCatalog.find(station.operatorID) else { return }
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
    private func resolveStationNames(_ ids: [String], op: TrainOperator) async -> [String: String] {
        var names: [String: String] = [:]
        if let railways = await cache.load([ODPTRailway].self, key: "railways.\(op.id)")?.value {
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
    }
}

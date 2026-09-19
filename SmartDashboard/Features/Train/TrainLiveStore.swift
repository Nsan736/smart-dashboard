import CoreLocation
import Foundation
import Observation

/// odpt:Train から得た、列車1本の遅れ
struct LiveDelay: Equatable {
    var seconds: TimeInterval
    var direction: String?
    /// この時刻を過ぎたら使わない (dct:valid)
    var validUntil: Date
}

/// 現在地から一番近い駅(登録した路線の駅の中から)
struct NearestStation: Equatable {
    var railwayID: String
    var stationID: String
    var name: String
    var distance: CLLocationDistance
}

/// 列車ごとの時刻表(端末に保存)と、リアルタイムの遅れを扱う。
/// 電車の位置は時刻表から計算し、リアルタイムのデータからは遅れだけを使う。事業者には依存しない。
@MainActor
@Observable
final class TrainLiveStore {
    private(set) var schedules: [String: LineSchedule] = [:]
    private(set) var downloadingSchedules: Set<String> = []
    private(set) var scheduleError: String?
    /// 路線ID → 列車番号 → 遅れ
    private(set) var delays: [String: [String: LiveDelay]] = [:]
    /// 路線ID → odpt:Train で列車ごとの遅れが取れるか(取得するまではnil)
    private(set) var delaySupport: [String: Bool] = [:]
    private(set) var lastDelayFetch: Date?
    private(set) var isFetchingDelays = false
    private(set) var delayError: String?
    /// 自動取得を見送っている理由(表示用)
    private(set) var autoFetchNote: String?
    private(set) var nearest: NearestStation?
    private(set) var nearestError: String?

    @ObservationIgnored private let api: ODPTAPI
    @ObservationIgnored private let storage: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let trains: TrainStore
    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var visibleReasons: Set<String> = []
    @ObservationIgnored private var nearestLocation: CLLocation?

    /// 1回の応答は1000件で打ち切られる
    static let responseLimit = 1000
    /// カレンダーの候補。事業者によって「土休日」か「土曜」「休日」かが違う。該当がなければ空の応答が返る。
    static let calendarCandidates = ["Weekday", "SaturdayHoliday", "Saturday", "Holiday"]

    init(api: ODPTAPI, storage: DiskCache, settings: AppSettings, network: NetworkMonitor, trains: TrainStore,
         location: LocationProvider, onFetched: @escaping @MainActor (Date) -> Void) {
        self.api = api
        self.storage = storage
        self.settings = settings
        self.network = network
        self.trains = trains
        self.location = location
        self.onFetched = onFetched
    }

    func loadIfNeeded() async {
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                await self.trains.loadIfNeeded()
                for railway in self.trains.neededRailways {
                    if let stored = await self.storage.load(LineSchedule.self, key: railway.railwayID) {
                        self.schedules[railway.railwayID] = stored.value
                    }
                }
            }
        }
        await loadTask?.value
    }

    // MARK: - 列車ごとの時刻表

    /// 保存していない(または30日を過ぎた)路線の時刻表をダウンロードする。
    /// 自動(manual = false)は、従量制でも省データでもない回線(Wi-Fiなど)のときだけ。モバイル通信では手動でだけ実行できる。
    func ensureSchedules(manual: Bool) async {
        await loadIfNeeded()
        let now = Date()
        let targets = trains.neededRailways.filter { schedules[$0.railwayID]?.isExpired(now: now) ?? true }
        // 使わなくなった路線の時刻表は消す
        let needed = Set(trains.neededRailways.map(\.railwayID))
        for id in schedules.keys where !needed.contains(id) {
            schedules[id] = nil
            await storage.remove(key: id)
        }
        guard !targets.isEmpty else { return }
        let allowed = manual ? network.status.isOnline : MapMode.canDownloadTiles(network: network.status)
        guard allowed else { return }
        scheduleError = nil
        for target in targets where !downloadingSchedules.contains(target.railwayID) {
            guard let op = OperatorCatalog.find(target.operatorID) else { continue }
            downloadingSchedules.insert(target.railwayID)
            do {
                let schedule = try await downloadSchedule(railwayID: target.railwayID, op: op)
                if schedule.trains.isEmpty {
                    scheduleError = "この路線では列車ごとの時刻表が提供されていません"
                } else {
                    schedules[target.railwayID] = schedule
                    try? await storage.save(schedule, key: target.railwayID, fetchedAt: schedule.downloadedAt)
                }
            } catch {
                scheduleError = error.localizedDescription
            }
            downloadingSchedules.remove(target.railwayID)
        }
    }

    private func downloadSchedule(railwayID: String, op: TrainOperator) async throws -> LineSchedule {
        var tables: [ODPTTrainTimetable] = []
        for name in Self.calendarCandidates {
            let calendarID = "odpt.Calendar:\(name)"
            let list = try await api.trainTimetables(railwayID: railwayID, calendarID: calendarID, directionID: nil, op: op)
            if list.count >= Self.responseLimit {
                // 打ち切られているので、方面ごとに取り直す
                let directions = Set(list.compactMap(\.railDirection))
                for direction in directions.sorted() {
                    tables += try await api.trainTimetables(railwayID: railwayID, calendarID: calendarID, directionID: direction, op: op)
                }
            } else {
                tables += list
            }
        }
        let railway = try? await trains.railways(of: op).first { $0.sameAs == railwayID }
        let ordered = (railway?.stationOrder ?? []).sorted { $0.index < $1.index }.map(\.station)
        let typeNames = await trains.trainTypeNames(of: op)
        let destinations = Set(tables.compactMap { $0.destinationStation?.first })
        let stationNames = await trains.resolveStationNames(Array(destinations), op: op)
        let downloaded = tables
        // 数MBのJSONから作るので、メインスレッドの外で組み立てる
        return await Task.detached(priority: .utility) {
            LineSchedule(railwayID: railwayID, downloadedAt: Date(), orderedStationIDs: ordered, timetables: downloaded,
                         trainTypeNames: typeNames, stationNames: stationNames)
        }.value
    }

    func redownloadSchedules() async {
        for id in schedules.keys { await storage.remove(key: id) }
        schedules = [:]
        await ensureSchedules(manual: true)
    }

    // MARK: - 遅れ(リアルタイム)

    /// 電車タブやホームの電車カードが表示されている間だけ、遅れを自動取得する
    func setVisible(_ reason: String, _ isVisible: Bool) {
        if isVisible { visibleReasons.insert(reason) } else { visibleReasons.remove(reason) }
        if visibleReasons.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        } else if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.fetchDelaysIfDue()
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
        }
    }

    /// 最短の間隔(Wi-Fiで2分、モバイル通信で5分)を過ぎていて、自動更新が許されているときだけ取得する。
    /// 省データモードのとき、月のモバイル通信量の上限を超えたときは、手動更新だけになる。
    func fetchDelaysIfDue() async {
        guard !trains.neededRailways.isEmpty else { return }
        let now = Date()
        let decision = settings.refreshPolicy.autoDecision(kind: .trainDelay, fetchedAt: lastDelayFetch, now: now, network: network.status)
        autoFetchNote = decision.note
        guard decision == .refresh else { return }
        if let lastDelayFetch, now.timeIntervalSince(lastDelayFetch) < RefreshPolicy.trainDelayInterval(network: network.status) { return }
        await fetchDelays()
    }

    func fetchDelaysManually() async {
        guard network.status.isOnline else {
            delayError = "オフラインのため更新できません"
            return
        }
        await fetchDelays()
    }

    private func fetchDelays() async {
        guard !isFetchingDelays else { return }
        isFetchingDelays = true
        defer { isFetchingDelays = false }
        delayError = nil
        let now = Date()
        // 事業者ごとに1リクエスト。登録した路線だけに絞る。
        let grouped = Dictionary(grouping: trains.neededRailways, by: \.operatorID)
        for (operatorID, group) in grouped {
            guard let op = OperatorCatalog.find(operatorID) else { continue }
            let railwayIDs = group.map(\.railwayID)
            do {
                let response = try await api.trains(op: op, railwayIDs: railwayIDs)
                let parsed = Self.parseDelays(response, railwayIDs: railwayIDs, now: now)
                for id in railwayIDs {
                    delays[id] = parsed.delays[id] ?? [:]
                    delaySupport[id] = parsed.support[id] ?? false
                }
            } catch {
                delayError = error.localizedDescription
            }
        }
        lastDelayFetch = now
        onFetched(now)
    }

    /// 応答から遅れだけを取り出す。遅れの項目を持つ列車が1本もない路線は「列車ごとの遅れは取れない」とする。
    nonisolated static func parseDelays(_ response: [ODPTTrain], railwayIDs: [String], now: Date)
        -> (delays: [String: [String: LiveDelay]], support: [String: Bool]) {
        let formatter = ISO8601DateFormatter()
        var delays: [String: [String: LiveDelay]] = [:]
        var support: [String: Bool] = [:]
        for id in railwayIDs { support[id] = false }
        for train in response {
            guard let seconds = train.delay else { continue }
            support[train.railway] = true
            let valid = train.valid.flatMap { formatter.date(from: $0) } ?? now.addingTimeInterval(5 * 60)
            delays[train.railway, default: [:]][train.trainNumber] = LiveDelay(seconds: seconds, direction: train.railDirection, validUntil: valid)
        }
        return (delays, support)
    }

    /// 位置の計算に渡す、有効な遅れ(列車番号 → 秒)
    func activeDelays(for railwayID: String, now: Date) -> [String: TimeInterval] {
        (delays[railwayID] ?? [:]).filter { $0.value.validUntil >= now }.mapValues(\.seconds)
    }

    /// 今の列車の位置。時刻表から計算し、遅れの分だけ補正する。
    /// 列車ごとの遅れが取れない路線では、運行情報で遅延・見合わせがあれば「路線で遅延あり」とする。
    func positions(for railwayID: String, now: Date, includesWaiting: Bool = false) -> [TrainPosition] {
        guard let schedule = schedules[railwayID] else { return [] }
        let status = trains.info?.value.first { $0.railwayID == railwayID }?.status
        let lineIsDelayed = status == .delay || status == .suspended
        return TrainPositionCalculator.positions(
            in: schedule, now: now, resolver: settings.dayTypeResolver,
            delays: activeDelays(for: railwayID, now: now), lineIsDelayed: lineIsDelayed, includesWaiting: includesWaiting)
    }

    // MARK: - 最寄り駅

    /// 電車タブを開いたときに呼ぶ。現在地は100m精度で1回だけ取得し、前回から500m以上動いたときだけ判定し直す。
    func updateNearestStation() async {
        await trains.loadIfNeeded()
        do {
            let current = try await location.currentLocation()
            nearestError = nil
            if let nearestLocation, nearest != nil, current.distance(from: nearestLocation) < 500 { return }
            nearestLocation = current
            nearest = Self.nearestStation(to: current, shapes: Array(trains.shapes.values))
        } catch {
            nearestError = error.localizedDescription
        }
    }

    nonisolated static func nearestStation(to location: CLLocation, shapes: [RailwayShape]) -> NearestStation? {
        var best: NearestStation?
        for shape in shapes {
            for stop in shape.stops {
                let distance = location.distance(from: CLLocation(latitude: stop.latitude, longitude: stop.longitude))
                if best == nil || distance < best!.distance {
                    best = NearestStation(railwayID: shape.railwayID, stationID: stop.stationID, name: stop.name, distance: distance)
                }
            }
        }
        return best
    }
}

import Foundation
import Observation

/// 検出した路線
struct DetectedRailway: Codable, Equatable, Identifiable {
    var id: String
    var operatorID: String
    var name: String
    /// 路線の色 (odpt:color、例 "#FF535F")。ない路線もある。
    var colorHex: String?
    /// 駅の数(odpt:stationOrder)
    var stationCount: Int
    var capabilities: ODPTCapabilities
}

/// 検出した事業者(使えるデータがあるものだけ)
struct DetectedOperator: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var endpoint: ODPTEndpoint
    var railways: [DetectedRailway]
    var capabilities: ODPTCapabilities
}

/// 検出の対象から外した事業者と、その理由
struct ExcludedOperator: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var reason: String
}

/// 事業者の検出の結果。30日間使い、キャッシュの削除では消さない(登録した路線の事業者を引くのに使うため)。
struct OperatorDiscoveryResult: Codable, Equatable {
    /// 検出に使ったエンドポイント(トークンがなければ、または無効なら公開エンドポイント)
    var endpoint: ODPTEndpoint
    var detectedAt: Date
    var operators: [DetectedOperator]
    var excluded: [ExcludedOperator]
    /// 路線の応答(駅の順・色・方面)。登録の画面の路線の一覧と駅の一覧に使い、取り直さない。
    var railwayData: [ODPTRailway]
    var requestCount: Int
    /// 検出にかかった時間(秒)
    var duration: Double

    static let validFor: TimeInterval = 30 * 24 * 60 * 60

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(detectedAt) > Self.validFor || detectedAt > now
    }

    var railwayCount: Int { operators.reduce(0) { $0 + $1.railways.count } }
}

/// 事業者の検出の手順(通信しない部分)。1回の検出は10リクエスト前後。
/// カンマ区切りの絞り込みは1回に10件まで(ODPTQuery.maxORValues)なので、それを超えるときは分けて問い合わせる。
///
/// 1. 事業者の一覧 (odpt:Operator)。チャレンジ限定のライセンスの事業者は、この時点で外す。
/// 2. 路線 (odpt:Railway)。絞り込まずに全件を1回で取り、対象の事業者の路線だけを使う。バス・航空の事業者は路線がないので、ここで落ちる。
/// 3. 運行情報 (odpt:TrainInformation) と 4. 列車 (odpt:Train) を、路線のある事業者に絞って。
/// 5. 各路線の最初の駅だけの odpt:Station(owl:sameAs)。駅の位置と、駅時刻表のIDの有無が分かる。
/// 6. 走っている列車がない事業者だけ、駅時刻表を1つ(owl:sameAs)。列車のIDを得るため。
/// 7. 事業者ごとに2本までの列車の odpt:TrainTimetable(odpt:train)。返れば列車ごとの時刻表が使える。
/// どれかの段階が失敗したら、そこで中止する(あとの段階を0件として扱わない)。
enum OperatorDetection {
    /// ある事業者の列車が1本もないとき、「列車ごとの遅れは提供されていない」と判断してよい時間帯(日本時間)。
    /// 深夜・早朝は走っていないだけのことがあるので、未確認にする。
    static let daytimeHours = 7..<22
    /// 列車時刻表の確認に使う、事業者ごとの列車の数
    static let trainsPerOperator = 2

    /// 1. 検出の対象の事業者(チャレンジ限定の事業者を外す)
    static func candidates(_ operators: [ODPTOperator]) -> (ids: [String], excluded: [ExcludedOperator]) {
        var ids: [String] = []
        var excluded: [ExcludedOperator] = []
        for op in operators {
            if let name = OperatorCatalog.challengeOnly[op.sameAs] {
                excluded.append(ExcludedOperator(id: op.sameAs, name: op.operatorTitle?.ja ?? name, reason: OperatorCatalog.challengeOnlyReason))
            } else {
                ids.append(op.sameAs)
            }
        }
        return (ids.sorted(), excluded)
    }

    /// 5. 駅の確認に使う駅(路線ごとに最初の駅)
    static func probeStationIDs(_ railways: [ODPTRailway]) -> [String] {
        let ids = railways.compactMap { railway in
            (railway.stationOrder ?? []).min { $0.index < $1.index }?.station
        }
        return Array(Set(ids)).sorted()
    }

    /// 6. 駅時刻表の確認に使うID。走っている列車がない事業者ごとに1つ(平日を優先)。
    static func probeStationTimetableIDs(stations: [ODPTStation], operatorsWithTrains: Set<String>) -> [String] {
        var chosen: [String: String] = [:]
        for station in stations.sorted(by: { $0.sameAs < $1.sameAs }) {
            guard let op = ODPTID.operatorID(of: station.sameAs), !operatorsWithTrains.contains(op), chosen[op] == nil else { continue }
            let refs = station.stationTimetables ?? []
            if let ref = refs.first(where: { $0.hasSuffix(".Weekday") }) ?? refs.first { chosen[op] = ref }
        }
        return chosen.values.sorted()
    }

    /// 7. 列車時刻表の確認に使う列車のID。事業者ごとに2本まで(走っている列車を優先し、なければ駅時刻表の列車)。
    static func probeTrainIDs(trains: [ODPTTrain], stationTimetables: [ODPTStationTimetable]) -> [String] {
        var chosen: [String: [String]] = [:]
        func add(_ id: String, operatorID: String?) {
            guard let op = operatorID ?? ODPTID.operatorID(of: id) else { return }
            var list = chosen[op] ?? []
            guard list.count < trainsPerOperator, !list.contains(id) else { return }
            list.append(id)
            chosen[op] = list
        }
        for train in trains {
            if let id = train.sameAs { add(id, operatorID: train.operatorID) }
        }
        for table in stationTimetables {
            // 始発や終電の前後は臨時の列車のことがあるので、真ん中あたりの列車を使う
            let ids = table.objects.compactMap(\.train)
            let middle = ids.count / 2
            for id in ids[middle..<min(ids.count, middle + trainsPerOperator)] {
                add(id, operatorID: ODPTID.operatorID(of: table.sameAs))
            }
        }
        return chosen.values.flatMap { $0 }.sorted()
    }

    /// 取得した結果から、事業者・路線ごとに使えるデータを決める
    static func evaluate(endpoint: ODPTEndpoint, operators: [ODPTOperator], excluded: [ExcludedOperator], railways: [ODPTRailway],
                         information: [ODPTTrainInformation], trains: [ODPTTrain], stations: [ODPTStation],
                         trainTimetables: [ODPTTrainTimetable], now: Date, requestCount: Int, duration: Double) -> OperatorDiscoveryResult {
        let hour = JapaneseHolidays.calendar.component(.hour, from: now)
        let absenceMeansNone = !trains.isEmpty && daytimeHours.contains(hour)
        let infoRailways = Set(information.compactMap(\.railway))
        // 路線を持たない運行情報(事業者全体のお知らせ)は、その事業者のすべての路線に使う
        let infoOperators = Set(information.filter { $0.railway == nil }.map(\.operatorID))
        let trainsByRailway = Dictionary(grouping: trains, by: \.railway)
        let stationsByID = Dictionary(stations.map { ($0.sameAs, $0) }, uniquingKeysWith: { first, _ in first })
        let timetableOperators = Set(trainTimetables.compactMap { $0.operatorID ?? ODPTID.operatorID(of: $0.sameAs) })
        let names = Dictionary(operators.map { ($0.sameAs, $0.name) }, uniquingKeysWith: { first, _ in first })
        let byOperator = Dictionary(grouping: railways, by: \.operatorID)

        var found: [DetectedOperator] = []
        var skipped = excluded
        for (operatorID, list) in byOperator {
            if OperatorCatalog.challengeOnly[operatorID] != nil { continue }
            let override = OperatorCatalog.override(operatorID)
            let name = override?.name ?? names[operatorID] ?? ODPTID.tail(operatorID)
            let detected = list.map { railway -> DetectedRailway in
                let order = (railway.stationOrder ?? []).sorted { $0.index < $1.index }
                let first = order.first.flatMap { stationsByID[$0.station] }
                var caps = ODPTCapabilities()
                caps.trainInformation = infoRailways.contains(railway.sameAs) || infoOperators.contains(operatorID)
                caps.trainTimetable = timetableOperators.contains(operatorID)
                caps.stationTimetable = !(first?.stationTimetables ?? []).isEmpty
                caps.stationLocation = first?.latitude != nil && first?.longitude != nil
                let running = trainsByRailway[railway.sameAs] ?? []
                if running.contains(where: { $0.delay != nil }) {
                    caps.delay = true
                } else if !running.isEmpty || absenceMeansNone {
                    caps.delay = false
                }
                return DetectedRailway(id: railway.sameAs, operatorID: operatorID, name: railway.name, colorHex: railway.color,
                                       stationCount: order.count, capabilities: caps)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let caps = ODPTCapabilities.union(detected.map(\.capabilities))
            guard caps.isUsable else {
                let reason = caps.stationLocation ? "駅の位置だけで、運行情報・時刻表が提供されていません" : "運行情報・時刻表・駅の位置が提供されていません"
                skipped.append(ExcludedOperator(id: operatorID, name: name, reason: reason))
                continue
            }
            found.append(DetectedOperator(id: operatorID, name: name, endpoint: override?.endpoint ?? endpoint,
                                          railways: detected, capabilities: caps))
        }
        let sortedFound = OperatorCatalog.sorted(found.map { TrainOperator(id: $0.id, name: $0.name, endpoint: $0.endpoint) })
            .compactMap { op in found.first { $0.id == op.id } }
        let usedRailways = Set(found.flatMap { $0.railways.map(\.id) })
        return OperatorDiscoveryResult(
            endpoint: endpoint, detectedAt: now, operators: sortedFound,
            excluded: skipped.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            railwayData: railways.filter { usedRailways.contains($0.sameAs) }.sorted { $0.sameAs < $1.sameAs },
            requestCount: requestCount, duration: duration)
    }
}

/// 検出の結果と予備の定義をまとめた、事業者の一覧(通信しない)
enum OperatorDirectory {
    /// 検出した事業者と、検出できていない予備の事業者。
    /// 予備は、公開エンドポイントの事業者(都営)と、トークンがあるのに検出がまだの間の、トークンが必要な事業者。
    static func merge(result: OperatorDiscoveryResult?, hasToken: Bool) -> [TrainOperator] {
        var list = (result?.operators ?? []).map {
            TrainOperator(id: $0.id, name: $0.name, endpoint: $0.endpoint, capabilities: $0.capabilities, railways: $0.railways)
        }
        let ids = Set(list.map(\.id))
        let excludedIDs = Set(result?.excluded.map(\.id) ?? [])
        for op in OperatorCatalog.fallback where !ids.contains(op.id) && !excludedIDs.contains(op.id) {
            if op.endpoint == .publicAPI || (hasToken && result?.endpoint != .authenticated) { list.append(op) }
        }
        return OperatorCatalog.sorted(list)
    }

    /// 事業者を引く。一覧にない(検出の前や、トークンを消したあとに残った登録)ときも、上書きの定義かIDから作って返す。
    static func resolve(_ id: String, in list: [TrainOperator]) -> TrainOperator {
        if let op = list.first(where: { $0.id == id }) { return op }
        let override = OperatorCatalog.override(id)
        return TrainOperator(id: id, name: override?.name ?? ODPTID.tail(id), endpoint: override?.endpoint ?? .authenticated, isFallback: true)
    }

    /// 路線の使えるデータ。検出していない路線は nil(すべて使えるものとして試す)。
    static func capabilities(ofRailway id: String, in list: [TrainOperator]) -> ODPTCapabilities? {
        for op in list {
            if let railway = op.railways.first(where: { $0.id == id }) { return railway.capabilities }
        }
        return nil
    }
}

/// 事業者の自動検出。トークンを保存したときと「再検出」のボタンで調べ、30日間使う。
/// 期限が切れたときの自動の検出は、従量制でない回線(Wi-Fiなど)のときだけ。
@MainActor
@Observable
final class OperatorDiscoveryStore {
    enum Failure: Equatable {
        case invalidToken
        /// ある段階が失敗して中止した。url は失敗したリクエスト(トークンを除く)。
        case stopped(stage: String, detail: String, url: String?)
        case other(String)

        var message: String {
            switch self {
            case .invalidToken:
                return "ODPTのアクセストークンが無効か、期限が切れています。ODPTのサイトで確かめて、入力し直してください。都営などトークンが要らない事業者は、そのまま使えます。"
            case let .stopped(stage, detail, _):
                return "\(stage)が取れなかったため、検出を中止しました(前回の結果はそのまま使います)。\(detail)"
            case .other(let text): return "事業者を検出できませんでした: \(text)"
            }
        }

        var url: String? {
            if case let .stopped(_, _, url) = self { return url }
            return nil
        }
    }

    /// 検出の段階の失敗
    struct StageFailure: Error {
        var stage: String
        var detail: String
        var url: String?
    }

    private(set) var result: OperatorDiscoveryResult?
    /// 検出の結果と予備の定義をまとめた一覧
    private(set) var operators: [TrainOperator] = OperatorDirectory.merge(result: nil, hasToken: false)
    private(set) var isDetecting = false
    private(set) var failure: Failure?
    /// 自動の検出を見送っている理由(「Wi-Fi接続時に検出します」)
    private(set) var note: String?
    /// トークンが保存されているか(AppEnvironment が setHasToken で設定する)
    private(set) var hasToken = false

    @ObservationIgnored private let api: ODPTAPI
    @ObservationIgnored private let storage: DiskCache
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let onFetched: @MainActor (Date) -> Void
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// 検出を保存したあとに呼ぶ(駅と路線の検索の一覧を、Wi-Fiなら続けて取得する)
    @ObservationIgnored var onDetected: (@MainActor () -> Void)?

    private static let storageKey = "operatorDiscovery"

    init(api: ODPTAPI, storage: DiskCache, settings: AppSettings, network: NetworkMonitor, hasToken: Bool,
         onFetched: @escaping @MainActor (Date) -> Void) {
        self.api = api
        self.storage = storage
        self.settings = settings
        self.network = network
        self.hasToken = hasToken
        self.onFetched = onFetched
        rebuild()
    }

    func loadIfNeeded() async {
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self else { return }
                if let stored = await self.storage.load(OperatorDiscoveryResult.self, key: Self.storageKey), self.result == nil {
                    self.result = stored.value
                    self.rebuild()
                }
            }
        }
        await loadTask?.value
    }

    /// 検出し直す必要があるか(結果がない、30日を過ぎた、トークンの有無と検出したエンドポイントが合わない)
    func needsDetection(now: Date = Date()) -> Bool {
        guard let result else { return true }
        if result.isExpired(now: now) { return true }
        // トークンを入れたのに、公開エンドポイントでしか検出していない(無効なトークンのときは、再検出のボタンで)
        if hasToken, result.endpoint == .publicAPI, failure != .invalidToken { return true }
        if !hasToken, result.endpoint == .authenticated { return true }
        return false
    }

    /// 起動時・登録の画面を開いたときに呼ぶ。必要なときだけ、従量制でない回線で検出する。
    func detectIfNeeded() async {
        await loadIfNeeded()
        guard needsDetection() else {
            note = nil
            return
        }
        guard MapMode.canDownloadTiles(network: network.status) else {
            note = network.status.isOnline ? "Wi-Fi接続時に検出します" : nil
            return
        }
        await detect(manual: false)
    }

    /// トークンを保存したときと「再検出」のボタン。オンラインなら、モバイル通信でも検出する(1回あたり数十KB)。
    func detect(manual: Bool) async {
        await loadIfNeeded()
        guard !isDetecting else { return }
        if manual, settings.refreshPolicy.manualDecision(network: network.status) != .refresh {
            failure = .other("オフラインです")
            return
        }
        isDetecting = true
        defer { isDetecting = false }
        failure = nil
        note = nil
        let endpoint: ODPTEndpoint = hasToken ? .authenticated : .publicAPI
        do {
            try await store(run(endpoint))
        } catch ODPTError.unauthorized {
            failure = .invalidToken
            // 公開エンドポイントの事業者(都営など)は、トークンがなくても使えるようにしておく
            if let found = try? await run(.publicAPI) { try? await store(found) }
        } catch let stop as StageFailure {
            failure = .stopped(stage: stop.stage, detail: stop.detail, url: stop.url)
        } catch {
            failure = .other(error.localizedDescription)
        }
    }

    /// 検出の1つの段階。失敗したら、段階の名前と、失敗したリクエストのURL・応答の本文を付けて中止する。
    private func step<T>(_ stage: String, _ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch ODPTError.unauthorized {
            throw ODPTError.unauthorized
        } catch let error as ODPTError {
            throw StageFailure(stage: stage, detail: error.localizedDescription, url: error.requestURL)
        } catch {
            throw StageFailure(stage: stage, detail: error.localizedDescription, url: nil)
        }
    }

    private func store(_ found: OperatorDiscoveryResult) async throws {
        result = found
        rebuild()
        try await storage.save(found, key: Self.storageKey, fetchedAt: found.detectedAt)
        onFetched(found.detectedAt)
        onDetected?()
    }

    private func run(_ endpoint: ODPTEndpoint) async throws -> OperatorDiscoveryResult {
        let started = Date()
        var requests = 0
        let operators = try await step("事業者の一覧") { try await api.operators(endpoint: endpoint) }
        requests += 1
        guard !operators.isEmpty else { throw StageFailure(stage: "事業者の一覧", detail: "応答が空でした。", url: nil) }
        let candidates = OperatorDetection.candidates(operators)
        let allRailways = try await step("路線の一覧") { try await api.railways(endpoint: endpoint) }
        requests += 1
        let candidateIDs = Set(candidates.ids)
        let railways = allRailways.filter { candidateIDs.contains($0.operatorID) }
        guard !railways.isEmpty else { throw StageFailure(stage: "路線の一覧", detail: "対象の事業者の路線が1つもありませんでした。", url: nil) }
        let railOperators = Array(Set(railways.map(\.operatorID))).sorted()
        let information = try await step("運行情報") { try await api.trainInformation(operatorIDs: railOperators, endpoint: endpoint) }
        let trains = try await step("列車の情報") { try await api.trains(operatorIDs: railOperators, endpoint: endpoint) }
        requests += ODPTQuery.chunks(railOperators).count * 2
        let stationIDs = OperatorDetection.probeStationIDs(railways)
        let stations = try await step("駅") { try await api.stations(ids: stationIDs, endpoint: endpoint) }
        requests += ODPTQuery.chunks(stationIDs).count
        let operatorsWithTrains = Set(trains.compactMap { $0.operatorID ?? ODPTID.operatorID(of: $0.railway) })
        let tableIDs = OperatorDetection.probeStationTimetableIDs(stations: stations, operatorsWithTrains: operatorsWithTrains)
        let tables = try await step("駅の時刻表") { try await api.stationTimetables(ids: tableIDs, endpoint: endpoint) }
        requests += ODPTQuery.chunks(tableIDs).count
        let trainIDs = OperatorDetection.probeTrainIDs(trains: trains, stationTimetables: tables)
        let timetables = try await step("列車の時刻表") { try await api.trainTimetables(trainIDs: trainIDs, endpoint: endpoint) }
        requests += ODPTQuery.chunks(trainIDs).count
        let now = Date()
        return OperatorDetection.evaluate(
            endpoint: endpoint, operators: operators, excluded: candidates.excluded, railways: railways,
            information: information, trains: trains, stations: stations, trainTimetables: timetables,
            now: now, requestCount: requests, duration: now.timeIntervalSince(started))
    }

    func setHasToken(_ value: Bool) {
        guard value != hasToken else { return }
        hasToken = value
        rebuild()
    }

    private func rebuild() {
        operators = OperatorDirectory.merge(result: result, hasToken: hasToken)
    }

    // MARK: - 引く

    func operatorInfo(_ id: String) -> TrainOperator {
        OperatorDirectory.resolve(id, in: operators)
    }

    /// 路線の使えるデータ。検出していない路線は nil。
    func capabilities(ofRailway id: String) -> ODPTCapabilities? {
        OperatorDirectory.capabilities(ofRailway: id, in: operators)
    }

    /// 検出のときに取得した路線の応答(30日以内のものだけ)。登録の画面で取り直さないために使う。
    func railwayData(of operatorID: String, now: Date = Date()) -> [ODPTRailway]? {
        guard let result, !result.isExpired(now: now), result.operators.contains(where: { $0.id == operatorID }) else { return nil }
        let list = result.railwayData.filter { $0.operatorID == operatorID }
        return list.isEmpty ? nil : list
    }
}

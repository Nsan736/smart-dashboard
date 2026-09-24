import Foundation

/// 位置の記録の1点。実際のGPSでも、デバッグの仮想の移動でも同じ形。
struct RideSample: Codable, Equatable {
    var time: Date
    var latitude: Double
    var longitude: Double
    /// 水平精度(m)。分からなければ負の値
    var accuracy: Double
    /// 端末が出した速さ(m/s)。無効なら負の値
    var speed: Double

    init(time: Date, latitude: Double, longitude: Double, accuracy: Double = -1, speed: Double = -1) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.speed = speed
    }

    init(time: Date, point: GeoPoint, accuracy: Double = -1, speed: Double = -1) {
        self.init(time: time, latitude: point.latitude, longitude: point.longitude, accuracy: accuracy, speed: speed)
    }

    var point: GeoPoint { GeoPoint(latitude, longitude) }

    enum CodingKeys: String, CodingKey {
        case time = "t"
        case latitude = "a"
        case longitude = "o"
        case accuracy = "h"
        case speed = "v"
    }
}

enum RideConfidence: Int, Comparable {
    case low
    case medium
    case high

    static func < (lhs: RideConfidence, rhs: RideConfidence) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        }
    }
}

/// 判定の途中の値(デバッグの表示用)
struct RideDebugInfo: Equatable {
    struct Candidate: Equatable {
        var trainID: String
        var label: String
        /// 自分の位置との、線に沿った距離(m)
        var distance: Double
    }

    var raw: GeoPoint?
    var rawAccuracy: Double?
    var projected: GeoPoint?
    /// 線までの距離(m)
    var lateral: Double?
    /// 線に沿った速さ(m/s)。駅の順に進むときは正。
    var alongSpeed: Double?
    /// 条件が続いている時間(秒)
    var continued: TimeInterval = 0
    var candidates: [Candidate] = []
    /// 駅で止まった回数と、駅以外で長く止まった回数
    var stationStops = 0
    var offStationStops = 0
}

/// 乗車中の判定の結果
struct RideJudgement: Equatable {
    enum State: Equatable {
        /// 判定の機能がオフ
        case off
        /// 条件を満たしていない
        case idle
        /// 条件を満たし始めた(まだ判定は出さない)
        case candidate
        /// 乗車中の可能性あり
        case riding
        /// GPSが途切れ、直前に判定した列車の時刻表で位置を推定している
        case estimating
    }

    var state: State = .idle
    var railwayID: String?
    /// 駅の順(線の始点 → 終点)に進んでいるか
    var isAscending: Bool?
    /// 線に沿った位置(m)。推定中は列車の位置。
    var along: Double?
    var trainID: String?
    /// 照合した列車との距離(m)
    var trainDistance: Double?
    var confidence: RideConfidence?
    /// 手動で選んだ列車
    var isManual = false
    /// 条件を満たし始めた時刻
    var since: Date?
    var lastFix: Date?
    /// GPSが戻ったときの、推定の位置との差(m)
    var answerCheck: Double?
    /// 判定をやり直した理由など
    var note: String?
    var debug = RideDebugInfo()

    var isRiding: Bool { state == .riding || state == .estimating }
}

/// 判定に渡す、その時点の路線と列車
struct RideContext {
    var lines: [RideLine]
    var trains: [RideTrainCandidate]
}

/// 移動の記録から「今乗っている電車」を判定する。CoreLocation にも画面にも依存しない。
///
/// 流れ:
/// 1. 位置を一番近い路線の線に投影し、線までの距離と、線に沿った速さを求める
/// 2. 線の近く(100m以内)を、線に沿って一定以上の速さ(時速15km以上)で動いている状態が30秒続いたら「乗車中の可能性あり」
/// 3. 進んでいる向きの列車(時刻表から計算し、遅れで補正した位置)のうち、一番近いものを照合する
/// 4. 駅以外で長く止まったら(信号待ちの車など)、判定をやり直し、次は駅での停止を見るまで判定を出さない
/// 5. GPSが途切れたら、照合した列車の時刻表の位置で推定を続け、位置が戻ったら答え合わせをする
struct RideDetector {
    struct Config: Equatable {
        /// 線からこの距離以内なら「線の近く」
        var maxLateral = 100.0
        /// 線に沿った速さの下限(m/s)。時速15km
        var minSpeed = 15.0 / 3.6
        /// 条件がこの時間続いたら判定を出す
        var requiredDuration: TimeInterval = 30
        /// 条件が一時的に崩れても(カーブでの測位のぶれなど)、この時間は続いていることにする
        var grace: TimeInterval = 15
        /// 止まっているとみなす速さ(m/s)
        var stopSpeed = 1.5
        /// 駅からこの距離以内で止まったら、駅での停止
        var stationRadius = 250.0
        /// 駅での停止として数える長さ
        var stationStopMinimum: TimeInterval = 8
        /// 駅以外でこの時間以上止まったら、電車らしくないとして判定をやり直す
        var offStationStopLimit: TimeInterval = 25
        /// 駅以外で止まったあと、駅での停止を見るまで判定を出さない時間
        var suspicionPeriod: TimeInterval = 600
        /// 照合する列車までの距離の上限(m)
        var trainMatchDistance = 1500.0
        /// この時間、位置が届かなければ「GPSなし」
        var gpsLostAfter: TimeInterval = 20
        /// 推定を続ける上限
        var maxEstimate: TimeInterval = 30 * 60
        /// 精度がこれより悪い位置は使わない(m)
        var maxAccuracy = 80.0
        /// 線に沿った速さを求める期間
        var speedWindow: TimeInterval = 12
    }

    private struct Entry {
        var time: Date
        var along: Double
        var lateral: Double
    }

    var config = Config()
    private(set) var judgement = RideJudgement()

    private var railwayID: String?
    private var history: [Entry] = []
    private var candidateSince: Date?
    private var lastSatisfied: Date?
    private var lateralSum = 0.0
    private var lateralCount = 0
    private var direction: Bool?
    private var lastAlong: Double?
    private var lastFix: Date?
    private var stopStart: Date?
    private var stopAtStation = false
    private var stopCounted = false
    private var stationStops = 0
    private var offStationStops = 0
    /// 駅以外で止まった時刻。ここから suspicionPeriod の間は、駅での停止を見るまで判定を出さない。
    private var suspicionSince: Date?
    private var stationStopsAtSuspicion = 0
    private var lockedTrainID: String?
    private var manualTrainID: String?
    private var estimatedAlong: Double?
    private var note: String?

    init(config: Config = Config()) {
        self.config = config
    }

    /// 手動で列車を選ぶ(nil で自動に戻す)
    mutating func selectTrain(_ trainID: String?) {
        manualTrainID = trainID
        if trainID == nil { lockedTrainID = nil }
    }

    var manualSelection: String? { manualTrainID }

    /// すべてを最初からにする
    mutating func reset() {
        self = RideDetector(config: config)
    }

    /// 位置を1点加える
    @discardableResult
    mutating func add(_ sample: RideSample, context: RideContext) -> RideJudgement {
        // 精度の悪い点は使わない(位置が届いていないのと同じに扱う)
        if sample.accuracy >= 0, sample.accuracy > config.maxAccuracy {
            return tick(now: sample.time, context: context)
        }
        let point = sample.point
        var best: (line: RideLine, projection: TrackProjection)?
        for line in context.lines {
            guard let projection = line.path.project(point) else { continue }
            if best == nil || projection.lateral < best!.projection.lateral { best = (line, projection) }
        }
        // 判定中の路線の近くにいる間は、その路線を使い続ける(乗換駅などで別の路線に飛ばないように)
        if let current = railwayID, let line = context.lines.first(where: { $0.railwayID == current }),
           let projection = line.path.project(point), projection.lateral <= config.maxLateral {
            best = (line, projection)
        }
        var debug = RideDebugInfo()
        debug.raw = point
        debug.rawAccuracy = sample.accuracy >= 0 ? sample.accuracy : nil
        let previousState = judgement.state
        let wasEstimating = previousState == .estimating
        let estimate = estimatedAlong
        lastFix = sample.time
        guard let best else {
            clearDetection()
            var result = RideJudgement(state: .idle)
            result.lastFix = sample.time
            result.debug = debug
            judgement = result
            return result
        }
        if best.line.railwayID != railwayID {
            clearDetection()
            railwayID = best.line.railwayID
        }
        let projection = best.projection
        debug.projected = projection.point
        debug.lateral = projection.lateral

        // GPSが戻ったら、推定していた位置と答え合わせをする
        var answerCheck: Double?
        if wasEstimating, let estimate {
            let gap = abs(projection.along - estimate)
            answerCheck = gap
            if gap > config.trainMatchDistance, manualTrainID == nil { lockedTrainID = nil }
        }
        if wasEstimating {
            // 途切れる前の点では速さを求められないので、戻った直後は条件が続いていることにする
            history = []
            lastSatisfied = sample.time
        }
        estimatedAlong = nil

        history.append(Entry(time: sample.time, along: projection.along, lateral: projection.lateral))
        history.removeAll { sample.time.timeIntervalSince($0.time) > 60 }
        let alongSpeed = Self.alongSpeed(history, now: sample.time, window: config.speedWindow)
        debug.alongSpeed = alongSpeed
        let near = projection.lateral <= config.maxLateral
        let moving = alongSpeed.map { abs($0) >= config.minSpeed } ?? false
        let stopped = alongSpeed.map { abs($0) < config.stopSpeed } ?? false
        if moving, let alongSpeed { direction = alongSpeed > 0 }
        lastAlong = projection.along

        // 止まっている間の扱い: 駅なら数え、駅以外で長く止まったら判定をやり直す
        if near, stopped {
            if stopStart == nil {
                stopStart = sample.time
                stopAtStation = best.line.nearestStation(toAlong: projection.along).map { $0.distance <= config.stationRadius } ?? false
                stopCounted = false
            }
            let duration = sample.time.timeIntervalSince(stopStart ?? sample.time)
            if stopAtStation {
                if !stopCounted, duration >= config.stationStopMinimum {
                    stationStops += 1
                    stopCounted = true
                }
            } else if !stopCounted, duration >= config.offStationStopLimit {
                offStationStops += 1
                stopCounted = true
                suspicionSince = sample.time
                stationStopsAtSuspicion = stationStops
                if candidateSince != nil {
                    resetCandidate()
                    note = "駅以外で止まったため(並行する道路の可能性)、判定をやり直します"
                }
            }
        } else {
            stopStart = nil
        }

        let satisfied = near && moving
        // 駅で止まっている間は、条件が続いていることにする
        let holding = near && stopped && stopAtStation && stopStart != nil
        if satisfied {
            if candidateSince == nil {
                candidateSince = sample.time
                lateralSum = 0
                lateralCount = 0
                note = nil
            }
            lastSatisfied = sample.time
            lateralSum += projection.lateral
            lateralCount += 1
        } else if holding {
            if candidateSince != nil { lastSatisfied = sample.time }
        } else if let last = lastSatisfied, sample.time.timeIntervalSince(last) > config.grace {
            if candidateSince != nil, previousState == .riding || previousState == .estimating {
                note = near ? "線に沿った動きが止まったため、判定を終えました" : "線から離れたため、判定を終えました"
            }
            resetCandidate()
        }

        var result = evaluate(now: sample.time, context: context, along: projection.along, debug: debug)
        result.answerCheck = answerCheck
        judgement = result
        return result
    }

    /// 位置が届かなくても毎秒呼ぶ。列車の位置の更新と、GPSが途切れたときの推定を行う。
    @discardableResult
    mutating func tick(now: Date, context: RideContext) -> RideJudgement {
        guard let lastFix else { return judgement }
        let silence = now.timeIntervalSince(lastFix)
        if silence > config.gpsLostAfter {
            if judgement.state == .riding || judgement.state == .estimating {
                guard silence <= config.maxEstimate,
                      let trainID = manualTrainID ?? lockedTrainID,
                      let train = context.trains.first(where: { $0.id == trainID }) else {
                    let debug = judgement.debug
                    clearDetection()
                    note = "GPSが途切れ、列車を特定できていないため、判定を止めました"
                    var result = RideJudgement(state: .idle)
                    result.note = note
                    result.lastFix = lastFix
                    result.debug = debug
                    judgement = result
                    return result
                }
                // 直前に判定した列車の時刻表で、位置の推定を続ける
                estimatedAlong = train.along
                var result = judgement
                result.state = .estimating
                result.along = train.along
                result.trainID = train.id
                result.trainDistance = nil
                if let ascending = train.isAscending { result.isAscending = ascending }
                result.lastFix = lastFix
                result.debug.continued = now.timeIntervalSince(candidateSince ?? now)
                judgement = result
                return result
            }
            if judgement.state == .candidate {
                resetCandidate()
                var result = RideJudgement(state: .idle)
                result.lastFix = lastFix
                result.debug = judgement.debug
                judgement = result
            }
            return judgement
        }
        guard judgement.state == .riding || judgement.state == .candidate, let along = lastAlong else { return judgement }
        // 列車の位置は時間とともに動くので、照合だけやり直す
        let result = evaluate(now: now, context: context, along: along, debug: judgement.debug)
        judgement = result
        return result
    }

    // MARK: - 内部

    private mutating func evaluate(now: Date, context: RideContext, along: Double, debug: RideDebugInfo) -> RideJudgement {
        var debug = debug
        debug.stationStops = stationStops
        debug.offStationStops = offStationStops
        var result = RideJudgement()
        result.lastFix = lastFix
        result.note = note
        guard let railwayID, let since = candidateSince else {
            result.state = .idle
            result.debug = debug
            return result
        }
        let continued = now.timeIntervalSince(since)
        debug.continued = continued
        result.railwayID = railwayID
        result.isAscending = direction
        result.along = along
        result.since = since

        // 候補の列車(進む向きが同じもの)
        let pool = context.trains.filter { train in
            guard train.railwayID == railwayID else { return false }
            guard let direction, let ascending = train.isAscending else { return true }
            return ascending == direction
        }
        let ranked = pool.map { (train: $0, distance: abs($0.along - along)) }.sorted { $0.distance < $1.distance }
        debug.candidates = ranked.prefix(4).map { RideDebugInfo.Candidate(trainID: $0.train.id, label: $0.train.label, distance: $0.distance) }

        var enough = continued >= config.requiredDuration
        if let suspicionSince, now.timeIntervalSince(suspicionSince) < config.suspicionPeriod, stationStops <= stationStopsAtSuspicion {
            // 駅以外で止まったあとは、駅での停止を見るまで判定を出さない
            enough = false
            if result.note == nil { result.note = "駅での停止を確認するまで判定を保留しています" }
        }
        guard enough else {
            result.state = .candidate
            result.debug = debug
            return result
        }
        result.state = .riding

        // 列車の照合
        if let manual = manualTrainID, let train = context.trains.first(where: { $0.id == manual }) {
            result.trainID = train.id
            result.trainDistance = abs(train.along - along)
            result.isManual = true
        } else {
            if manualTrainID != nil { manualTrainID = nil }
            let locked = ranked.first { $0.train.id == lockedTrainID }
            let nearest = ranked.first
            if let locked, locked.distance <= config.trainMatchDistance * 1.5,
               !(nearest.map { $0.train.id != locked.train.id && $0.distance < locked.distance * 0.5 } ?? false) {
                result.trainID = locked.train.id
                result.trainDistance = locked.distance
            } else if let nearest, nearest.distance <= config.trainMatchDistance {
                lockedTrainID = nearest.train.id
                result.trainID = nearest.train.id
                result.trainDistance = nearest.distance
            } else {
                lockedTrainID = nil
            }
        }
        result.confidence = confidence(continued: continued, trainDistance: result.trainDistance)
        result.debug = debug
        return result
    }

    /// 確からしさ。線までの距離、列車との近さ、駅での停止、続いた時間から点数を付ける。
    private func confidence(continued: TimeInterval, trainDistance: Double?) -> RideConfidence {
        var score = 0
        let averageLateral = lateralCount > 0 ? lateralSum / Double(lateralCount) : .infinity
        if averageLateral <= 35 { score += 2 } else if averageLateral <= 70 { score += 1 }
        if let trainDistance {
            if trainDistance <= 400 { score += 2 } else if trainDistance <= config.trainMatchDistance { score += 1 }
        }
        if stationStops > 0 { score += 1 }
        if continued >= 120 { score += 1 }
        if offStationStops > 0 { score -= 1 }
        if score >= 5 { return .high }
        if score >= 3 { return .medium }
        return .low
    }

    /// 条件の継続だけをやり直す(駅での停止などの記録は残す)
    private mutating func resetCandidate() {
        candidateSince = nil
        lastSatisfied = nil
        lateralSum = 0
        lateralCount = 0
        if manualTrainID == nil { lockedTrainID = nil }
        estimatedAlong = nil
    }

    /// 路線が変わったときなど、判定の材料をすべて捨てる
    private mutating func clearDetection() {
        resetCandidate()
        railwayID = nil
        history = []
        direction = nil
        lastAlong = nil
        stopStart = nil
        stationStops = 0
        offStationStops = 0
        suspicionSince = nil
        stationStopsAtSuspicion = 0
        manualTrainID = nil
        lockedTrainID = nil
    }

    /// 線に沿った速さ(m/s)。window 秒前ごろの点との差から求める(5秒以上の間隔が必要)。
    static func alongSpeed(_ history: [(time: Date, along: Double)], now: Date, window: TimeInterval) -> Double? {
        guard let last = history.last else { return nil }
        guard let base = history.first(where: { now.timeIntervalSince($0.time) <= window }) else { return nil }
        let dt = last.time.timeIntervalSince(base.time)
        guard dt >= 5 else { return nil }
        return (last.along - base.along) / dt
    }

    private static func alongSpeed(_ history: [Entry], now: Date, window: TimeInterval) -> Double? {
        alongSpeed(history.map { (time: $0.time, along: $0.along) }, now: now, window: window)
    }
}

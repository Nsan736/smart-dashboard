import Foundation

/// 測位1回分。CoreLocationに依存しない形にして、テストしやすくする。
struct SpeedSample: Equatable {
    var latitude: Double
    var longitude: Double
    /// CLLocation.speed。負は無効。
    var speed: Double
    /// CLLocation.speedAccuracy。負は無効。
    var speedAccuracy: Double
    /// CLLocation.horizontalAccuracy。負は無効。
    var horizontalAccuracy: Double
    var timestamp: Date
}

enum SpeedSource: Equatable {
    /// GPSが報告した速度
    case reported
    /// 位置の差分から計算した速度
    case derived
    /// 歩行ペース(CMPedometer の currentPace)から推定した速度。屋内や地下など、GPSで動きを検出できないときに使う。
    case pedometer
    /// 位置の差分が測位の誤差に埋もれていて、歩数の更新もないので、停止中とみなした
    case stationary
}

/// 画面に出す速度と、その求め方
struct SpeedReading: Equatable {
    /// m/s。求められないときはnil(「測位中…」)。
    var speed: Double?
    var source: SpeedSource?
}

/// リアルタイムの速度と、画面を開いてからの最高速度・平均速度・移動距離を求める。
/// 無効な値と精度の悪い点は計算から除外する。
struct SpeedEstimator: Equatable {
    /// これより水平精度の悪い点は使わない(m)
    static let maxHorizontalAccuracy = 50.0
    /// GPSの速度を信用する速度精度の上限(m/s)
    static let maxSpeedAccuracy = 3.0
    /// 差分の計算に使う区間の長さ(秒)
    static let derivationWindow: TimeInterval = 8
    static let minimumDerivationInterval: TimeInterval = 2
    /// 平滑化に使う点数
    static let smoothingCount = 3
    /// 最後の有効な測位からこれ以上たったら「測位中」に戻す(秒)
    static let staleAfter: TimeInterval = 6
    /// 停止中の揺らぎを距離に入れないための下限(m/s)
    static let movingThreshold = 0.5
    /// 歩行ペースを有効とみなす時間(秒)。CMPedometer の更新は数秒おきに届き、立ち止まると届かなくなる。
    static let paceValidFor: TimeInterval = 10
    /// 歩行ペースから求める速度の上限(m/s)。異常値よけ。
    static let maxPedometerSpeed = 7.0

    /// 平滑化した現在の速度(m/s)。求められないときはnil。
    private(set) var currentSpeed: Double?
    private(set) var source: SpeedSource?
    private(set) var lastFix: SpeedSample?
    private(set) var maxSpeed = 0.0
    private(set) var distance = 0.0
    private(set) var movingTime: TimeInterval = 0

    private var fixes: [SpeedSample] = []
    private var recentSpeeds: [Double] = []
    /// 最後に速度を求められた時刻
    private var lastSpeedAt: Date?
    /// 歩行ペースから求めた速度と、その時刻
    private var paceSpeed: Double?
    private var paceAt: Date?
    private var lastPedometerSteps: Int?
    private var lastPedometerDistance: Double?
    private var lastPedometerAt: Date?

    /// 平均速度(m/s)。動いていた時間に対する平均。
    var averageSpeed: Double { movingTime > 0 ? distance / movingTime : 0 }

    static func isGoodFix(_ sample: SpeedSample) -> Bool {
        sample.horizontalAccuracy >= 0 && sample.horizontalAccuracy <= maxHorizontalAccuracy
    }

    static func hasReliableSpeed(_ sample: SpeedSample) -> Bool {
        sample.speed >= 0 && sample.speedAccuracy >= 0 && sample.speedAccuracy <= maxSpeedAccuracy
    }

    mutating func add(_ sample: SpeedSample) {
        guard Self.isGoodFix(sample) else {
            expireIfStale(now: sample.timestamp)
            return
        }
        if let last = lastFix, sample.timestamp <= last.timestamp { return }

        var raw: Double?
        var rawSource: SpeedSource?
        if Self.hasReliableSpeed(sample) {
            raw = sample.speed
            rawSource = .reported
        } else if let derived = derivedSpeed(to: sample) {
            raw = derived
            rawSource = .derived
        }

        let previous = lastFix
        fixes.append(sample)
        fixes.removeAll { sample.timestamp.timeIntervalSince($0.timestamp) > Self.derivationWindow }
        lastFix = sample

        guard let raw, let rawSource else {
            expireIfStale(now: sample.timestamp)
            return
        }
        lastSpeedAt = sample.timestamp
        recentSpeeds.append(raw)
        if recentSpeeds.count > Self.smoothingCount { recentSpeeds.removeFirst(recentSpeeds.count - Self.smoothingCount) }
        var smoothed = recentSpeeds.reduce(0, +) / Double(recentSpeeds.count)
        if smoothed < 0.3 { smoothed = 0 }
        currentSpeed = smoothed
        source = rawSource

        // 画面を開いてからの統計。動いているときの、連続した良い測位だけを足す。
        if let previous {
            let dt = sample.timestamp.timeIntervalSince(previous.timestamp)
            if dt > 0, dt <= 10, smoothed >= Self.movingThreshold {
                distance += Self.distance(previous, sample)
                movingTime += dt
            }
        }
        maxSpeed = max(maxSpeed, smoothed)
    }

    // MARK: - 表示する速度の選択

    /// GPSによる速度(報告値か、位置の差分)。測位が途絶えていたらnil。
    private func gpsSpeed(now: Date) -> (speed: Double, source: SpeedSource)? {
        guard let lastSpeedAt, now.timeIntervalSince(lastSpeedAt) <= Self.staleAfter,
              let currentSpeed, let source else { return nil }
        return (currentSpeed, source)
    }

    private func pedometerSpeed(now: Date) -> Double? {
        guard let paceSpeed, let paceAt, now.timeIntervalSince(paceAt) <= Self.paceValidFor,
              now.timeIntervalSince(paceAt) >= -1 else { return nil }
        return paceSpeed
    }

    /// 優先順位:
    /// 1. GPSが報告した速度(速度精度が十分で、動いているとき)
    /// 2. 位置の差分から計算した速度(測位の誤差より十分大きく移動しているとき)
    /// 3. 歩行ペースから推定した速度(直近に歩数の更新があるとき)
    /// 4. GPSは測位できているが動きを検出できないとき、停止中として0。測位もできていなければnil
    ///
    /// 乗り物では歩数が増えないので3にはならず、GPSの値を使う。
    /// GPSの報告値がほぼ0で、歩数が増えているとき(屋内で速度精度だけ良い場合など)は、歩行ペースを優先する。
    func reading(now: Date) -> SpeedReading {
        let gps = gpsSpeed(now: now)
        if let gps, gps.source == .reported, gps.speed >= Self.movingThreshold {
            return SpeedReading(speed: gps.speed, source: .reported)
        }
        if let gps, gps.source == .derived, gps.speed > 0 {
            return SpeedReading(speed: gps.speed, source: .derived)
        }
        if let pace = pedometerSpeed(now: now) {
            return SpeedReading(speed: pace, source: .pedometer)
        }
        if let gps {
            return SpeedReading(speed: gps.speed, source: gps.source == .reported ? .reported : .stationary)
        }
        return SpeedReading(speed: nil, source: nil)
    }

    // MARK: - 歩数計

    /// CMPedometer の更新を渡す。steps と distance は今日の累計、secondsPerMeter は currentPace。
    /// GPSで動きが取れている区間では統計に足さない(二重に数えない)。
    mutating func addPedometer(steps: Int, distance: Double?, secondsPerMeter: Double?, at now: Date) {
        let previousAt = lastPedometerAt
        let previousDistance = lastPedometerDistance
        let stepsIncreased = lastPedometerSteps.map { steps > $0 } ?? true
        lastPedometerSteps = steps
        lastPedometerAt = now
        if let distance { lastPedometerDistance = distance }

        guard stepsIncreased, let pace = secondsPerMeter, pace > 0, pace.isFinite else {
            // 歩数が増えていない、またはペースが出ていない = 歩いていない
            paceSpeed = nil
            paceAt = nil
            return
        }
        let speed = min(1 / pace, Self.maxPedometerSpeed)
        paceSpeed = speed
        paceAt = now

        let gpsIsMoving = (gpsSpeed(now: now)?.speed ?? 0) >= Self.movingThreshold
        guard !gpsIsMoving else { return }
        maxSpeed = max(maxSpeed, speed)
        guard let previousAt else { return }
        let dt = now.timeIntervalSince(previousAt)
        guard dt > 0, dt <= 15 else { return }
        // 歩数計の距離の増分があればそれを使い、なければペースから求める
        var moved = speed * dt
        if let distance, let previousDistance, distance >= previousDistance {
            moved = min(distance - previousDistance, speed * dt * 2)
        }
        self.distance += moved
        movingTime += dt
    }

    /// 測位が途絶えたときに呼ぶ。古い速度を表示し続けない。
    mutating func expireIfStale(now: Date) {
        guard let lastSpeedAt else { return }
        if now.timeIntervalSince(lastSpeedAt) > Self.staleAfter {
            currentSpeed = nil
            source = nil
            recentSpeeds = []
        }
    }

    mutating func resetStatistics() {
        maxSpeed = 0
        distance = 0
        movingTime = 0
    }

    /// 直近の区間の最初の点から今回の点までの移動から速度を求める。
    /// 移動が測位の誤差より小さいときは、止まっているとみなして0にする。
    private func derivedSpeed(to sample: SpeedSample) -> Double? {
        guard let first = fixes.first(where: {
            let dt = sample.timestamp.timeIntervalSince($0.timestamp)
            return dt >= Self.minimumDerivationInterval && dt <= Self.derivationWindow
        }) else { return nil }
        let dt = sample.timestamp.timeIntervalSince(first.timestamp)
        let moved = Self.distance(first, sample)
        if moved < max(first.horizontalAccuracy, sample.horizontalAccuracy) * 0.5 { return 0 }
        return moved / dt
    }

    /// 2点間の距離(m)。球面三角法(haversine)。
    static func distance(_ a: SpeedSample, _ b: SpeedSample) -> Double {
        let radius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, h.squareRoot()))
    }
}

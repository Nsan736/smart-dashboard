import Foundation

/// 気圧計(CMAltimeter)で実測した値
struct PressureSample: Codable, Equatable {
    var time: Date
    var hPa: Double
    /// アプリがバックグラウンドにいる間に記録した値か
    var inBackground: Bool = false
}

/// 予報の気圧(Open-Meteo の hourly surface_pressure)
struct PressureForecastPoint: Equatable {
    var time: Date
    var hPa: Double
}

/// 実測の記録のルール。5分に1回記録し、48時間分だけ残す。
enum PressureLog {
    static let interval: TimeInterval = 5 * 60
    static let retention: TimeInterval = 48 * 3600

    static func shouldRecord(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        // 時計が戻された場合も記録する
        return elapsed >= interval || elapsed < 0
    }

    static func trimmed(_ samples: [PressureSample], now: Date) -> [PressureSample] {
        samples.filter { now.timeIntervalSince($0.time) <= retention && $0.time <= now.addingTimeInterval(60) }
    }
}

/// グラフの1点
struct PressurePoint: Equatable, Identifiable {
    enum Source: Equatable {
        case measured
        case forecast
    }

    var time: Date
    var hPa: Double
    var source: Source
    var id: Date { time }
}

/// 実測と予報をつないだ、過去24時間〜今後24時間の気圧
struct PressureSeries: Equatable {
    var points: [PressurePoint]
    /// 予報の値に足した補正(hPa)。実測がなければ0。
    var correction: Double
    var hasMeasured: Bool

    /// 実測がこの時間より離れている時間帯は予報で埋める
    static let gapTolerance: TimeInterval = 30 * 60
    static let window: TimeInterval = 24 * 3600

    /// - 実測がある時間帯は実測を使う
    /// - 実測がない時間帯(アプリを閉じていた間と未来)は予報で埋める
    /// - 境目で段差にならないよう、予報の全体に「直近の実測 − 同じ時刻の予報」を足す
    ///   (予報は地表の気圧で、端末のある高さとの差はほぼ一定なので、全体を同じ量だけずらす)
    static func make(measured: [PressureSample], forecast: [PressureForecastPoint], now: Date) -> PressureSeries {
        let from = now.addingTimeInterval(-window)
        let to = now.addingTimeInterval(window)
        let samples = measured.filter { $0.time >= from && $0.time <= now }.sorted { $0.time < $1.time }
        let model = forecast.sorted { $0.time < $1.time }
        var correction = 0.0
        if let last = samples.last, let modelValue = interpolate(model, at: last.time) {
            correction = last.hPa - modelValue
        }
        var points = samples.map { PressurePoint(time: $0.time, hPa: $0.hPa, source: .measured) }
        for point in model where point.time >= from && point.time <= to {
            let hasNearbySample = samples.contains { abs($0.time.timeIntervalSince(point.time)) <= gapTolerance }
            if !hasNearbySample {
                points.append(PressurePoint(time: point.time, hPa: point.hPa + correction, source: .forecast))
            }
        }
        points.sort { $0.time < $1.time }
        return PressureSeries(points: points, correction: correction, hasMeasured: !samples.isEmpty)
    }

    /// 1時間ごとの予報を線形に補間する。範囲の外は nil。
    static func interpolate(_ forecast: [PressureForecastPoint], at time: Date) -> Double? {
        guard let first = forecast.first, let last = forecast.last, time >= first.time, time <= last.time else { return nil }
        for index in 1..<max(forecast.count, 1) {
            let a = forecast[index - 1]
            let b = forecast[index]
            if time >= a.time && time <= b.time {
                let span = b.time.timeIntervalSince(a.time)
                guard span > 0 else { return a.hPa }
                return a.hPa + (b.hPa - a.hPa) * time.timeIntervalSince(a.time) / span
            }
        }
        return first.hPa
    }

    /// タップした位置に一番近い点
    func nearest(to time: Date) -> PressurePoint? {
        points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}

/// 「今後3時間の変化」
struct PressureChange: Equatable {
    var hours: Int
    var delta: Double
    /// 起点が実測か(なければ予報)
    var baseIsMeasured: Bool

    static let freshness: TimeInterval = 30 * 60

    /// 起点は最新の実測(30分以内)。なければ、補正した予報の現在の値。終点は、補正した予報の hours 時間後の値。
    static func make(measured: [PressureSample], forecast: [PressureForecastPoint], now: Date, hours: Int = 3) -> PressureChange? {
        let model = forecast.sorted { $0.time < $1.time }
        let series = PressureSeries.make(measured: measured, forecast: model, now: now)
        guard let target = PressureSeries.interpolate(model, at: now.addingTimeInterval(Double(hours) * 3600)) else { return nil }
        let latest = measured.filter { $0.time <= now }.max { $0.time < $1.time }
        if let latest, now.timeIntervalSince(latest.time) <= freshness {
            return PressureChange(hours: hours, delta: target + series.correction - latest.hPa, baseIsMeasured: true)
        }
        guard let base = PressureSeries.interpolate(model, at: now) else { return nil }
        return PressureChange(hours: hours, delta: target - base, baseIsMeasured: false)
    }

    /// 設定した値以上に下がる予報か(threshold は正の値。例: 4 → −4hPa以下で true)
    func isAlert(threshold: Double) -> Bool {
        delta <= -abs(threshold)
    }

    var text: String {
        let value = abs(delta) < 0.05 ? "±0.0" : String(format: "%+.1f", delta).replacingOccurrences(of: "-", with: "−")
        return "今後\(hours)時間の変化：\(value)hPa"
    }
}

/// バックグラウンドで実際に記録できていたかを、記録の時刻から判定する
enum BackgroundRecordingCheck: String, Codable {
    /// バックグラウンドにいた時間が短く、判定できない
    case tooShort
    case recorded
    case notRecorded

    /// 判定に必要な、バックグラウンドにいた時間の下限(記録の間隔の3倍)
    static let minimumDuration: TimeInterval = 15 * 60

    /// アプリを閉じていた間([start, end])に、5分おきの記録が続いていたか。
    /// 期待される回数の半分以上あれば「記録できた」とみなす。
    static func verdict(backgroundStart: Date, end: Date, sampleTimes: [Date]) -> BackgroundRecordingCheck {
        let duration = end.timeIntervalSince(backgroundStart)
        guard duration >= minimumDuration else { return .tooShort }
        let count = sampleTimes.filter { $0 > backgroundStart.addingTimeInterval(60) && $0 < end }.count
        let expected = Int(duration / PressureLog.interval)
        return count * 2 >= max(expected, 1) ? .recorded : .notRecorded
    }
}

/// バックグラウンドでの記録を止める理由
enum BackgroundStopReason: Equatable {
    case disabled
    case lowBattery
    case lowPowerMode
    case audioFailed

    var text: String {
        switch self {
        case .disabled: return "設定がオフ"
        case .lowBattery: return "電池残量が20%未満"
        case .lowPowerMode: return "低電力モード"
        case .audioFailed: return "オーディオを開始できませんでした"
        }
    }

    /// 動かしてよいかを決める。止めるなら理由を返す。batteryLevel は 0〜1、不明なら負の値。
    static func decide(enabled: Bool, batteryLevel: Float, isLowPowerMode: Bool) -> BackgroundStopReason? {
        if !enabled { return .disabled }
        if isLowPowerMode { return .lowPowerMode }
        if batteryLevel >= 0 && batteryLevel < 0.2 { return .lowBattery }
        return nil
    }
}

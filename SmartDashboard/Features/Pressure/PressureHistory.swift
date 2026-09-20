import Foundation

/// 端末に保存する、予報モデルの気圧(過去約100日〜7日先、1時間ごと)。1地点の分だけを持つ。
struct PressureHistory: Codable, Equatable {
    struct Point: Codable, Equatable {
        var time: Date
        var hPa: Double
    }

    var latitude: Double
    var longitude: Double
    /// 時刻の昇順。同じ時刻は1つだけ。
    var points: [Point]
    /// 過去の分をまとめて取得した時刻。nil なら未取得。
    var backfilledAt: Date?

    static let retention: TimeInterval = 100 * 24 * 3600
    /// これ以上離れた地点に変わったら、保存した分を捨てて取り直す(気圧は標高で大きく変わるため、別の地点の値とはつなげない)
    static let relocationDistanceKm = 50.0
    /// 通常の更新(天気の更新と、7日先までの予報の取得)で埋められる空白の上限
    static let maxIncrementalGap: TimeInterval = 7 * 24 * 3600

    static func empty(latitude: Double, longitude: Double) -> PressureHistory {
        PressureHistory(latitude: latitude, longitude: longitude, points: [], backfilledAt: nil)
    }

    /// 新しく取得した値を足す。同じ時刻は新しい値で置き換え、100日より古いものは捨てる(未来の分は残す)。
    func merged(with new: [Point], now: Date) -> PressureHistory {
        var byTime: [Date: Double] = [:]
        byTime.reserveCapacity(points.count + new.count)
        for point in points { byTime[point.time] = point.hPa }
        for point in new { byTime[point.time] = point.hPa }
        let limit = now.addingTimeInterval(-Self.retention)
        var result = self
        result.points = byTime.filter { $0.key >= limit }.map { Point(time: $0.key, hPa: $0.value) }.sorted { $0.time < $1.time }
        return result
    }

    /// 保存済みの、現在までの最後の時刻
    func lastPastTime(now: Date) -> Date? {
        points.last { $0.time <= now }?.time
    }

    /// 保存済みの最後の時刻から現在までの空白(秒)。保存がなければ nil。
    func gap(now: Date) -> TimeInterval? {
        lastPastTime(now: now).map { now.timeIntervalSince($0) }
    }

    /// 足りない分だけを取るための past_hours(24〜168)
    func neededPastHours(now: Date) -> Int {
        guard let gap = gap(now: now) else { return 24 }
        return min(max(Int(gap / 3600) + 2, 24), 168)
    }

    /// 過去の分をまとめて取り直す必要があるか(未取得、または空白が7日を超えた)
    func needsBackfill(now: Date) -> Bool {
        guard backfilledAt != nil, let gap = gap(now: now) else { return true }
        return gap > Self.maxIncrementalGap
    }

    func isFar(latitude: Double, longitude: Double) -> Bool {
        Self.distanceKm(latitude, longitude, self.latitude, self.longitude) > Self.relocationDistanceKm
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad
        let dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 6371 * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    var forecastPoints: [PressureForecastPoint] {
        points.map { PressureForecastPoint(time: $0.time, hPa: $0.hPa) }
    }
}

/// Open-Meteo の応答のうち、1時間ごとの気圧だけを読む(過去の分の取得用)
struct OpenMeteoPressureResponse: Decodable {
    struct Hourly: Decodable {
        let time: [TimeInterval]
        let surface_pressure: [Double?]
    }

    let hourly: Hourly

    /// 欠損(null)は捨てる
    var points: [PressureHistory.Point] {
        zip(hourly.time, hourly.surface_pressure).compactMap { time, value in
            value.map { PressureHistory.Point(time: Date(timeIntervalSince1970: time), hPa: $0) }
        }
    }
}

enum PressureRequests {
    private static func base(_ host: String, latitude: Double, longitude: Double) -> URLComponents {
        var c = URLComponents(string: "https://\(host)/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "hourly", value: "surface_pressure"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return c
    }

    /// 過去100日分。Forecast API の past_days=92 は古い約19日分が欠損(null)で返る(2026-09-20に確認)ので、
    /// 同じ変数を欠損なしで返す Historical Forecast API を使う。
    static func backfillURL(latitude: Double, longitude: Double, now: Date) -> URL {
        var c = base("historical-forecast-api.open-meteo.com", latitude: latitude, longitude: longitude)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd"
        c.queryItems?.append(URLQueryItem(name: "start_date", value: formatter.string(from: now.addingTimeInterval(-99 * 24 * 3600))))
        c.queryItems?.append(URLQueryItem(name: "end_date", value: formatter.string(from: now)))
        return c.url!
    }

    /// 足りない過去の分(24〜168時間)と、7日先までの予報
    static func outlookURL(latitude: Double, longitude: Double, pastHours: Int) -> URL {
        var c = base("api.open-meteo.com", latitude: latitude, longitude: longitude)
        c.queryItems?.append(URLQueryItem(name: "past_hours", value: String(pastHours)))
        c.queryItems?.append(URLQueryItem(name: "forecast_hours", value: "168"))
        return c.url!
    }
}

/// 表示する期間に応じた間引き
enum PressureThinning {
    /// step 秒ごとの区切りにまとめ、区切りごとに平均(時刻も値も)を1点にする。区切りの中に実測があれば実測だけを使う。
    /// points は時刻の昇順。
    static func thin(_ points: [PressurePoint], step: TimeInterval) -> [PressurePoint] {
        guard step > 0 else { return points }
        var result: [PressurePoint] = []
        var bucket: [PressurePoint] = []
        var bucketIndex = Int.min
        func flush() {
            guard !bucket.isEmpty else { return }
            let measured = bucket.filter { $0.source == .measured }
            let used = measured.isEmpty ? bucket : measured
            let mean = used.map(\.hPa).reduce(0, +) / Double(used.count)
            let time = Date(timeIntervalSince1970: used.map(\.time.timeIntervalSince1970).reduce(0, +) / Double(used.count))
            result.append(PressurePoint(time: time, hPa: mean, source: measured.isEmpty ? .forecast : .measured))
        }
        for point in points {
            let index = Int((point.time.timeIntervalSince1970 / step).rounded(.down))
            if index != bucketIndex {
                flush()
                bucket = []
                bucketIndex = index
            }
            bucket.append(point)
        }
        flush()
        return result
    }
}

/// 値の読み取りと、急な低下の区間
enum PressureAnalysis {
    /// 時刻の昇順の点を線形に補間する。範囲の外は nil。
    static func value(in points: [PressurePoint], at time: Date) -> Double? {
        guard let first = points.first, let last = points.last, time >= first.time, time <= last.time else { return nil }
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].time <= time { low = mid } else { high = mid }
        }
        let a = points[low]
        let b = points[high]
        let span = b.time.timeIntervalSince(a.time)
        guard span > 0 else { return a.hPa }
        return a.hPa + (b.hPa - a.hPa) * time.timeIntervalSince(a.time) / span
    }

    /// 時刻の昇順の点から、一番近い点を探す(二分探索)
    static func nearest(in points: [PressurePoint], to time: Date) -> PressurePoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].time <= time { low = mid } else { high = mid }
        }
        return abs(points[low].time.timeIntervalSince(time)) <= abs(points[high].time.timeIntervalSince(time)) ? points[low] : points[high]
    }

    /// その時刻までの hours 時間の変化(hPa)
    static func change(in points: [PressurePoint], at time: Date, hours: Double = 3) -> Double? {
        guard let now = value(in: points, at: time),
              let before = value(in: points, at: time.addingTimeInterval(-hours * 3600)) else { return nil }
        return now - before
    }

    /// 気圧が急に下がっている時間帯(その時刻までの3時間で threshold hPa 以上の低下)。
    /// step ごとに調べ、続いている区間を1つにまとめる。区間は、下がり始め(3時間前)から含める。
    static func dropIntervals(in points: [PressurePoint], threshold: Double, hours: Double = 3, step: TimeInterval = 1800) -> [DateInterval] {
        guard let first = points.first, let last = points.last, threshold > 0 else { return [] }
        var intervals: [DateInterval] = []
        var time = first.time.addingTimeInterval(hours * 3600)
        while time <= last.time {
            if let delta = change(in: points, at: time, hours: hours), delta <= -threshold {
                let start = time.addingTimeInterval(-hours * 3600)
                if let current = intervals.last, start <= current.end {
                    intervals[intervals.count - 1] = DateInterval(start: current.start, end: max(current.end, time))
                } else {
                    intervals.append(DateInterval(start: start, end: time))
                }
            }
            time = time.addingTimeInterval(step)
        }
        return intervals
    }
}

/// 表示中の期間の最高・最低・平均と、1日ごとの最高・最低
struct PressureStats: Equatable {
    struct Day: Equatable, Identifiable {
        var date: Date
        var high: Double
        var low: Double
        var id: Date { date }
    }

    var high: Double
    var low: Double
    var mean: Double
    var days: [Day]

    static func make(_ points: [PressurePoint], from: Date, to: Date, calendar: Calendar = .current) -> PressureStats? {
        let visible = points.filter { $0.time >= from && $0.time <= to }
        guard let high = visible.map(\.hPa).max(), let low = visible.map(\.hPa).min() else { return nil }
        var byDay: [Date: (high: Double, low: Double)] = [:]
        for point in visible {
            let day = calendar.startOfDay(for: point.time)
            let current = byDay[day] ?? (point.hPa, point.hPa)
            byDay[day] = (max(current.high, point.hPa), min(current.low, point.hPa))
        }
        let days = byDay.map { Day(date: $0.key, high: $0.value.high, low: $0.value.low) }.sorted { $0.date > $1.date }
        return PressureStats(high: high, low: low, mean: visible.map(\.hPa).reduce(0, +) / Double(visible.count), days: days)
    }
}

import Foundation

/// 太陽か月
enum SkyBody: String, Codable, CaseIterable, Identifiable {
    case sun
    case moon

    var id: String { rawValue }
    var label: String { self == .sun ? "太陽" : "月" }

    func horizontal(_ date: Date, latitude: Double, longitude: Double) -> Astronomy.Horizontal {
        self == .sun ? Astronomy.sunHorizontal(date, latitude: latitude, longitude: longitude)
            : Astronomy.moonHorizontal(date, latitude: latitude, longitude: longitude)
    }

    func semidiameter(_ date: Date) -> Double {
        self == .sun ? Astronomy.sunSemidiameter(date) : Astronomy.moonSemidiameter(date)
    }
}

/// 出・入りなどの時刻と方角
struct SkyEvent: Equatable {
    var date: Date
    var azimuth: Double
}

/// 1日の出入りの計算(国立天文台の暦計算室と同じ決め方: 地平線での屈折を 35′08″、日の出入りは太陽の上の縁、月の出入りは月の中心)
enum SkyEvents {
    /// 地平線での屈折(度)
    static let horizonRefraction = 35.0 / 60 + 8.0 / 3600

    /// 出入りの判定の高さ(屈折を考えない高さが、これを超えたら出ている)
    static func threshold(_ body: SkyBody, date: Date) -> Double {
        body == .sun ? -(horizonRefraction + body.semidiameter(date)) : -horizonRefraction
    }

    /// 日本時間の、その日の0時
    static func startOfDay(_ date: Date, calendar: Calendar = .japan) -> Date {
        calendar.startOfDay(for: date)
    }

    /// value(t) が 0 を下から上へ(rising)、上から下へ横切る時刻。10分ごとに調べて、二分法で1秒まで詰める
    static func crossings(from start: Date, to end: Date, step: TimeInterval = 600, rising: Bool,
                          value: (Date) -> Double) -> [Date] {
        var result: [Date] = []
        var previousTime = start
        var previous = value(start)
        var time = start
        while time < end {
            time = min(time.addingTimeInterval(step), end)
            let current = value(time)
            if rising ? (previous < 0 && current >= 0) : (previous > 0 && current <= 0) {
                var low = previousTime, high = time
                let lowValue = previous
                while high.timeIntervalSince(low) > 1 {
                    let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    if (value(middle) < 0) == (lowValue < 0) { low = middle } else { high = middle }
                }
                result.append(low.addingTimeInterval(high.timeIntervalSince(low) / 2))
            }
            previousTime = time
            previous = current
        }
        return result
    }

    /// その日(日本時間)の出と入り(地平線で)
    static func riseSet(_ body: SkyBody, on day: Date, latitude: Double, longitude: Double) -> (rise: SkyEvent?, set: SkyEvent?) {
        let start = startOfDay(day)
        let end = start.addingTimeInterval(86_400)
        let value: (Date) -> Double = { date in
            body.horizontal(date, latitude: latitude, longitude: longitude).altitude - threshold(body, date: date)
        }
        let event: (Date) -> SkyEvent = { SkyEvent(date: $0, azimuth: body.horizontal($0, latitude: latitude, longitude: longitude).azimuth) }
        let rise = crossings(from: start, to: end, rising: true, value: value).first.map(event)
        let set = crossings(from: start, to: end, rising: false, value: value).first.map(event)
        return (rise, set)
    }

    /// 本当の日の出・日の入り: 景色の稜線(方角ごとの見える高さ)に、太陽の上の縁が隠れる・出てくる時刻。
    /// horizon(方角) は、その方角の稜線の見える高さ(度)。分からない方角は nil(そのときは求めない)
    static func terrainRiseSet(_ body: SkyBody, on day: Date, latitude: Double, longitude: Double,
                               horizon: @escaping (Double) -> Double?) -> (rise: SkyEvent?, set: SkyEvent?) {
        let start = startOfDay(day)
        let end = start.addingTimeInterval(86_400)
        let value: (Date) -> Double = { date in
            let position = body.horizontal(date, latitude: latitude, longitude: longitude)
            // 稜線の高さは見かけの高さ(大気の屈折を含む)。上の縁(月は中心)が稜線に一致する所
            let edge = body == .sun ? body.semidiameter(date) : 0
            return position.apparentAltitude + edge - max(horizon(position.azimuth) ?? 0, 0)
        }
        let event: (Date) -> SkyEvent = { SkyEvent(date: $0, azimuth: body.horizontal($0, latitude: latitude, longitude: longitude).azimuth) }
        // 稜線が分からない方角での出入りは、求めない(地平線での時刻だけを出す)
        let known: (SkyEvent) -> Bool = { horizon($0.azimuth) != nil }
        // 山の陰に何度か出入りすることがあるので、出は最初、入りは最後
        let rise = crossings(from: start, to: end, step: 120, rising: true, value: value).first.map(event).flatMap { known($0) ? $0 : nil }
        let set = crossings(from: start, to: end, step: 120, rising: false, value: value).last.map(event).flatMap { known($0) ? $0 : nil }
        return (rise, set)
    }

    /// 1日の通り道(10分ごと)と、1時間ごとの時刻の印
    struct PathPoint: Equatable {
        var date: Date
        var azimuth: Double
        var apparentAltitude: Double
        var isHour: Bool
    }

    static func path(_ body: SkyBody, on day: Date, latitude: Double, longitude: Double, step: TimeInterval = 600) -> [PathPoint] {
        let start = startOfDay(day)
        let calendar = Calendar.japan
        return stride(from: 0.0, through: 86_400, by: step).map { offset in
            let date = start.addingTimeInterval(offset)
            let position = body.horizontal(date, latitude: latitude, longitude: longitude)
            let minute = calendar.component(.minute, from: date)
            return PathPoint(date: date, azimuth: position.azimuth, apparentAltitude: position.apparentAltitude, isHour: minute == 0)
        }
    }

    /// その年の夏至・冬至(太陽の黄経が 90°・270° になる日時)
    static func solstice(year: Int, summer: Bool) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = summer ? 6 : 12
        components.day = 10
        guard let start = Calendar.japan.date(from: components) else { return nil }
        let target = summer ? 90.0 : 270.0
        let value: (Date) -> Double = { date in
            WaypointMath.difference(from: target, to: Astronomy.sunLongitude(date))
        }
        return crossings(from: start, to: start.addingTimeInterval(20 * 86_400), step: 3_600, rising: true, value: value).first
    }
}

extension Calendar {
    /// 日本時間のグレゴリオ暦
    static let japan: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }()
}

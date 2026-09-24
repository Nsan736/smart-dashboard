import Foundation

/// 移動の記録の保存期間
enum MovementRetention: String, CaseIterable, Identifiable {
    case today
    case week
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "今日だけ"
        case .week: return "7日"
        case .none: return "保存しない"
        }
    }

    /// 残す日数(今日を含む)
    var days: Int {
        switch self {
        case .today: return 1
        case .week: return 7
        case .none: return 0
        }
    }
}

/// 乗車したと判定した区間
struct MovementRide: Codable, Equatable, Identifiable {
    var id = UUID()
    var railwayID: String
    var railwayName: String
    var trainLabel: String?
    var start: Date
    var end: Date
    /// 確からしさ(RideConfidence の rawValue)の一番高かった値
    var confidence: Int
}

/// 1日分の移動の記録。端末の中だけに保存し、外部には送らない。
struct MovementDay: Codable, Equatable {
    var day: String
    var samples: [RideSample] = []
    var rides: [MovementRide] = []
}

enum MovementLogPolicy {
    /// 記録に残す間隔。1秒ごとの点をすべては残さず、5秒か25mごとにする(1日の記録を小さく保つ)。
    static let minimumInterval: TimeInterval = 5
    static let minimumDistance = 25.0

    static func dayKey(_ date: Date, calendar: Calendar = JapaneseHolidays.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 記録に加えるか
    static func shouldAppend(_ sample: RideSample, after last: RideSample?) -> Bool {
        guard let last else { return true }
        if sample.time.timeIntervalSince(last.time) >= minimumInterval { return true }
        return GeoMath.distance(last.point, sample.point) >= minimumDistance
    }

    /// 保存期間を過ぎたファイル(日付のキー)。「保存しない」ならすべて。
    static func expiredKeys(_ keys: [String], today: Date, retention: MovementRetention,
                            calendar: Calendar = JapaneseHolidays.calendar) -> [String] {
        guard retention.days > 0 else { return keys }
        let keep = Set((0..<retention.days).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayKey($0, calendar: calendar) }
        })
        return keys.filter { !keep.contains($0) }
    }

    /// 地図に描くための区切り。乗車と判定した区間は isRide = true。
    static func segments(_ day: MovementDay) -> [(points: [GeoPoint], isRide: Bool)] {
        var result: [(points: [GeoPoint], isRide: Bool)] = []
        var current: [GeoPoint] = []
        var currentIsRide: Bool?
        for sample in day.samples {
            let isRide = day.rides.contains { sample.time >= $0.start && sample.time <= $0.end }
            if let currentIsRide, currentIsRide != isRide {
                // 区切りの点は両方に入れて、線をつなげる
                if let last = current.last {
                    result.append((current, currentIsRide))
                    current = [last]
                }
            }
            current.append(sample.point)
            currentIsRide = isRide
        }
        if let currentIsRide, current.count >= 2 { result.append((current, currentIsRide)) }
        return result
    }

    /// 記録の合計の距離(m)
    static func distance(_ samples: [RideSample]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) { $0 + GeoMath.distance($1.0.point, $1.1.point) }
    }
}

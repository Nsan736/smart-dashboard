import Foundation

/// 駅まで歩いて、その電車に間に合うか
enum CatchStatus: Equatable {
    case comfortable
    case hurry
    case missed

    var label: String {
        switch self {
        case .comfortable: return "間に合う"
        case .hurry: return "急げば間に合う"
        case .missed: return "間に合わない"
        }
    }

    var shortLabel: String {
        switch self {
        case .comfortable: return "間に合う"
        case .hurry: return "急げば"
        case .missed: return "無理"
        }
    }
}

enum CatchEstimator {
    /// 駅までの時間(秒)。直線距離に係数をかけて歩く速さで割り、駅の中の移動の時間を足す。「急げば」は速さに倍率をかける。
    static func walkSeconds(distance: Double, settings: WalkSettings, hurry: Bool) -> TimeInterval {
        let speed = settings.speedMetersPerSecond * (hurry ? max(1, settings.hurryMultiplier) : 1)
        return max(0, distance) * settings.routeFactor / speed + max(0, settings.accessMinutes) * 60
    }

    static func status(departure: Date, now: Date, distance: Double, settings: WalkSettings) -> CatchStatus {
        let slack = departure.timeIntervalSince(now)
        if walkSeconds(distance: distance, settings: settings, hurry: false) <= slack { return .comfortable }
        if walkSeconds(distance: distance, settings: settings, hurry: true) <= slack { return .hurry }
        return .missed
    }

    /// 普通に歩いて間に合う、一番早い電車
    static func nextComfortable(_ departures: [StationDeparture], now: Date, distance: Double, settings: WalkSettings) -> StationDeparture? {
        departures.first { status(departure: $0.effective, now: now, distance: distance, settings: settings) == .comfortable }
    }
}

/// 駅から出る電車1本(列車ごとの時刻表から作る)
struct StationDeparture: Equatable, Identifiable {
    /// 列車の運行のID(TrainPosition.id と同じ形)
    var id: String
    var railwayID: String
    var trainNumber: String
    var trainType: String
    var destination: String
    var direction: String
    /// その列車の運行日(0時)
    var serviceDay: Date
    var scheduled: Date
    /// 遅れを反映した予定(遅れが分かっているときだけ)
    var expected: Date?
    var platform: String?
    /// この駅が始発
    var isOrigin: Bool

    var effective: Date { expected ?? scheduled }

    var label: String {
        let type = trainType.isEmpty ? "" : trainType + " "
        return type + (destination.isEmpty ? "行先不明" : destination + "行")
    }
}

/// 方面ごとの時刻表
struct StationDirectionBoard: Equatable, Identifiable {
    var direction: String
    /// 今の時刻の付近から
    var departures: [StationDeparture]
    /// 今の運行日の始発と終電
    var first: Date?
    var last: Date?

    var id: String { direction }
}

/// 列車ごとの時刻表(LineSchedule)から、駅の時刻表を作る。登録していない駅でも作れる。
enum StationDepartures {
    /// この時刻より前は、前の日の運行日とみなす(深夜の電車のため)
    static let serviceDayStartHour = 3

    /// 駅を出る電車(前日の運行日の深夜の分、今日、翌日の運行日)。遅れは反映しない。時刻の順。
    static func scheduled(schedule: LineSchedule, stationID: String, now: Date, resolver: DayTypeResolver) -> [StationDeparture] {
        guard let index = schedule.stationIDs.firstIndex(of: stationID) else { return [] }
        let calendar = JapaneseHolidays.calendar
        let today = calendar.startOfDay(for: now)
        var result: [StationDeparture] = []
        for dayOffset in [-1, 0, 1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let dayType = resolver.dayType(of: day.addingTimeInterval(12 * 3600))
            for train in schedule.trains(for: dayType) {
                // 終点での到着は、出発ではないので出さない
                for (position, stop) in train.stops.enumerated() where stop.station == index && position < train.stops.count - 1 {
                    result.append(StationDeparture(
                        id: TrainPositionCalculator.tripID(number: train.number, calendar: train.calendar, day: day),
                        railwayID: schedule.railwayID, trainNumber: train.number, trainType: train.trainType,
                        destination: train.destination, direction: train.direction, serviceDay: day,
                        scheduled: day.addingTimeInterval(Double(stop.departureMinute) * 60), expected: nil,
                        platform: stop.platform, isOrigin: position == 0))
                }
            }
        }
        return result.sorted { $0.scheduled != $1.scheduled ? $0.scheduled < $1.scheduled : $0.id < $1.id }
    }

    /// 遅れ(列車番号 → 秒)を反映する。列車番号は毎日同じなので、今の前後3時間の電車にだけ使う。
    static func applyingDelays(_ departures: [StationDeparture], delays: [String: TimeInterval], now: Date) -> [StationDeparture] {
        guard !delays.isEmpty else { return departures }
        return departures.map { departure in
            guard let seconds = delays[departure.trainNumber], seconds > 0,
                  abs(departure.scheduled.timeIntervalSince(now)) <= 3 * 3600 else { return departure }
            var copy = departure
            copy.expected = departure.scheduled.addingTimeInterval(seconds)
            return copy
        }
    }

    /// 今の運行日(3時より前は前の日)
    static func serviceDay(of now: Date) -> Date {
        let calendar = JapaneseHolidays.calendar
        let today = calendar.startOfDay(for: now)
        let hour = calendar.component(.hour, from: now)
        return hour < serviceDayStartHour ? (calendar.date(byAdding: .day, value: -1, to: today) ?? today) : today
    }

    /// 方面ごとにまとめる。今から(1分前まで)の電車を limit 本と、今の運行日の始発・終電。
    static func boards(_ departures: [StationDeparture], now: Date, directionOrder: [String], limit: Int = 6) -> [StationDirectionBoard] {
        let service = serviceDay(of: now)
        let grouped = Dictionary(grouping: departures, by: \.direction)
        let directions = grouped.keys.sorted { a, b in
            let ra = directionOrder.firstIndex(of: a) ?? Int.max
            let rb = directionOrder.firstIndex(of: b) ?? Int.max
            return ra != rb ? ra < rb : a < b
        }
        return directions.map { direction in
            let list = grouped[direction] ?? []
            let upcoming = list.filter { $0.effective >= now.addingTimeInterval(-60) }
            let today = list.filter { $0.serviceDay == service }
            return StationDirectionBoard(direction: direction, departures: Array(upcoming.prefix(limit)),
                                         first: today.map(\.scheduled).min(), last: today.map(\.scheduled).max())
        }
    }
}

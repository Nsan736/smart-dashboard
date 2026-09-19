import Foundation

/// 運行情報を見る路線の登録
struct RegisteredLine: Codable, Equatable, Identifiable, Hashable {
    var operatorID: String
    var railwayID: String
    var railwayName: String
    var id: String { railwayID }
}

/// 時刻表を見る駅・方面の登録
struct RegisteredStation: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var operatorID: String
    var railwayID: String
    var railwayName: String
    var stationID: String
    var stationName: String
    var directionID: String
    var directionName: String
}

/// 端末に保存する時刻表。表示に必要な項目だけを持つ。
struct StoredTimetable: Codable, Equatable {
    struct Departure: Codable, Equatable {
        /// 始発からの運行日基準の分。0時を過ぎた列車は1440以上になる。
        var minutes: Int
        var trainType: String?
        var destination: String?
        var isLast: Bool
    }

    var registrationID: UUID
    var downloadedAt: Date
    var issued: String?
    /// キーはODPTのカレンダーID (例: odpt.Calendar:Weekday)
    var departuresByCalendar: [String: [Departure]]

    /// ODPTの応答から作る。時刻は並び順を保ったまま、前の列車より早い時刻が出たら翌日とみなす。
    init(registrationID: UUID, downloadedAt: Date, tables: [ODPTStationTimetable],
         trainTypeNames: [String: String], stationNames: [String: String]) {
        self.registrationID = registrationID
        self.downloadedAt = downloadedAt
        issued = tables.compactMap(\.issued).max()
        var result: [String: [Departure]] = [:]
        for table in tables {
            guard let calendar = table.calendar else { continue }
            var dayOffset = 0
            var previous = -1
            var list: [Departure] = []
            for object in table.objects {
                guard let text = object.departureTime, let base = Self.parseMinutes(text) else { continue }
                var minutes = base + dayOffset
                if minutes < previous {
                    dayOffset += 1440
                    minutes = base + dayOffset
                }
                previous = minutes
                let destination = object.destinationStation?.first.map { stationNames[$0] ?? ODPTID.tail($0) }
                let type = object.trainType.map { trainTypeNames[$0] ?? ODPTID.tail($0) }
                list.append(Departure(minutes: minutes, trainType: type, destination: destination, isLast: object.isLast ?? false))
            }
            result[calendar] = list
        }
        departuresByCalendar = result
    }

    static func parseMinutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<60).contains(m), (0..<48).contains(h) else { return nil }
        return h * 60 + m
    }

    /// その日の種別に合うカレンダーを選ぶ。事業者によって「土休日」か「土曜」「休日」かが違う。
    func departures(for dayType: DayType) -> [Departure] {
        let candidates: [String]
        switch dayType {
        case .weekday: candidates = ["Weekday"]
        case .saturday: candidates = ["Saturday", "SaturdayHoliday", "Holiday"]
        case .holiday: candidates = ["Holiday", "SaturdayHoliday", "Sunday"]
        }
        for name in candidates {
            if let list = departuresByCalendar["odpt.Calendar:\(name)"] { return list }
        }
        return []
    }
}

struct UpcomingDeparture: Equatable, Identifiable {
    var date: Date
    var departure: StoredTimetable.Departure
    var id: Date { date }
}

enum TimetableCalculator {
    /// 通信なしで、保存した時刻表から次の列車を求める。
    /// 深夜0時過ぎは前日の運行日の時刻表(1440分以降)も対象にする。
    static func upcoming(in timetable: StoredTimetable, now: Date, count: Int = 2) -> [UpcomingDeparture] {
        let calendar = JapaneseHolidays.calendar
        let today = calendar.startOfDay(for: now)
        var result: [UpcomingDeparture] = []
        for dayOffset in [-1, 0, 1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let list = timetable.departures(for: JapaneseHolidays.dayType(of: day))
            for departure in list {
                let date = day.addingTimeInterval(TimeInterval(departure.minutes * 60))
                if date >= now { result.append(UpcomingDeparture(date: date, departure: departure)) }
            }
            if dayOffset >= 0, result.count >= count { break }
        }
        return Array(result.sorted { $0.date < $1.date }.prefix(count))
    }
}

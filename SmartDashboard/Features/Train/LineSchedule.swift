import Foundation

/// 端末に保存する、路線1本分の列車ごとの時刻表。事業者に依存しない形にしてある。
/// 時刻は運行日を基準にした分で、0時を過ぎたら1440以上になる(駅の時刻表 StoredTimetable と同じ扱い)。
struct LineSchedule: Codable, Equatable {
    struct Stop: Codable, Equatable {
        /// stationIDs の番号
        var station: Int
        var arrival: Int?
        var departure: Int?

        enum CodingKeys: String, CodingKey {
            case station = "s"
            case arrival = "a"
            case departure = "d"
        }

        /// 到着・出発のどちらかは必ずある
        var arrivalMinute: Int { arrival ?? departure ?? 0 }
        var departureMinute: Int { departure ?? arrival ?? 0 }
    }

    struct Train: Codable, Equatable {
        var number: String
        /// ODPTのカレンダーID (例: odpt.Calendar:Weekday)
        var calendar: String
        var direction: String
        var trainType: String
        var destination: String
        var stops: [Stop]

        enum CodingKeys: String, CodingKey {
            case number = "n"
            case calendar = "c"
            case direction = "r"
            case trainType = "t"
            case destination = "e"
            case stops = "p"
        }
    }

    var railwayID: String
    var downloadedAt: Date
    /// 路線の駅(odpt:Railway の駅の順)。時刻表にしか出てこない駅は後ろに足す。
    var stationIDs: [String]
    var trains: [Train]

    /// 保存してから30日で取り直す
    static let validFor: TimeInterval = 30 * 24 * 60 * 60

    func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(downloadedAt) > Self.validFor
    }

    /// ODPTの応答から作る
    init(railwayID: String, downloadedAt: Date, orderedStationIDs: [String], timetables: [ODPTTrainTimetable],
         trainTypeNames: [String: String], stationNames: [String: String]) {
        self.railwayID = railwayID
        self.downloadedAt = downloadedAt
        var ids = orderedStationIDs
        var index = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var result: [Train] = []
        var seen = Set<String>()
        for table in timetables {
            guard let calendar = table.calendar, seen.insert("\(table.trainNumber)|\(calendar)").inserted else { continue }
            var stops: [Stop] = []
            var previous = -1
            var dayOffset = 0
            for object in table.objects {
                guard let stationID = object.departureStation ?? object.arrivalStation else { continue }
                if index[stationID] == nil {
                    index[stationID] = ids.count
                    ids.append(stationID)
                }
                func minute(_ text: String?) -> Int? {
                    guard let text, let base = StoredTimetable.parseMinutes(text) else { return nil }
                    var value = base + dayOffset
                    if value < previous {
                        dayOffset += 1440
                        value = base + dayOffset
                    }
                    previous = value
                    return value
                }
                let arrival = minute(object.arrivalTime)
                let departure = minute(object.departureTime)
                guard arrival != nil || departure != nil, let station = index[stationID] else { continue }
                stops.append(Stop(station: station, arrival: arrival, departure: departure))
            }
            guard stops.count >= 2 else { continue }
            let destinationID = table.destinationStation?.first
            result.append(Train(
                number: table.trainNumber,
                calendar: calendar,
                direction: table.railDirection ?? "",
                trainType: table.trainType.map { trainTypeNames[$0] ?? ODPTID.tail($0) } ?? "",
                destination: destinationID.map { stationNames[$0] ?? ODPTID.tail($0) } ?? "",
                stops: stops
            ))
        }
        stationIDs = ids
        trains = result
    }

    init(railwayID: String, downloadedAt: Date, stationIDs: [String], trains: [Train]) {
        self.railwayID = railwayID
        self.downloadedAt = downloadedAt
        self.stationIDs = stationIDs
        self.trains = trains
    }

    /// その日の種別に合うカレンダーの列車。事業者によって「土休日」か「土曜」「休日」かが違う。
    func trains(for dayType: DayType) -> [Train] {
        let candidates: [String]
        switch dayType {
        case .weekday: candidates = ["Weekday"]
        case .saturday: candidates = ["Saturday", "SaturdayHoliday", "Holiday"]
        case .holiday: candidates = ["Holiday", "SaturdayHoliday", "Sunday"]
        }
        for name in candidates {
            let list = trains.filter { $0.calendar == "odpt.Calendar:\(name)" }
            if !list.isEmpty { return list }
        }
        return []
    }
}

/// 遅れの出どころ
enum DelaySource: Equatable {
    /// odpt:Train の遅れ(秒)
    case realtime(TimeInterval)
    /// 時刻表どおりとして表示している(リアルタイムの遅れが取れない、または対応付けできない)
    case timetable
    /// 運行情報で路線に遅延・見合わせがあるが、列車ごとの遅れは分からない
    case lineDelayed

    var seconds: TimeInterval {
        if case .realtime(let seconds) = self { return seconds }
        return 0
    }

    var label: String {
        switch self {
        case .realtime(let seconds):
            let minutes = Int((seconds / 60).rounded())
            return minutes <= 0 ? "遅れなし(リアルタイム)" : "遅れ\(minutes)分(リアルタイム)"
        case .timetable: return "時刻表どおり"
        case .lineDelayed: return "路線で遅延あり(列車ごとの遅れは不明)"
        }
    }

    /// 地図や路線図での色分け
    enum Tone: Equatable { case onTime, delayed, unknown }

    var tone: Tone {
        switch self {
        case .realtime(let seconds): return seconds >= 60 ? .delayed : .onTime
        case .timetable: return .onTime
        case .lineDelayed: return .unknown
        }
    }
}

/// ある時刻の列車の位置(時刻表から計算し、遅れの分だけ補正したもの)
struct TrainPosition: Equatable, Identifiable {
    struct UpcomingStop: Equatable {
        var station: Int
        /// 遅れを補正した到着予定
        var arrival: Date
    }

    var id: String
    var number: String
    var direction: String
    var trainType: String
    var destination: String
    var delay: DelaySource
    /// いる駅、または直前に出た駅(stationIDs の番号)
    var fromStation: Int
    /// 次に止まる駅。終点に着いているときは fromStation と同じ。
    var toStation: Int
    /// fromStation から toStation までの進み具合(0〜1)。停車中は0。
    var fraction: Double
    var isStopped: Bool
    /// まだ始発駅を出ていない
    var isWaitingToDepart: Bool
    /// これから止まる駅(今いる駅は含まない)
    var upcoming: [UpcomingStop]
}

/// ある駅に向かっている列車
struct TrainApproach: Equatable, Identifiable {
    var position: TrainPosition
    var arrival: Date
    /// その駅まであと何駅か(次に止まるのがその駅なら1)
    var stopsAway: Int
    var id: String { position.id }
}

enum TrainPositionCalculator {
    /// 到着と出発が同じ分のとき、停車していたとみなす時間(分)
    static let minimumDwell = 0.4
    /// 始発駅での発車待ちとして扱う時間(分)。「駅に向かっている列車」の一覧に使う。
    static let waitingWindow = 30.0

    /// 時刻表から、今走っている列車の位置を求める。
    /// - delays: 列車番号 → 遅れ(秒)。odpt:Train から得たもの。
    /// - lineIsDelayed: 運行情報で路線に遅延・見合わせがある
    /// 深夜0時過ぎは、前日の運行日の時刻表(1440分以降)も対象にする。
    static func positions(in schedule: LineSchedule, now: Date, resolver: DayTypeResolver = DayTypeResolver(),
                          delays: [String: TimeInterval] = [:], lineIsDelayed: Bool = false,
                          includesWaiting: Bool = false) -> [TrainPosition] {
        let calendar = JapaneseHolidays.calendar
        let today = calendar.startOfDay(for: now)
        var result: [TrainPosition] = []
        for dayOffset in [-1, 0] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let dayType = resolver.dayType(of: day.addingTimeInterval(12 * 3600))
            let minutesNow = now.timeIntervalSince(day) / 60
            for train in schedule.trains(for: dayType) {
                let delaySeconds = delays[train.number]
                let source: DelaySource = delaySeconds.map { .realtime($0) } ?? (lineIsDelayed ? .lineDelayed : .timetable)
                // 遅れの分だけ、時刻表の上での「今」を戻す
                let t = minutesNow - source.seconds / 60
                guard let position = position(of: train, at: t, day: day, delay: source, includesWaiting: includesWaiting) else { continue }
                result.append(position)
            }
        }
        return result
    }

    /// 時刻表の上での時刻 t(運行日基準の分)における位置。走っていなければnil。
    static func position(of train: LineSchedule.Train, at t: Double, day: Date, delay: DelaySource,
                         includesWaiting: Bool) -> TrainPosition? {
        guard let first = train.stops.first, let last = train.stops.last else { return nil }
        let start = Double(first.departureMinute)
        let end = Double(last.arrivalMinute)
        let isWaiting = t < start
        if isWaiting {
            guard includesWaiting, start - t <= waitingWindow else { return nil }
        }
        guard t <= end else { return nil }

        func date(_ minute: Int) -> Date {
            day.addingTimeInterval(Double(minute) * 60 + delay.seconds)
        }
        func make(from: Int, to: Int, fraction: Double, stopped: Bool, nextIndex: Int) -> TrainPosition {
            let upcoming = train.stops[nextIndex...].map {
                TrainPosition.UpcomingStop(station: $0.station, arrival: date($0.arrivalMinute))
            }
            return TrainPosition(
                id: "\(train.number)|\(train.calendar)|\(Int(day.timeIntervalSince1970))",
                number: train.number, direction: train.direction, trainType: train.trainType, destination: train.destination,
                delay: delay, fromStation: train.stops[from].station, toStation: train.stops[to].station,
                fraction: fraction, isStopped: stopped, isWaitingToDepart: isWaiting, upcoming: Array(upcoming))
        }

        if isWaiting { return make(from: 0, to: min(1, train.stops.count - 1), fraction: 0, stopped: true, nextIndex: 1) }
        for index in train.stops.indices {
            let stop = train.stops[index]
            let arrival = Double(stop.arrivalMinute)
            // 到着と出発が同じ分でも、少しの間は停車していたことにする
            let departure = max(Double(stop.departureMinute), arrival + (index == train.stops.count - 1 ? 0 : minimumDwell))
            if index == train.stops.count - 1 {
                return make(from: index, to: index, fraction: 0, stopped: true, nextIndex: train.stops.count)
            }
            if t <= departure {
                return make(from: index, to: index + 1, fraction: 0, stopped: true, nextIndex: index + 1)
            }
            let nextArrival = Double(train.stops[index + 1].arrivalMinute)
            if t < nextArrival {
                let span = max(0.1, nextArrival - departure)
                return make(from: index, to: index + 1, fraction: min(1, max(0, (t - departure) / span)), stopped: false, nextIndex: index + 1)
            }
        }
        return nil
    }

    /// ある駅に、指定した方面で向かっている列車を、到着の早い順に返す
    static func approaches(to station: Int, direction: String?, positions: [TrainPosition], now: Date, limit: Int = 3) -> [TrainApproach] {
        var result: [TrainApproach] = []
        for position in positions {
            if let direction, position.direction != direction { continue }
            guard let offset = position.upcoming.firstIndex(where: { $0.station == station }) else { continue }
            let arrival = position.upcoming[offset].arrival
            guard arrival >= now.addingTimeInterval(-30) else { continue }
            result.append(TrainApproach(position: position, arrival: arrival, stopsAway: offset + 1))
        }
        return Array(result.sorted { $0.arrival < $1.arrival }.prefix(limit))
    }

    /// その路線の方面の一覧(列車に出てくる順)
    static func directions(in schedule: LineSchedule) -> [String] {
        var seen = Set<String>()
        return schedule.trains.map(\.direction).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

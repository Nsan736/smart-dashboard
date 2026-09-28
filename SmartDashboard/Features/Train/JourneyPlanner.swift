import Foundation

/// 経路の中の、1つの駅での到着と出発
struct JourneyStop: Equatable {
    var stationID: String
    var name: String
    var arrival: Date
    var departure: Date
    var platform: String?
}

/// 経路の中の、1本の列車に乗る区間
struct JourneyLeg: Equatable, Identifiable {
    /// 列車の運行のID(TrainPosition.id と同じ形)。乗車中の判定と比べるのに使う。
    var tripID: String
    var railwayID: String
    var railwayName: String
    var trainNumber: String
    var trainType: String
    var destination: String
    var direction: String
    /// 乗る駅から降りる駅まで(両端を含む。2つ以上)
    var stops: [JourneyStop]

    var id: String { tripID + "@" + (stops.first?.stationID ?? "") }
    var board: JourneyStop { stops[0] }
    var alight: JourneyStop { stops[stops.count - 1] }

    var trainLabel: String {
        let type = trainType.isEmpty ? "" : trainType + " "
        return type + (destination.isEmpty ? "行先不明" : destination + "行")
    }
}

/// 乗り換えでの待ち
struct JourneyWait: Equatable {
    var stationName: String
    /// 別の駅(別の名前や別の路線の駅)へ歩く
    var nextStationName: String
    var seconds: TimeInterval
}

struct Journey: Equatable, Identifiable {
    var legs: [JourneyLeg]

    var id: String { legs.map(\.id).joined(separator: ">") }
    var departure: Date { legs.first?.board.departure ?? .distantPast }
    var arrival: Date { legs.last?.alight.arrival ?? .distantPast }
    var transfers: Int { max(0, legs.count - 1) }
    var duration: TimeInterval { arrival.timeIntervalSince(departure) }

    var waits: [JourneyWait] {
        zip(legs, legs.dropFirst()).map { previous, next in
            JourneyWait(stationName: previous.alight.name, nextStationName: next.board.name,
                        seconds: next.board.departure.timeIntervalSince(previous.alight.arrival))
        }
    }
}

struct JourneyOption: Equatable, Identifiable {
    enum Kind: Equatable {
        /// 一番早く着く
        case fastest
        /// 早く着く経路より、乗り換えが少ない
        case fewerTransfers
        /// 次の電車で行く
        case later

        var label: String {
            switch self {
            case .fastest: return "早く着く"
            case .fewerTransfers: return "乗り換えが少ない"
            case .later: return "次の電車"
            }
        }
    }

    var journey: Journey
    var kind: Kind

    var id: String { journey.id }
}

struct JourneyQuery: Equatable {
    var origins: Set<String>
    var destinations: Set<String>
    /// 出発の駅で電車に乗れる時刻
    var departure: Date
    var maxTransfers = 3
    /// 調べる時間の範囲
    var horizon: TimeInterval = 6 * 3600
}

/// 保存した時刻表だけを使い、通信なしで経路を探す。
///
/// 時刻表の接続(列車が、ある駅から次の駅へ行くこと)を、出発の早い順に1回だけ調べる方式(Connection Scan Algorithm)。
/// 乗った列車の数ごとに「その駅に一番早く着く時刻」を持つので、「早く着く」と「乗り換えが少ない」の両方が1回の走査で求まる。
/// 見つけた経路は、着く時刻を変えずに、途中の列車をできるだけ遅い列車に置き換える(乗り換えでの待ちを減らし、出発を遅らせる)。
enum JourneyPlanner {
    struct TripStop: Equatable {
        var stationID: String
        /// timeIntervalSinceReferenceDate
        var arrival: TimeInterval
        var departure: TimeInterval
        var platform: String?
    }

    /// ある運行日の列車1本
    struct Trip: Equatable {
        var id: String
        var railwayID: String
        var number: String
        var trainType: String
        var destination: String
        var direction: String
        var stops: [TripStop]
    }

    /// 経路の中の1区間(列車、乗る駅と降りる駅の番号)
    struct LegRef: Equatable {
        var trip: Int
        var board: Int
        var alight: Int
    }

    /// 乗り換えの相手と、乗り換えの時間(秒)
    typealias TransferProvider = (String) -> [(stationID: String, seconds: TimeInterval)]

    /// 保存した時刻表から、出発から horizon の間に走る列車を取り出す。
    /// 日をまたぐ場合のため、前日の運行日(24時以降の列車)と、翌日の運行日の列車も含める。
    static func trips(schedules: [LineSchedule], from start: Date, horizon: TimeInterval, resolver: DayTypeResolver) -> [Trip] {
        let calendar = JapaneseHolidays.calendar
        let today = calendar.startOfDay(for: start)
        let begin = start.timeIntervalSinceReferenceDate
        let end = begin + horizon
        var result: [Trip] = []
        for dayOffset in [-1, 0, 1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let dayType = resolver.dayType(of: day.addingTimeInterval(12 * 3600))
            let base = day.timeIntervalSinceReferenceDate
            for schedule in schedules {
                for train in schedule.trains(for: dayType) {
                    guard let first = train.stops.first, let last = train.stops.last else { continue }
                    // 出発より前に終わった列車と、範囲より後に出る列車は使わない
                    guard base + Double(last.arrivalMinute) * 60 >= begin, base + Double(first.departureMinute) * 60 <= end else { continue }
                    let stops = train.stops.compactMap { stop -> TripStop? in
                        guard schedule.stationIDs.indices.contains(stop.station) else { return nil }
                        return TripStop(stationID: schedule.stationIDs[stop.station],
                                        arrival: base + Double(stop.arrivalMinute) * 60,
                                        departure: base + Double(stop.departureMinute) * 60,
                                        platform: stop.platform)
                    }
                    guard stops.count >= 2 else { continue }
                    result.append(Trip(id: TrainPositionCalculator.tripID(number: train.number, calendar: train.calendar, day: day),
                                       railwayID: schedule.railwayID, number: train.number, trainType: train.trainType,
                                       destination: train.destination, direction: train.direction, stops: stops))
                }
            }
        }
        return result
    }

    /// 経路を探す。結果は「早く着く」「乗り換えが少ない」の順。足りなければ、次の電車で探し直して足す(最大 limit 件)。
    static func search(trips: [Trip], query: JourneyQuery, sameStationTransfer: TimeInterval, transfers: TransferProvider,
                       stationName: (String) -> String, railwayName: (String) -> String, limit: Int = 3) -> [JourneyOption] {
        guard !query.origins.isEmpty, !query.destinations.isEmpty, query.origins.isDisjoint(with: query.destinations) else { return [] }
        var options: [JourneyOption] = []
        let pareto = journeys(trips: trips, query: query, sameStationTransfer: sameStationTransfer, transfers: transfers,
                              stationName: stationName, railwayName: railwayName)
            .sorted { $0.arrival != $1.arrival ? $0.arrival < $1.arrival : $0.transfers < $1.transfers }
        for (index, journey) in pareto.enumerated() {
            options.append(JourneyOption(journey: journey, kind: index == 0 ? .fastest : .fewerTransfers))
        }
        var nextStart = options.first?.journey.departure
        var attempts = 0
        while options.count < limit, let start = nextStart, attempts < limit {
            attempts += 1
            var later = query
            later.departure = start.addingTimeInterval(60)
            let found = journeys(trips: trips, query: later, sameStationTransfer: sameStationTransfer, transfers: transfers,
                                 stationName: stationName, railwayName: railwayName)
            guard let journey = found.min(by: { $0.arrival != $1.arrival ? $0.arrival < $1.arrival : $0.transfers < $1.transfers })
            else { break }
            if !options.contains(where: { $0.journey.id == journey.id }) {
                options.append(JourneyOption(journey: journey, kind: .later))
            }
            nextStart = journey.departure
        }
        return Array(options.prefix(limit))
    }

    static func journeys(trips: [Trip], query: JourneyQuery, sameStationTransfer: TimeInterval, transfers: TransferProvider,
                         stationName: (String) -> String, railwayName: (String) -> String) -> [Journey] {
        let found = scan(trips: trips, query: query, sameStationTransfer: sameStationTransfer, transfers: transfers)
        var result: [Journey] = []
        for legs in found {
            var list: [JourneyLeg] = []
            for ref in legs {
                list.append(makeLeg(ref, trips: trips, stationName: stationName, railwayName: railwayName))
            }
            result.append(Journey(legs: list))
        }
        return result
    }

    /// 乗った列車の数ごとに、一番早く着く経路を求める(乗り換えの回数と着く時刻が、互いに劣らないものだけ)
    static func scan(trips: [Trip], query: JourneyQuery, sameStationTransfer: TimeInterval, transfers: TransferProvider) -> [[LegRef]] {
        let maxTrips = max(1, query.maxTransfers + 1)
        let begin = query.departure.timeIntervalSinceReferenceDate
        let end = begin + query.horizon

        // 接続を出発の早い順に並べる
        var connections: [(trip: Int, index: Int, departure: TimeInterval)] = []
        for (t, trip) in trips.enumerated() where trip.stops.count >= 2 {
            for i in 0..<(trip.stops.count - 1) {
                let departure = trip.stops[i].departure
                guard departure >= begin, departure <= end, trip.stops[i + 1].arrival >= departure else { continue }
                connections.append((t, i, departure))
            }
        }
        connections.sort { a, b in
            if a.departure != b.departure { return a.departure < b.departure }
            if a.trip != b.trip { return a.trip < b.trip }
            return a.index < b.index
        }

        // ready[k][駅]: k本の列車に乗ったあと、その駅で次の列車に乗れる時刻(0本は出発の駅)
        var ready = [[String: TimeInterval]](repeating: [:], count: maxTrips + 1)
        var readyVia = [[String: LegRef]](repeating: [:], count: maxTrips + 1)
        for origin in query.origins {
            ready[0][origin] = begin
        }
        for origin in query.origins {
            for target in transfers(origin) where !query.origins.contains(target.stationID) {
                ready[0][target.stationID] = min(ready[0][target.stationID] ?? .infinity, begin + target.seconds)
            }
        }
        // arrival[m][駅]: m本の列車に乗って、その駅に着く一番早い時刻
        var arrival = [[String: TimeInterval]](repeating: [:], count: maxTrips + 1)
        var arrivalVia = [[String: LegRef]](repeating: [:], count: maxTrips + 1)
        // 列車ごとに、乗ったときの列車の数(少ないほうを残す)と、乗った駅
        var boarded = [(count: Int, board: Int)?](repeating: nil, count: trips.count)

        for connection in connections {
            let trip = trips[connection.trip]
            let from = trip.stops[connection.index]
            for k in 0..<maxTrips {
                guard let time = ready[k][from.stationID], time <= connection.departure else { continue }
                if let state = boarded[connection.trip], state.count <= k + 1 { break }
                boarded[connection.trip] = (k + 1, connection.index)
                break
            }
            guard let state = boarded[connection.trip] else { continue }
            let to = trip.stops[connection.index + 1]
            let m = state.count
            let leg = LegRef(trip: connection.trip, board: state.board, alight: connection.index + 1)
            if to.arrival < (arrival[m][to.stationID] ?? .infinity) {
                arrival[m][to.stationID] = to.arrival
                arrivalVia[m][to.stationID] = leg
            }
            guard m < maxTrips else { continue }
            let sameStation = to.arrival + sameStationTransfer
            if sameStation < (ready[m][to.stationID] ?? .infinity) {
                ready[m][to.stationID] = sameStation
                readyVia[m][to.stationID] = leg
            }
            for target in transfers(to.stationID) {
                let time = to.arrival + target.seconds
                if time < (ready[m][target.stationID] ?? .infinity) {
                    ready[m][target.stationID] = time
                    readyVia[m][target.stationID] = leg
                }
            }
        }

        var results: [[LegRef]] = []
        var best = TimeInterval.infinity
        for m in 1...maxTrips {
            let reached = query.destinations.compactMap { id in arrival[m][id].map { (id: id, time: $0) } }
            guard let target = reached.min(by: { $0.time != $1.time ? $0.time < $1.time : $0.id < $1.id }), target.time < best else { continue }
            // 経路をさかのぼる
            guard var leg = arrivalVia[m][target.id] else { continue }
            var legs = [leg]
            var k = m - 1
            var valid = true
            while k > 0 {
                let station = trips[leg.trip].stops[leg.board].stationID
                guard let previous = readyVia[k][station] else {
                    valid = false
                    break
                }
                legs.insert(previous, at: 0)
                leg = previous
                k -= 1
            }
            guard valid else { continue }
            best = target.time
            results.append(tightened(legs, trips: trips, originReady: ready[0], sameStationTransfer: sameStationTransfer, transfers: transfers))
        }
        return results
    }

    /// 着く時刻を変えずに、最後の区間より前の列車を、間に合う範囲で一番遅い列車に置き換える
    static func tightened(_ input: [LegRef], trips: [Trip], originReady: [String: TimeInterval], sameStationTransfer: TimeInterval,
                          transfers: TransferProvider) -> [LegRef] {
        guard input.count >= 2 else { return input }
        var legs = input
        for i in stride(from: legs.count - 2, through: 0, by: -1) {
            let current = legs[i]
            let next = legs[i + 1]
            let trip = trips[current.trip]
            let boardStation = trip.stops[current.board].stationID
            let alightStation = trip.stops[current.alight].stationID
            let nextBoard = trips[next.trip].stops[next.board]
            let deadline = nextBoard.departure - transferTime(alightStation, nextBoard.stationID, sameStationTransfer: sameStationTransfer, transfers: transfers)
            let lower: TimeInterval
            if i == 0 {
                lower = originReady[boardStation] ?? trip.stops[current.board].departure
            } else {
                let previous = legs[i - 1]
                let previousAlight = trips[previous.trip].stops[previous.alight]
                lower = previousAlight.arrival + transferTime(previousAlight.stationID, boardStation, sameStationTransfer: sameStationTransfer, transfers: transfers)
            }
            var best = current
            var bestDeparture = trip.stops[current.board].departure
            for (index, candidate) in trips.enumerated() where index != current.trip && candidate.railwayID == trip.railwayID {
                guard let b = candidate.stops.firstIndex(where: { $0.stationID == boardStation }), b + 1 < candidate.stops.count,
                      let a = candidate.stops[(b + 1)...].firstIndex(where: { $0.stationID == alightStation }) else { continue }
                let departure = candidate.stops[b].departure
                guard departure >= lower, departure > bestDeparture, candidate.stops[a].arrival <= deadline else { continue }
                best = LegRef(trip: index, board: b, alight: a)
                bestDeparture = departure
            }
            legs[i] = best
        }
        return legs
    }

    /// 駅 a で降りて、駅 b で乗るまでに必要な時間
    static func transferTime(_ a: String, _ b: String, sameStationTransfer: TimeInterval, transfers: TransferProvider) -> TimeInterval {
        if a == b { return sameStationTransfer }
        for target in transfers(a) where target.stationID == b { return target.seconds }
        return sameStationTransfer
    }

    static func makeLeg(_ ref: LegRef, trips: [Trip], stationName: (String) -> String, railwayName: (String) -> String) -> JourneyLeg {
        let trip = trips[ref.trip]
        let stops = trip.stops[ref.board...ref.alight].map { stop in
            JourneyStop(stationID: stop.stationID, name: stationName(stop.stationID),
                        arrival: Date(timeIntervalSinceReferenceDate: stop.arrival),
                        departure: Date(timeIntervalSinceReferenceDate: stop.departure), platform: stop.platform)
        }
        return JourneyLeg(tripID: trip.id, railwayID: trip.railwayID, railwayName: railwayName(trip.railwayID),
                          trainNumber: trip.number, trainType: trip.trainType, destination: trip.destination,
                          direction: trip.direction, stops: Array(stops))
    }
}

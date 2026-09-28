import Foundation

/// 選んだ経路と、乗車中の判定を結びつける
enum JourneyTracking {
    enum Status: Equatable {
        /// 乗車中ではない
        case notRiding
        /// 経路の列車に乗っている(予定どおり)
        case onPlan(leg: Int)
        /// 経路の路線に乗っているが、列車が違うか、特定できていない
        case onLine(leg: Int)
        /// 経路にない路線に乗っている
        case offRoute
    }

    static func status(journey: Journey, judgement: RideJudgement) -> Status {
        guard judgement.isRiding else { return .notRiding }
        if let trainID = judgement.trainID, let index = journey.legs.firstIndex(where: { $0.tripID == trainID }) {
            return .onPlan(leg: index)
        }
        if let railwayID = judgement.railwayID, let index = journey.legs.firstIndex(where: { $0.railwayID == railwayID }) {
            return .onLine(leg: index)
        }
        return .offRoute
    }

    /// 降りる駅の1駅前で知らせる区間。次に止まる駅が降りる駅になったとき(1駅前に停車している間を含む)に、区間ごとに1回だけ。
    static func alightAlert(journey: Journey, judgement: RideJudgement, nextStationID: String?, alerted: Set<Int>) -> Int? {
        guard let nextStationID else { return nil }
        let index: Int
        switch status(journey: journey, judgement: judgement) {
        case .onPlan(let leg), .onLine(let leg):
            index = leg
        case .notRiding, .offRoute:
            return nil
        }
        guard !alerted.contains(index), journey.legs.indices.contains(index) else { return nil }
        return journey.legs[index].alight.stationID == nextStationID ? index : nil
    }

    /// 知らせる文
    static func alertText(journey: Journey, leg index: Int) -> String {
        guard journey.legs.indices.contains(index) else { return "" }
        let name = journey.legs[index].alight.name
        if index + 1 < journey.legs.count {
            return "次は\(name)。降りて\(journey.legs[index + 1].railwayName)に乗り換えます"
        }
        return "次は\(name)。降りる準備をしてください"
    }
}

/// デバッグ用: 選んだ経路の列車に、時刻表どおりに乗ったときの位置。家の中で、判定・「予定どおり」・降りる駅の通知を試すのに使う。
struct JourneyMotion: Equatable {
    struct Stop: Equatable {
        var point: GeoPoint
        /// 路線の線に沿った位置(線がない路線では nil)
        var along: Double?
        var arrival: TimeInterval
        var departure: TimeInterval
    }

    struct Leg: Equatable {
        var stops: [Stop]
        var line: RideLine?
    }

    let legs: [Leg]

    /// point: 駅の緯度経度を返す(路線の線にない駅も、駅の一覧から引けるように)
    init(journey: Journey, lines: [RideLine], point: (String) -> GeoPoint?) {
        var result: [Leg] = []
        for leg in journey.legs {
            let line = lines.first { $0.railwayID == leg.railwayID }
            var previous: Double?
            var stops: [Stop] = []
            for stop in leg.stops {
                let along = line?.stationAlong(stop.stationID, near: previous)
                if let along { previous = along }
                guard let place = along.flatMap({ line?.path.point(atAlong: $0) }) ?? point(stop.stationID) else { continue }
                stops.append(Stop(point: place, along: along, arrival: stop.arrival.timeIntervalSinceReferenceDate,
                                  departure: stop.departure.timeIntervalSinceReferenceDate))
            }
            if stops.count >= 2 { result.append(Leg(stops: stops, line: line)) }
        }
        legs = result
    }

    var start: Date? { legs.first?.stops.first.map { Date(timeIntervalSinceReferenceDate: $0.departure) } }
    var end: Date? { legs.last?.stops.last.map { Date(timeIntervalSinceReferenceDate: $0.arrival) } }

    /// その時刻の位置。乗る前は最初の駅、乗り換えの間は降りた駅(待ち時間の半分を過ぎたら次に乗る駅)、着いたあとは最後の駅。
    func position(at date: Date) -> GeoPoint? {
        guard let lastLeg = legs.last, let lastStop = lastLeg.stops.last else { return nil }
        let time = date.timeIntervalSinceReferenceDate
        for (index, leg) in legs.enumerated() {
            guard let first = leg.stops.first, let last = leg.stops.last else { continue }
            if time < first.departure {
                guard index > 0, let previous = legs[index - 1].stops.last else { return first.point }
                let middle = previous.arrival + (first.departure - previous.arrival) / 2
                return time < middle ? previous.point : first.point
            }
            if time <= last.arrival {
                for j in 0..<(leg.stops.count - 1) {
                    let a = leg.stops[j]
                    let b = leg.stops[j + 1]
                    if time <= a.departure { return a.point }
                    if time < b.arrival {
                        let fraction = min(1, max(0, (time - a.departure) / max(1, b.arrival - a.departure)))
                        if let line = leg.line, let from = a.along, let to = b.along,
                           let point = line.path.point(atAlong: from + (to - from) * fraction) {
                            return point
                        }
                        return GeoPoint(a.point.latitude + (b.point.latitude - a.point.latitude) * fraction,
                                        a.point.longitude + (b.point.longitude - a.point.longitude) * fraction)
                    }
                }
                return last.point
            }
        }
        return lastStop.point
    }
}

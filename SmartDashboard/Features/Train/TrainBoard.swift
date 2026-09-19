import CoreLocation
import Foundation

/// 地図と路線図の表示の切り替え
enum TrainFilter: String, CaseIterable, Identifiable {
    case all
    case registered
    case nearMe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "すべて"
        case .registered: return "登録駅"
        case .nearMe: return "自分の近く"
        }
    }

    var title: String {
        switch self {
        case .all: return "すべての電車"
        case .registered: return "登録した駅に近い電車"
        case .nearMe: return "自分の近くの電車"
        }
    }
}

/// 路線1本分の、表示に必要なものをまとめたもの
struct BoardLine {
    var railwayID: String
    var name: String
    var schedule: LineSchedule
    var shape: RailwayShape?
    var positions: [TrainPosition]

    func stationID(_ index: Int) -> String? {
        schedule.stationIDs.indices.contains(index) ? schedule.stationIDs[index] : nil
    }

    func stationName(_ index: Int) -> String {
        guard let id = stationID(index) else { return "?" }
        return shape?.stops.first { $0.stationID == id }?.name ?? ODPTID.tail(id)
    }

    func stationIndex(of stationID: String) -> Int? {
        schedule.stationIDs.firstIndex(of: stationID)
    }
}

/// ある駅に、ある方面で向かっている電車の一覧
struct ApproachGroup: Identifiable {
    var railwayID: String
    var lineName: String
    var stationID: String
    var stationName: String
    var direction: String
    var directionName: String
    var approaches: [TrainApproach]
    var id: String { "\(railwayID)|\(stationID)|\(direction)" }
}

enum TrainBoard {
    /// 列車の地図上の位置と進行方向。駅の緯度経度を、駅間の進み具合で直線補間する。
    static func coordinate(of position: TrainPosition, in line: BoardLine) -> (coordinate: CLLocationCoordinate2D, heading: Double?)? {
        guard let shape = line.shape,
              let fromID = line.stationID(position.fromStation), let toID = line.stationID(position.toStation),
              let from = shape.stops.first(where: { $0.stationID == fromID }),
              let to = shape.stops.first(where: { $0.stationID == toID }) else { return nil }
        let a = CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)
        let b = CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)
        let f = min(1, max(0, position.fraction))
        let point = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                           longitude: a.longitude + (b.longitude - a.longitude) * f)
        return (point, MapBearing.degrees(from: a, to: b))
    }

    /// 種別の短いラベル。各停は空にして、形(円)だけで表す。
    static func typeBadge(_ trainType: String) -> (label: String, isExpress: Bool) {
        let name = trainType.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.contains("普通") || name.contains("各停") || name.contains("各駅") || name == "Local" {
            return ("", false)
        }
        if name.contains("快特") { return ("快特", true) }
        if name.contains("特急") { return ("特", true) }
        if name.contains("急行") { return ("急", true) }
        if name.contains("快速") { return ("快", true) }
        return (String(name.prefix(1)), true)
    }

    /// 駅に向かっている電車を、方面ごとに3本ずつ
    static func groups(for stationID: String, stationName: String, in line: BoardLine,
                       directionNames: [String: String], now: Date, limit: Int = 3) -> [ApproachGroup] {
        guard let index = line.stationIndex(of: stationID) else { return [] }
        return TrainPositionCalculator.directions(in: line.schedule).compactMap { direction -> ApproachGroup? in
            let approaches = TrainPositionCalculator.approaches(to: index, direction: direction, positions: line.positions, now: now, limit: limit)
            guard !approaches.isEmpty else { return nil }
            return ApproachGroup(railwayID: line.railwayID, lineName: line.name, stationID: stationID, stationName: stationName,
                                 direction: direction, directionName: directionNames[direction] ?? ODPTID.tail(direction),
                                 approaches: approaches)
        }
    }

    /// 「あと3分で到着・2駅前」
    static func approachText(_ approach: TrainApproach, now: Date) -> String {
        let seconds = max(0, approach.arrival.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded(.up))
        let eta = seconds < 30 ? "まもなく到着" : "あと\(minutes)分で到着"
        if approach.position.isWaitingToDepart { return "\(eta)・始発駅で発車待ち" }
        return approach.stopsAway <= 1 ? "\(eta)・次に停車" : "\(eta)・\(approach.stopsAway - 1)駅前"
    }

    /// 「今は◯駅(あと◯駅)」。ホームのカード用。
    static func whereaboutsText(_ approach: TrainApproach, in line: BoardLine) -> String {
        let position = approach.position
        let place: String
        if position.isWaitingToDepart {
            place = "\(line.stationName(position.fromStation))駅で発車待ち"
        } else if position.isStopped {
            place = "今は\(line.stationName(position.fromStation))駅"
        } else {
            place = "今は\(line.stationName(position.fromStation))→\(line.stationName(position.toStation))の間"
        }
        return "\(place)(あと\(approach.stopsAway)駅)"
    }

    /// 路線図での位置。駅の順の番号(小数)で表す。環状線などで同じ駅が2回出てくる場合は、前後の駅に近いほうを選ぶ。
    static func diagramPosition(of position: TrainPosition, in line: BoardLine, order: [String]) -> (value: Double, isAscending: Bool)? {
        guard let fromID = line.stationID(position.fromStation), let toID = line.stationID(position.toStation) else { return nil }
        let fromCandidates = order.indices.filter { order[$0] == fromID }
        let toCandidates = order.indices.filter { order[$0] == toID }
        guard !fromCandidates.isEmpty, !toCandidates.isEmpty else { return nil }
        var best: (from: Int, to: Int)?
        for f in fromCandidates {
            for t in toCandidates where best == nil || abs(t - f) < abs(best!.to - best!.from) {
                best = (f, t)
            }
        }
        guard let best else { return nil }
        let value = Double(best.from) + Double(best.to - best.from) * min(1, max(0, position.fraction))
        if best.to != best.from { return (value, best.to > best.from) }
        // 終点などで向きが決まらないときは、これから止まる駅か、来た方向で決める
        if let next = position.upcoming.first, let nextID = line.stationID(next.station),
           let nextIndex = order.firstIndex(of: nextID), nextIndex != best.from {
            return (value, nextIndex > best.from)
        }
        return (value, best.from != 0)
    }
}

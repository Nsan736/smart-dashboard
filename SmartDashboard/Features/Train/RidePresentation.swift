import Foundation

/// 乗車中の判定を、画面に出す形にまとめたもの
struct RideInfo: Equatable {
    struct Target: Equatable {
        var name: String
        /// あと何駅か(次に止まる駅なら1)
        var stopsAway: Int
        var arrival: Date?
    }

    var stateText: String
    var railwayName: String?
    /// 「西馬込行」「押上方面」
    var directionText: String?
    var train: RideTrainCandidate?
    /// 次の停車駅と、その次の数駅(列車を照合できたとき)
    var nextStops: [RideTrainCandidate.Stop] = []
    /// 列車を照合できないときの、この先の駅
    var aheadStations: [String] = []
    /// 次の駅までの距離(m)
    var nextStopDistance: Double?
    /// 登録した駅までの残り
    var targets: [Target] = []
    /// 線に沿った速さ(km/h)。推定中は nil。
    var speedKmh: Double?

    static func stateText(_ judgement: RideJudgement) -> String {
        switch judgement.state {
        case .off: return "乗車中の判定はオフです"
        case .idle: return "乗車中ではありません"
        case .candidate: return "乗車中か確認しています(\(Int(judgement.debug.continued))秒)"
        case .riding: return "乗車中の可能性あり"
        case .estimating: return "推定中(GPSなし)"
        }
    }

    static func make(judgement: RideJudgement, lines: [RideLine], trains: [RideTrainCandidate],
                     registeredStationIDs: Set<String>) -> RideInfo {
        var info = RideInfo(stateText: stateText(judgement))
        guard judgement.isRiding, let railwayID = judgement.railwayID, let line = lines.first(where: { $0.railwayID == railwayID }) else {
            return info
        }
        info.railwayName = line.name
        if judgement.state == .riding, let speed = judgement.debug.alongSpeed { info.speedKmh = abs(speed) * 3.6 }
        let along = judgement.along ?? 0
        let train = judgement.trainID.flatMap { id in trains.first { $0.id == id } }
        info.train = train
        let ascending = judgement.isAscending ?? train?.isAscending
        if let train, !train.destination.isEmpty {
            info.directionText = train.destination + "行"
        } else if let ascending {
            info.directionText = line.terminalName(ascending: ascending) + "方面"
        }
        if let train {
            info.nextStops = Array(train.upcoming.prefix(5))
            if let next = train.upcoming.first?.along { info.nextStopDistance = abs(next - along) }
            for (index, stop) in train.upcoming.enumerated() where registeredStationIDs.contains(stop.stationID) {
                info.targets.append(Target(name: stop.name, stopsAway: index + 1, arrival: stop.arrival))
            }
        } else if let ascending {
            let ahead = line.stationsAhead(of: along, ascending: ascending)
            info.aheadStations = ahead.prefix(5).map(\.name)
            if let next = ahead.first { info.nextStopDistance = abs(next.along - along) }
            for (index, station) in ahead.enumerated() where registeredStationIDs.contains(station.stationID) {
                info.targets.append(Target(name: station.name, stopsAway: index + 1, arrival: nil))
            }
        }
        return info
    }
}

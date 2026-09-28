import CoreGraphics
import Foundation

/// 地図を拡大したとき、駅の点のまわりに重ねる電車(停車中と、まもなく着く電車)
struct StationTrainItem: Equatable {
    var trainID: String
    var stationID: String
    var direction: String
    /// 方面を並べる順(路線の方面の一覧の順)
    var directionRank: Int
    var platform: String?
    /// 種別の短い文字と、行先の頭文字(例: 急西)
    var label: String
    var isExpress: Bool
    var tone: DelaySource.Tone
    var isStopped: Bool
    /// 着くまでの秒(停車中は0)
    var secondsToArrival: TimeInterval
}

/// 駅のまわりの並び(行は方面か番線、列は近い順)
struct StationTrainSlot: Equatable {
    var item: StationTrainItem
    var row: Int
    var column: Int
    var rowCount: Int
    /// この行に入りきらなかった数(行の最後の枠にだけ入れる)
    var hiddenCount: Int
}

enum StationTrainPlacement {
    /// まもなく着く、とみなす時間
    static let arrivingWindow: TimeInterval = 180
    /// 1つの行に並べる数
    static let maxPerRow = 3
    /// アイコンの大きさと間隔(画面上のpt)
    static let iconSize = CGSize(width: 24, height: 14)
    static let spacing: CGFloat = 2
    static let rowHeight: CGFloat = 16
    /// 駅の点からの距離(駅名は点の右に出るので、左側に並べる)
    static let gap: CGFloat = 9

    /// 路線1本の、駅に重ねる電車。停車中の電車と、3分以内に次の駅に着く電車だけ。
    static func items(positions: [TrainPosition], line: BoardLine, now: Date, directionOrder: [String]) -> [StationTrainItem] {
        var result: [StationTrainItem] = []
        for position in positions where !position.isWaitingToDepart {
            let rank = directionOrder.firstIndex(of: position.direction) ?? directionOrder.count
            let badge = TrainBoard.typeBadge(position.trainType)
            let label = badge.label + String(position.destination.prefix(1))
            if position.isStopped {
                guard let stationID = line.stationID(position.fromStation) else { continue }
                result.append(StationTrainItem(trainID: position.id, stationID: stationID, direction: position.direction,
                                               directionRank: rank, platform: position.currentPlatform, label: label,
                                               isExpress: badge.isExpress, tone: position.delay.tone, isStopped: true,
                                               secondsToArrival: 0))
            } else if let next = position.upcoming.first, let stationID = line.stationID(next.station) {
                let seconds = next.arrival.timeIntervalSince(now)
                guard seconds >= 0, seconds <= arrivingWindow else { continue }
                result.append(StationTrainItem(trainID: position.id, stationID: stationID, direction: position.direction,
                                               directionRank: rank, platform: next.platform, label: label,
                                               isExpress: badge.isExpress, tone: position.delay.tone, isStopped: false,
                                               secondsToArrival: seconds))
            }
        }
        return result
    }

    /// 1つの駅の電車を並べる。番線がすべての電車で分かるときは番線の順、そうでなければ方面の順に行を分け、
    /// 行の中は停車中を先に、あとは着く順。
    static func slots(_ items: [StationTrainItem]) -> [StationTrainSlot] {
        guard !items.isEmpty else { return [] }
        let usesPlatform = items.allSatisfy { $0.platform != nil }
        let grouped = Dictionary(grouping: items) { item in usesPlatform ? "p:" + (item.platform ?? "") : "d:" + item.direction }
        let keys = grouped.keys.sorted { a, b in
            let ia = grouped[a]?.first
            let ib = grouped[b]?.first
            if usesPlatform {
                let pa = Int(ia?.platform ?? "") ?? Int.max
                let pb = Int(ib?.platform ?? "") ?? Int.max
                if pa != pb { return pa < pb }
            } else {
                let ra = ia?.directionRank ?? Int.max
                let rb = ib?.directionRank ?? Int.max
                if ra != rb { return ra < rb }
            }
            return a < b
        }
        var result: [StationTrainSlot] = []
        for (row, key) in keys.enumerated() {
            let sorted = (grouped[key] ?? []).sorted { a, b in
                if a.isStopped != b.isStopped { return a.isStopped }
                if a.secondsToArrival != b.secondsToArrival { return a.secondsToArrival < b.secondsToArrival }
                return a.trainID < b.trainID
            }
            let shown = Array(sorted.prefix(maxPerRow))
            for (column, item) in shown.enumerated() {
                let hidden = column == shown.count - 1 ? sorted.count - shown.count : 0
                result.append(StationTrainSlot(item: item, row: row, column: column, rowCount: keys.count, hiddenCount: hidden))
            }
        }
        return result
    }

    /// すべての駅の並び(駅ID → 並び)
    static func place(_ items: [StationTrainItem]) -> [String: [StationTrainSlot]] {
        Dictionary(grouping: items, by: \.stationID).mapValues { slots($0) }
    }

    /// アイコンの中心の、駅の点からのずれ(画面上のpt)。駅の点の左側に、行を上下に並べる。
    static func offset(of slot: StationTrainSlot) -> CGPoint {
        let x = -(gap + iconSize.width / 2 + CGFloat(slot.column) * (iconSize.width + spacing))
        let y = (CGFloat(slot.row) - CGFloat(slot.rowCount - 1) / 2) * rowHeight
        return CGPoint(x: x, y: y)
    }
}

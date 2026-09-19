import Foundation

/// 地図に描く路線の形。odpt:Railway の駅の順に、odpt:Station の緯度経度を結んだもの。
/// 一度作ったら端末に保存し、毎回は取得しない。
struct RailwayShape: Codable, Equatable {
    struct Stop: Codable, Equatable {
        var stationID: String
        var name: String
        var latitude: Double
        var longitude: Double
    }

    var railwayID: String
    /// 路線本来の色 (odpt:color、例 "#FF535F")。ない路線もある。
    var colorHex: String?
    /// 駅の順に並んだ点
    var stops: [Stop]
    /// 緯度経度が取れなかった駅
    var missingStationIDs: [String]

    /// 駅が2つ以上あれば線として描ける
    var isDrawable: Bool { stops.count >= 2 }

    static func build(railway: ODPTRailway, stations: [ODPTStation]) -> RailwayShape {
        let byID = Dictionary(stations.map { ($0.sameAs, $0) }, uniquingKeysWith: { first, _ in first })
        var stops: [Stop] = []
        var missing: [String] = []
        let order = (railway.stationOrder ?? []).sorted { $0.index < $1.index }
        if order.isEmpty {
            // 駅の順序がない路線は、取得した順に並べる
            for station in stations {
                if let latitude = station.latitude, let longitude = station.longitude {
                    stops.append(Stop(stationID: station.sameAs, name: station.name, latitude: latitude, longitude: longitude))
                } else {
                    missing.append(station.sameAs)
                }
            }
        }
        for entry in order {
            if let station = byID[entry.station], let latitude = station.latitude, let longitude = station.longitude {
                stops.append(Stop(stationID: entry.station, name: entry.stationTitle?.text ?? station.name,
                                  latitude: latitude, longitude: longitude))
            } else {
                missing.append(entry.station)
            }
        }
        return RailwayShape(railwayID: railway.sameAs, colorHex: railway.color, stops: stops, missingStationIDs: missing)
    }
}

/// 登録路線全体の要約(電車タブの一番上に1行で出す)
enum TrainSummary {
    /// 状況が悪いほど小さい値。並べ替えに使う。
    static func severity(_ status: TrainStatus?) -> Int {
        switch status {
        case .suspended?: return 0
        case .delay?: return 1
        case .other?: return 2
        case .normal?: return 3
        case nil: return 4
        }
    }

    static func sorted(_ lines: [RegisteredLine], items: [TrainInfoItem]) -> [RegisteredLine] {
        let status = Dictionary(items.map { ($0.railwayID, $0.status) }, uniquingKeysWith: { first, _ in first })
        return lines.enumerated().sorted { a, b in
            let sa = severity(status[a.element.railwayID])
            let sb = severity(status[b.element.railwayID])
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)
    }

    static func text(lines: [RegisteredLine], items: [TrainInfoItem]) -> String {
        guard !lines.isEmpty else { return "路線が登録されていません" }
        let known = lines.compactMap { line in items.first { $0.railwayID == line.railwayID }?.status }
        guard !known.isEmpty else { return "運行情報は未取得です" }
        let suspended = known.filter { $0 == .suspended }.count
        let delayed = known.filter { $0 == .delay }.count
        let other = known.filter { $0 == .other }.count
        var parts: [String] = []
        if suspended > 0 { parts.append("\(suspended)路線で見合わせ・運休") }
        if delayed > 0 { parts.append("\(delayed)路線で遅延") }
        if other > 0 { parts.append("\(other)路線で情報あり") }
        if parts.isEmpty {
            return known.count == lines.count ? "登録路線はすべて平常運転" : "取得できた\(known.count)路線はすべて平常運転"
        }
        return parts.joined(separator: "、")
    }
}

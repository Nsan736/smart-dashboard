import CoreLocation
import Foundation

/// 緯度経度の点(保存・比較しやすいように、CLLocationCoordinate2D の代わりに使う)
struct GeoPoint: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double

    init(_ latitude: Double, _ longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(coordinate.latitude, coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    enum CodingKeys: String, CodingKey {
        case latitude = "a"
        case longitude = "o"
    }
}

/// 数km程度の範囲の計算。原点のまわりを平面とみなす(誤差は数kmで0.1%未満)。
enum GeoMath {
    static let earthRadius = 6_371_000.0

    /// 2点間の距離(m)
    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let p = local(b, origin: a)
        return (p.x * p.x + p.y * p.y).squareRoot()
    }

    /// origin を原点にした平面の座標(m)。x は東、y は北。
    static func local(_ point: GeoPoint, origin: GeoPoint) -> (x: Double, y: Double) {
        let latitude = (point.latitude + origin.latitude) / 2 * .pi / 180
        let x = (point.longitude - origin.longitude) * .pi / 180 * earthRadius * cos(latitude)
        let y = (point.latitude - origin.latitude) * .pi / 180 * earthRadius
        return (x, y)
    }

    /// origin から東へ east m、北へ north m ずらした点
    static func offset(_ origin: GeoPoint, east: Double, north: Double) -> GeoPoint {
        let latitude = origin.latitude + north / earthRadius * 180 / .pi
        let middle = (latitude + origin.latitude) / 2 * .pi / 180
        let longitude = origin.longitude + east / (earthRadius * cos(middle)) * 180 / .pi
        return GeoPoint(latitude, longitude)
    }
}

/// 線の上に投影した結果
struct TrackProjection: Equatable {
    /// 線の始点から、線に沿った距離(m)
    var along: Double
    /// 線からの距離(m)
    var lateral: Double
    /// 線の上の点
    var point: GeoPoint
    /// 何番目の区間か
    var segment: Int
}

/// 折れ線。線に沿った距離で位置を表す。
struct GeoPath: Equatable {
    let points: [GeoPoint]
    /// 各点までの、線に沿った距離(m)
    let cumulative: [Double]

    init(_ points: [GeoPoint]) {
        self.points = points
        var total = 0.0
        var list: [Double] = []
        for (index, point) in points.enumerated() {
            if index > 0 { total += GeoMath.distance(points[index - 1], point) }
            list.append(total)
        }
        cumulative = list
    }

    var length: Double { cumulative.last ?? 0 }

    /// 線に沿った距離の位置にある点
    func point(atAlong along: Double) -> GeoPoint? {
        guard let first = points.first else { return nil }
        guard points.count >= 2 else { return first }
        let d = min(max(along, 0), length)
        var index = 0
        while index < points.count - 2, cumulative[index + 1] < d { index += 1 }
        let span = cumulative[index + 1] - cumulative[index]
        let t = span > 0 ? (d - cumulative[index]) / span : 0
        let a = points[index]
        let b = points[index + 1]
        return GeoPoint(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t)
    }

    /// 線に一番近い点に投影する
    func project(_ point: GeoPoint) -> TrackProjection? {
        guard points.count >= 2 else { return nil }
        var best: TrackProjection?
        for index in 0..<(points.count - 1) {
            // 点を原点にした平面で、区間への最短の位置を求める
            let a = GeoMath.local(points[index], origin: point)
            let b = GeoMath.local(points[index + 1], origin: point)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            let t = length2 > 0 ? min(max(-(a.x * dx + a.y * dy) / length2, 0), 1) : 0
            let cx = a.x + dx * t
            let cy = a.y + dy * t
            let lateral = (cx * cx + cy * cy).squareRoot()
            if best == nil || lateral < best!.lateral {
                let along = cumulative[index] + (cumulative[index + 1] - cumulative[index]) * t
                let p = points[index]
                let q = points[index + 1]
                best = TrackProjection(along: along, lateral: lateral,
                                       point: GeoPoint(p.latitude + (q.latitude - p.latitude) * t, p.longitude + (q.longitude - p.longitude) * t),
                                       segment: index)
            }
        }
        return best
    }

    /// 線に沿った距離 from〜to の部分の点(端は補間する)
    func subpath(from: Double, to: Double) -> [GeoPoint] {
        let low = max(0, min(from, to))
        let high = min(length, max(from, to))
        guard high > low, let start = point(atAlong: low), let end = point(atAlong: high) else { return [] }
        var result = [start]
        for index in points.indices where cumulative[index] > low && cumulative[index] < high {
            result.append(points[index])
        }
        result.append(end)
        return result
    }
}

/// 判定に使う駅
struct RideStation: Equatable {
    var stationID: String
    var name: String
    /// 線の始点からの距離(m)
    var along: Double
}

/// 判定に使う路線。路線の形(駅を結んだ線)から作る。事業者には依存しない。
struct RideLine: Equatable {
    var railwayID: String
    var name: String
    var path: GeoPath
    var stations: [RideStation]

    init(railwayID: String, name: String, stations: [(id: String, name: String, point: GeoPoint)]) {
        self.railwayID = railwayID
        self.name = name
        let path = GeoPath(stations.map { $0.point })
        self.path = path
        self.stations = stations.enumerated().map { RideStation(stationID: $0.element.id, name: $0.element.name, along: path.cumulative[$0.offset]) }
    }

    static func make(shape: RailwayShape, name: String) -> RideLine? {
        guard shape.isDrawable else { return nil }
        return RideLine(railwayID: shape.railwayID, name: name,
                        stations: shape.stops.map { (id: $0.stationID, name: $0.name, point: GeoPoint($0.latitude, $0.longitude)) })
    }

    /// 駅の位置(線に沿った距離)。環状線などで同じ駅が2回出てくるときは、near に近いほう。
    func stationAlong(_ stationID: String, near: Double? = nil) -> Double? {
        let candidates = stations.filter { $0.stationID == stationID }.map(\.along)
        guard let near else { return candidates.first }
        return candidates.min { abs($0 - near) < abs($1 - near) }
    }

    /// 2つの駅の位置の組で、互いに一番近いもの
    func alongPair(_ fromID: String, _ toID: String) -> (from: Double, to: Double)? {
        let froms = stations.filter { $0.stationID == fromID }.map(\.along)
        let tos = stations.filter { $0.stationID == toID }.map(\.along)
        var best: (from: Double, to: Double)?
        for f in froms {
            for t in tos where best == nil || abs(t - f) < abs(best!.to - best!.from) { best = (f, t) }
        }
        return best
    }

    /// 線に沿った距離で一番近い駅
    func nearestStation(toAlong along: Double) -> (station: RideStation, distance: Double)? {
        stations.map { ($0, abs($0.along - along)) }.min { $0.1 < $1.1 }.map { (station: $0.0, distance: $0.1) }
    }

    /// これから向かう駅(進む向きで、along より先にある駅を近い順に)
    func stationsAhead(of along: Double, ascending: Bool) -> [RideStation] {
        if ascending { return stations.filter { $0.along > along + 1 }.sorted { $0.along < $1.along } }
        return stations.filter { $0.along < along - 1 }.sorted { $0.along > $1.along }
    }

    /// その向きの終点の駅名(「◯◯方面」に使う)
    func terminalName(ascending: Bool) -> String {
        (ascending ? stations.last : stations.first)?.name ?? ""
    }
}

/// 照合に使う列車(時刻表から計算し、遅れで補正した位置を、線に沿った距離に直したもの)
struct RideTrainCandidate: Equatable {
    struct Stop: Equatable {
        var stationID: String
        var name: String
        var arrival: Date
        var along: Double?
    }

    var id: String
    var railwayID: String
    var number: String
    var trainType: String
    var destination: String
    var delay: DelaySource
    /// 線に沿った距離(m)
    var along: Double
    /// 駅の順(線の始点から終点)に進んでいるか。分からなければ nil。
    var isAscending: Bool?
    var isStopped: Bool
    /// これから止まる駅
    var upcoming: [Stop]

    var label: String {
        let type = trainType.isEmpty ? "" : trainType + " "
        return type + (destination.isEmpty ? "行先不明" : destination + "行")
    }

    /// 時刻表から計算した列車の位置を、判定に使う形にする
    static func make(position: TrainPosition, line: BoardLine, ride: RideLine) -> RideTrainCandidate? {
        guard !position.isWaitingToDepart,
              let fromID = line.stationID(position.fromStation), let toID = line.stationID(position.toStation),
              let pair = ride.alongPair(fromID, toID) else { return nil }
        let fraction = min(1, max(0, position.fraction))
        let along = pair.from + (pair.to - pair.from) * fraction
        var ascending: Bool? = pair.to != pair.from ? pair.to > pair.from : nil
        var previous = along
        var stops: [Stop] = []
        for stop in position.upcoming {
            guard let id = line.stationID(stop.station) else { continue }
            let stationAlong = ride.stationAlong(id, near: previous)
            if ascending == nil, let stationAlong, abs(stationAlong - along) > 1 { ascending = stationAlong > along }
            if let stationAlong { previous = stationAlong }
            stops.append(Stop(stationID: id, name: line.stationName(stop.station), arrival: stop.arrival, along: stationAlong))
        }
        return RideTrainCandidate(id: position.id, railwayID: line.railwayID, number: position.number, trainType: position.trainType,
                                  destination: position.destination, delay: position.delay, along: along, isAscending: ascending,
                                  isStopped: position.isStopped, upcoming: stops)
    }
}

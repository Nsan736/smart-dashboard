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
        // 点の位置ちょうどなら、その点をそのまま返す(補間の丸めの誤差を出さない)
        if let exact = cumulative.firstIndex(of: d) { return points[exact] }
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

    /// 線に沿った距離 minAlong より先で、点を線に合わせる(駅の位置の合わせ込み)。
    /// 線に沿って並べたときの谷(前後より近い所)のうち、一番近いものから window 以内で、一番手前のもの。
    /// 環状の区間のように線が近くを2回通るとき、先の区間へ飛ばないようにする。
    func snap(_ point: GeoPoint, after minAlong: Double = 0, window: Double = 100) -> TrackProjection? {
        guard points.count >= 2 else { return nil }
        var candidates: [TrackProjection] = []
        for index in 0..<(points.count - 1) where cumulative[index + 1] >= minAlong {
            let a = GeoMath.local(points[index], origin: point)
            let b = GeoMath.local(points[index + 1], origin: point)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length2 = dx * dx + dy * dy
            let span = cumulative[index + 1] - cumulative[index]
            var t = length2 > 0 ? min(max(-(a.x * dx + a.y * dy) / length2, 0), 1) : 0
            var along = cumulative[index] + span * t
            if along < minAlong {
                along = minAlong
                t = span > 0 ? min(1, max(0, (minAlong - cumulative[index]) / span)) : 0
            }
            let cx = a.x + dx * t
            let cy = a.y + dy * t
            let p = points[index]
            let q = points[index + 1]
            candidates.append(TrackProjection(along: along, lateral: (cx * cx + cy * cy).squareRoot(),
                                              point: GeoPoint(p.latitude + (q.latitude - p.latitude) * t, p.longitude + (q.longitude - p.longitude) * t),
                                              segment: index))
        }
        var valleys: [TrackProjection] = []
        for (index, candidate) in candidates.enumerated() {
            let before = index > 0 ? candidates[index - 1].lateral : .infinity
            let after = index + 1 < candidates.count ? candidates[index + 1].lateral : .infinity
            if candidate.lateral <= before, candidate.lateral <= after { valleys.append(candidate) }
        }
        guard let nearest = valleys.map(\.lateral).min() else { return candidates.min { $0.lateral < $1.lateral } }
        return valleys.first { $0.lateral <= nearest + window }
    }

    /// 線に沿った距離 a から b へ向かうときに通る、途中の点(両端は含まない。a > b なら逆の順)
    func interiorPoints(from a: Double, to b: Double) -> [GeoPoint] {
        let low = min(a, b)
        let high = max(a, b)
        let inside = points.indices.filter { cumulative[$0] > low && cumulative[$0] < high }.map { points[$0] }
        return a <= b ? inside : Array(inside.reversed())
    }

    /// その位置での線の向き(度。北が0、時計回り)。forward が false なら逆向き。
    func bearing(atAlong along: Double, forward: Bool) -> Double? {
        guard let a = point(atAlong: along - 10), let b = point(atAlong: along + 10) else { return nil }
        return forward ? MapBearing.degrees(from: a.coordinate, to: b.coordinate) : MapBearing.degrees(from: b.coordinate, to: a.coordinate)
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
    /// 駅の座標を線路の上に合わせたときに動かした距離(m)。線路の形がないときは0。
    var offset: Double = 0
}

/// 判定に使う路線。事業者には依存しない。
/// 線路の形(同梱した国土数値情報の線)があれば、それを線にして、駅を線路の上の最も近い点に合わせる。
/// なければ、駅を結んだ直線を線にする。
struct RideLine: Equatable {
    var railwayID: String
    var name: String
    var path: GeoPath
    var stations: [RideStation]
    /// 実際の線路の形を使っているか
    var usesTrack: Bool

    init(railwayID: String, name: String, stations: [(id: String, name: String, point: GeoPoint)], track: [GeoPoint]? = nil) {
        self.railwayID = railwayID
        self.name = name
        if let track, track.count >= 2 {
            let path = GeoPath(Self.oriented(track, first: stations.first?.point, last: stations.last?.point))
            var previous = 0.0
            var list: [RideStation] = []
            for station in stations {
                // 駅の順に、前の駅より先で合わせる(同じ駅を2回通る路線でも、順番を保つ)
                if let snapped = path.snap(station.point, after: previous) {
                    list.append(RideStation(stationID: station.id, name: station.name, along: snapped.along, offset: snapped.lateral))
                    previous = snapped.along
                } else {
                    list.append(RideStation(stationID: station.id, name: station.name, along: previous,
                                            offset: path.points.last.map { GeoMath.distance($0, station.point) } ?? 0))
                }
            }
            self.path = path
            self.stations = list
            usesTrack = true
        } else {
            let path = GeoPath(stations.map { $0.point })
            self.path = path
            self.stations = stations.enumerated().map { RideStation(stationID: $0.element.id, name: $0.element.name, along: path.cumulative[$0.offset]) }
            usesTrack = false
        }
    }

    /// 線路の形の向きを、駅の順(最初の駅が始点の側)にそろえる。
    /// N02 の駅だけで作った線路の形は、ODPT の駅の順と逆向きのことがあるため。
    static func oriented(_ track: [GeoPoint], first: GeoPoint?, last: GeoPoint?) -> [GeoPoint] {
        guard let first, let last, track.count >= 2 else { return track }
        let path = GeoPath(track)
        guard let a = path.project(first), let b = path.project(last), a.along > b.along else { return track }
        return track.reversed()
    }

    /// track: 同梱した線路の形(RailwayTrackCatalog)。なければ駅を結んだ直線。
    static func make(shape: RailwayShape, name: String, track: [GeoPoint]? = nil) -> RideLine? {
        guard shape.isDrawable else { return nil }
        return RideLine(railwayID: shape.railwayID, name: name,
                        stations: shape.stops.map { (id: $0.stationID, name: $0.name, point: GeoPoint($0.latitude, $0.longitude)) },
                        track: track)
    }

    /// 線路の上に合わせた駅の位置(同じ駅が2回出てくる路線では、最初のもの)
    func stationPoint(_ stationID: String) -> GeoPoint? {
        stations.first { $0.stationID == stationID }.flatMap { path.point(atAlong: $0.along) }
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

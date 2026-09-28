import Foundation

/// 徒歩の時間の設定(駅まで歩く時間、乗り換えで歩く時間に使う)
struct WalkSettings: Equatable {
    /// 直線距離にかける係数(道なりの距離の目安)
    var routeFactor = 1.3
    /// 歩く速さ(km/h)
    var speedKmh = 4.8
    /// 駅の中の移動(改札からホームまで)の時間(分)
    var accessMinutes = 2.0
    /// 「急げば」のときの速さの倍率
    var hurryMultiplier = 1.5

    var speedMetersPerSecond: Double { max(0.5, speedKmh) / 3.6 }
}

/// 経路の検索と駅の検索に使う駅(事業者ごとの odpt:Station から作る)
struct TransitStation: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var railwayID: String
    var latitude: Double?
    var longitude: Double?
    /// 乗り換えできる駅(odpt:connectingStation。他社の駅を含む)
    var connecting: [String] = []

    var point: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude, longitude)
    }
}

extension TransitStation {
    /// 路線の分からない駅は使わない
    init?(_ station: ODPTStation) {
        guard let railway = station.railway else { return nil }
        self.init(id: station.sameAs, name: station.name, railwayID: railway, latitude: station.latitude,
                  longitude: station.longitude, connecting: station.connectingStation ?? [])
    }
}

/// 駅名でまとめた駅(乗り換えでつながる、同じ名前の駅)。行きたい駅の検索に使う。
struct StationGroup: Equatable, Hashable, Identifiable {
    var name: String
    var stationIDs: [String]
    var railwayIDs: [String]

    var id: String { stationIDs.joined(separator: ",") }
}

/// 駅の一覧と、乗り換えの関係。通信はしない(一覧は TrainStore が長期間キャッシュする)。
///
/// 乗り換えは odpt:connectingStation を使う(駅IDまで分かるので確実)。片方の駅にだけ書かれている場合も、両方向に使う。
/// どちらにも書かれていない同じ名前の駅は、500m以内なら乗り換えとみなす(connectingStation を提供しない事業者のため)。
struct TransitDirectory: Equatable {
    private(set) var stations: [String: TransitStation]
    private(set) var railwayNames: [String: String]
    /// 乗り換えの相手(駅ID → 駅ID)
    private(set) var links: [String: [String]]

    /// 同じ名前の駅を乗り換えとみなす距離(connectingStation がない場合)
    static let sameNameDistance = 500.0
    /// 乗り換えの時間に含まれる歩く距離。これより離れた駅どうしは、その分の歩く時間を足す(蔵前、三田など)。
    static let includedWalkDistance = 150.0

    init(stations list: [TransitStation], railwayNames: [String: String]) {
        var byID: [String: TransitStation] = [:]
        for station in list where byID[station.id] == nil { byID[station.id] = station }
        stations = byID
        self.railwayNames = railwayNames
        var sets: [String: Set<String>] = [:]
        for station in byID.values {
            for other in station.connecting where other != station.id && byID[other] != nil {
                sets[station.id, default: []].insert(other)
                sets[other, default: []].insert(station.id)
            }
        }
        let byName = Dictionary(grouping: byID.values, by: \.name)
        for group in byName.values where group.count > 1 {
            for a in group {
                for b in group where a.id < b.id && a.railwayID != b.railwayID {
                    guard !(sets[a.id]?.contains(b.id) ?? false), let pa = a.point, let pb = b.point,
                          GeoMath.distance(pa, pb) <= Self.sameNameDistance else { continue }
                    sets[a.id, default: []].insert(b.id)
                    sets[b.id, default: []].insert(a.id)
                }
            }
        }
        links = sets.mapValues { $0.sorted() }
    }

    func station(_ id: String) -> TransitStation? { stations[id] }

    func name(of id: String) -> String { stations[id]?.name ?? ODPTID.tail(id) }

    func railwayName(of id: String) -> String { railwayNames[id] ?? ODPTID.tail(id) }

    func transferTargets(from id: String) -> [String] { links[id] ?? [] }

    /// 乗り換えの時間(秒)。同じ駅なら設定の時間だけ、離れた駅どうしは、150mを超えた分の歩く時間を足す。
    func transferSeconds(from a: String, to b: String, transferMinutes: Double, walk: WalkSettings) -> TimeInterval {
        var seconds = max(0, transferMinutes) * 60
        if a != b, let pa = stations[a]?.point, let pb = stations[b]?.point {
            let extra = GeoMath.distance(pa, pb) - Self.includedWalkDistance
            if extra > 0 { seconds += extra * walk.routeFactor / walk.speedMetersPerSecond }
        }
        return seconds
    }

    /// 乗り換えでつながる同じ名前の駅をまとめる
    func groups() -> [StationGroup] {
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current { current = next }
            return current
        }
        for id in stations.keys { parent[id] = id }
        for (id, targets) in links {
            for target in targets where stations[id]?.name == stations[target]?.name {
                let a = root(id)
                let b = root(target)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        let grouped = Dictionary(grouping: stations.keys, by: root)
        return grouped.values.map { ids in
            let sorted = ids.sorted()
            let railways = sorted.compactMap { stations[$0]?.railwayID }
            var seen = Set<String>()
            return StationGroup(name: stations[sorted[0]]?.name ?? ODPTID.tail(sorted[0]), stationIDs: sorted,
                                railwayIDs: railways.filter { seen.insert($0).inserted })
        }
        .sorted { $0.name != $1.name ? $0.name < $1.name : $0.id < $1.id }
    }

    /// その駅を含むグループ
    func group(containing id: String) -> StationGroup? {
        groups().first { $0.stationIDs.contains(id) }
    }

    /// 駅名(ひらがな・カタカナ・全角半角の違いを吸収)と、駅IDの末尾(ローマ字)で探す。前方一致を先に並べる。
    func search(_ query: String, in list: [StationGroup]? = nil) -> [StationGroup] {
        let all = list ?? groups()
        let key = ToolSearch.normalize(query)
        guard !key.isEmpty else { return all }
        let matched = all.compactMap { group -> (StationGroup, Int)? in
            let name = ToolSearch.normalize(group.name)
            let romaji = group.stationIDs.map { ODPTID.tail($0).lowercased() }
            if name.hasPrefix(key) || romaji.contains(where: { $0.hasPrefix(key) }) { return (group, 0) }
            if name.contains(key) || romaji.contains(where: { $0.contains(key) }) { return (group, 1) }
            return nil
        }
        return matched.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }.map { $0.0 }
    }

    /// 一番近い駅。railways を指定したときは、その路線の駅だけ。
    func nearest(to point: GeoPoint, railways: Set<String>? = nil) -> (station: TransitStation, distance: Double)? {
        var best: (station: TransitStation, distance: Double)?
        for station in stations.values {
            if let railways, !railways.contains(station.railwayID) { continue }
            guard let p = station.point else { continue }
            let distance = GeoMath.distance(point, p)
            if best == nil || distance < best!.distance || (distance == best!.distance && station.id < best!.station.id) {
                best = (station, distance)
            }
        }
        return best
    }

    /// 路線どうしのつながり(乗り換えできる路線)。allowed を指定したときは、その路線だけ(列車ごとの時刻表がある路線など)。
    /// 事業者をまたぐ乗り換えも、駅の乗り換えの関係(odpt:connectingStation と、同じ名前で500m以内)から作る。
    func railwayGraph(allowed: Set<String>? = nil) -> [String: Set<String>] {
        var graph: [String: Set<String>] = [:]
        for station in stations.values where allowed?.contains(station.railwayID) ?? true {
            graph[station.railwayID, default: []] = graph[station.railwayID, default: []]
        }
        for (id, targets) in links {
            guard let a = stations[id]?.railwayID, allowed?.contains(a) ?? true else { continue }
            for target in targets {
                guard let b = stations[target]?.railwayID, a != b, allowed?.contains(b) ?? true else { continue }
                graph[a, default: []].insert(b)
            }
        }
        return graph
    }

    /// 出発の路線から到着の路線まで、乗り換えの少ない経路に出てくる路線(出発に近い順)。つながらなければ空。
    func railwaysOnShortestPaths(from origins: Set<String>, to destinations: Set<String>, allowed: Set<String>? = nil) -> [String] {
        let graph = railwayGraph(allowed: allowed)
        let starts = allowed.map { origins.intersection($0) } ?? origins
        let goals = allowed.map { destinations.intersection($0) } ?? destinations
        func distances(from starts: Set<String>) -> [String: Int] {
            var result: [String: Int] = [:]
            var queue: [String] = []
            for start in starts.sorted() {
                result[start] = 0
                queue.append(start)
            }
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                for next in (graph[current] ?? []).sorted() where result[next] == nil {
                    result[next] = (result[current] ?? 0) + 1
                    queue.append(next)
                }
            }
            return result
        }
        let fromOrigin = distances(from: starts)
        let toDestination = distances(from: goals)
        guard let shortest = goals.compactMap({ fromOrigin[$0] }).min() else { return [] }
        return fromOrigin.keys
            .filter { railway in
                guard let a = fromOrigin[railway], let b = toDestination[railway] else { return false }
                return a + b == shortest
            }
            .sorted { (fromOrigin[$0] ?? 0, $0) < (fromOrigin[$1] ?? 0, $1) }
    }
}

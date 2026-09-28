import Foundation

/// 検索の対象の駅(事業者ごとの odpt:Station から作る)
struct SearchStation: Equatable, Identifiable {
    var id: String
    var name: String
    var nameEn: String?
    /// 読み仮名(東京メトロの駅だけ)
    var reading: String?
    /// 駅ナンバリング (odpt:stationCode)
    var code: String?
    var railwayID: String
    var railwayName: String
    var operatorID: String
    var operatorName: String
    /// 路線の色 (odpt:color)
    var colorHex: String?
    var point: GeoPoint?
}

/// 検索の対象の路線
struct SearchRailway: Equatable, Identifiable {
    var id: String
    var name: String
    var nameEn: String?
    var operatorID: String
    var operatorName: String
    var colorHex: String?
}

/// 同じ名前の駅をまとめたもの(例: 新宿 → 都営の新宿線・大江戸線、東京メトロの丸ノ内線…)
struct StationSearchGroup: Equatable, Identifiable {
    var name: String
    /// 登録済みの路線の駅が先
    var stations: [SearchStation]

    var id: String { name }
}

/// 一致の強さ。小さいほど強い。
enum StationSearchMatch: Int, Comparable {
    case exact = 0
    case prefix = 1
    case contains = 2

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// 駅と路線の検索。索引(正規化した名前・英語名・読み仮名・駅ナンバリング・ID)を先に作っておき、入力のたびには照合だけをする。通信しない。
///
/// 正規化は小ツールの検索と同じ(`ToolSearch.normalize`: 小文字、全角→半角、カタカナ→ひらがな、空白・長音・中点を除く)。
/// そのうえで、英数字だけを残した形(「I-13」→「i13」、「Nishi-magome」→「nishimagome」)でも比べる。
struct StationSearchIndex {
    private struct Keys {
        /// 正規化した文字列
        var full: [String]
        /// 記号を除いた形(英数字と文字だけ)
        var compact: [String]

        init(_ texts: [String?]) {
            let normalized = texts.compactMap { $0 }.map { ToolSearch.normalize($0) }.filter { !$0.isEmpty }
            full = Array(Set(normalized))
            compact = Array(Set(normalized.map(StationSearchIndex.compact).filter { !$0.isEmpty }))
        }

        func match(_ query: String, _ compactQuery: String) -> StationSearchMatch? {
            var best: StationSearchMatch?
            func consider(_ keys: [String], _ q: String) {
                guard !q.isEmpty else { return }
                for key in keys {
                    let m: StationSearchMatch? = key == q ? .exact : key.hasPrefix(q) ? .prefix : key.contains(q) ? .contains : nil
                    if let m, best == nil || m < best! { best = m }
                    if best == .exact { return }
                }
            }
            consider(full, query)
            consider(compact, compactQuery)
            return best
        }
    }

    private(set) var groups: [StationSearchGroup]
    private(set) var railways: [SearchRailway]
    private let groupKeys: [Keys]
    private let railwayKeys: [Keys]
    /// グループの名前を正規化したもの(名前で引くときに使う)
    private let nameKeys: [String]

    var stationCount: Int { groups.reduce(0) { $0 + $1.stations.count } }

    init(stations: [SearchStation], railways: [SearchRailway]) {
        var seen = Set<String>()
        let unique = stations.filter { seen.insert($0.id).inserted }
        let grouped = Dictionary(grouping: unique) { ToolSearch.normalize($0.name) }
        let groups = grouped.values.map { list -> StationSearchGroup in
            let sorted = list.sorted { ($0.operatorID, $0.railwayName, $0.id) < ($1.operatorID, $1.railwayName, $1.id) }
            return StationSearchGroup(name: sorted[0].name, stations: sorted)
        }
        .sorted { $0.name < $1.name }
        self.groups = groups
        nameKeys = groups.map { ToolSearch.normalize($0.name) }
        groupKeys = groups.map { group in
            var texts: [String?] = [group.name]
            for station in group.stations {
                texts += [station.nameEn, station.reading, station.code, station.id, Self.shortID(station.id)]
            }
            return Keys(texts)
        }
        self.railways = railways.sorted { ($0.operatorID, $0.name) < ($1.operatorID, $1.name) }
        railwayKeys = self.railways.map { Keys([$0.name, $0.nameEn, $0.id, Self.shortID($0.id)]) }
    }

    /// 記号を除いた形(英数字と文字だけ)
    static func compact(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// "odpt.Station:TokyoMetro.Marunouchi.Shinjuku" → "TokyoMetro.Marunouchi.Shinjuku"
    static func shortID(_ id: String) -> String {
        id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
    }

    /// 検索する。並びは、完全一致 → 前方一致 → 部分一致、同じなら登録済みの路線(の駅)を先に、あとは名前の順。
    /// registered: 登録済みの路線のID。グループの中の駅も、登録済みの路線の駅を先にする。
    func search(_ query: String, registered: Set<String> = [], limit: Int = 60)
        -> (groups: [StationSearchGroup], railways: [SearchRailway]) {
        let q = ToolSearch.normalize(query)
        let cq = Self.compact(q)
        guard !q.isEmpty else { return ([], []) }
        var foundGroups: [(StationSearchGroup, StationSearchMatch, Bool)] = []
        for (index, group) in groups.enumerated() {
            guard let match = groupKeys[index].match(q, cq) else { continue }
            let hasRegistered = group.stations.contains { registered.contains($0.railwayID) }
            foundGroups.append((Self.ordered(group, registered: registered), match, hasRegistered))
        }
        foundGroups.sort { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 }
            return a.0.name < b.0.name
        }
        var foundRailways: [(SearchRailway, StationSearchMatch, Bool)] = []
        for (index, railway) in railways.enumerated() {
            guard let match = railwayKeys[index].match(q, cq) else { continue }
            foundRailways.append((railway, match, registered.contains(railway.id)))
        }
        foundRailways.sort { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 }
            return a.0.name < b.0.name
        }
        return (foundGroups.prefix(limit).map { $0.0 }, foundRailways.prefix(limit).map { $0.0 })
    }

    /// 名前でグループを引く(最近検索した駅の表示に使う)
    func group(named name: String, registered: Set<String> = []) -> StationSearchGroup? {
        let key = ToolSearch.normalize(name)
        guard let index = nameKeys.firstIndex(of: key) else { return nil }
        return Self.ordered(groups[index], registered: registered)
    }

    /// 駅を引く
    func station(_ id: String) -> SearchStation? {
        for group in groups {
            if let station = group.stations.first(where: { $0.id == id }) { return station }
        }
        return nil
    }

    /// グループの中の駅を、登録済みの路線の駅が先になるように並べる
    static func ordered(_ group: StationSearchGroup, registered: Set<String>) -> StationSearchGroup {
        guard !registered.isEmpty else { return group }
        var copy = group
        let first = group.stations.filter { registered.contains($0.railwayID) }
        copy.stations = first + group.stations.filter { !registered.contains($0.railwayID) }
        return copy
    }
}

extension StationSearchIndex {
    /// 事業者ごとの駅の一覧と路線から作る。路線の分からない駅と、名前のない駅は入れない。
    static func make(stations: [String: [ODPTStation]], railways: [ODPTRailway], operatorNames: [String: String]) -> StationSearchIndex {
        let railwayByID = Dictionary(railways.map { ($0.sameAs, $0) }, uniquingKeysWith: { first, _ in first })
        var list: [SearchStation] = []
        for (operatorID, items) in stations {
            for station in items {
                guard let railwayID = station.railway else { continue }
                let railway = railwayByID[railwayID]
                let name = station.name
                guard !name.isEmpty else { continue }
                let point = station.latitude.flatMap { lat in station.longitude.map { GeoPoint(lat, $0) } }
                list.append(SearchStation(
                    id: station.sameAs, name: name, nameEn: station.stationTitle?.en, reading: station.stationTitle?.jaHrkt,
                    code: station.stationCode, railwayID: railwayID, railwayName: railway?.name ?? ODPTID.tail(railwayID),
                    operatorID: operatorID, operatorName: operatorNames[operatorID] ?? ODPTID.tail(operatorID),
                    colorHex: railway?.color, point: point))
            }
        }
        let usedOperators = Set(stations.keys)
        let railwayList = railways.filter { usedOperators.contains($0.operatorID) }.map { railway in
            SearchRailway(id: railway.sameAs, name: railway.name, nameEn: railway.railwayTitle?.en, operatorID: railway.operatorID,
                          operatorName: operatorNames[railway.operatorID] ?? ODPTID.tail(railway.operatorID), colorHex: railway.color)
        }
        return StationSearchIndex(stations: list, railways: railwayList)
    }
}

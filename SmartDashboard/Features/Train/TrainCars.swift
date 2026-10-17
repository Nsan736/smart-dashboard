import Foundation

/// 路線ごとの両数の表(Resources/railway_cars.json)。各社の公式サイトで調べた値と、列車を見分ける規則、出典。
/// 同じ内容を docs/railway-cars.md に置いてある。調べ直したら両方を直す。
struct TrainCarCatalog: Equatable {
    /// 列車を見分ける規則。書いてある条件をすべて満たす列車に、cars を使う。上から順に調べ、最初に合ったものを使う。
    struct Rule: Equatable {
        var cars: Int
        /// 停車駅がすべてこの中にある列車(ODPTの駅ID)
        var stopsWithin: Set<String>? = nil
        /// 列車番号の末尾の文字がこのどれか(車両の持ち主を表す文字)
        var numberSuffixes: Set<String>? = nil
        /// 種別の名前(「急行」など)がこのどれか
        var trainTypes: Set<String>? = nil
        /// 行先の駅の名前がこのどれか
        var destinations: Set<String>? = nil
        /// 規則に合っても、両数が確かでない(混在がある)
        var isEstimate = false
        /// 規則の説明(設定とドキュメントに出す)
        var note = ""

        func matches(_ train: LineSchedule.Train, stationIDs: [String]) -> Bool {
            if let stopsWithin {
                let ids = train.stops.compactMap { stationIDs.indices.contains($0.station) ? stationIDs[$0.station] : nil }
                guard !ids.isEmpty, ids.allSatisfy({ stopsWithin.contains($0) }) else { return false }
            }
            if let numberSuffixes {
                guard let last = train.number.last, numberSuffixes.contains(String(last)) else { return false }
            }
            if let trainTypes, !trainTypes.contains(train.trainType) { return false }
            if let destinations, !destinations.contains(train.destination) { return false }
            return true
        }
    }

    struct Source: Equatable {
        var url: String
        /// 確認した日
        var checked: String
    }

    struct Entry: Equatable {
        /// 表示名(設定の一覧に出す)
        var name = ""
        /// 代表の両数(見分けられない列車に使う)
        var cars: Int
        /// 同じ路線に両数の違う列車があり、規則で見分けきれない
        var mixed: Bool
        /// 1列車の両数を公式の資料で確かめられた(確かめられなければ目安)
        var verified = true
        var rules: [Rule]
        /// 調べた内容のまとめ(設定に出す)
        var note: String
        var sources: [Source]
    }

    var fetched: String
    var railways: [String: Entry]

    init(fetched: String = "", railways: [String: Entry]) {
        self.fetched = fetched
        self.railways = railways
    }

    /// 形式: {"fetched": "2026-10-18", "railways": {"odpt.Railway:TokyoMetro.Chiyoda": {"cars": 10, "mixed": false,
    /// "verified": true, "rules": [{"cars": 3, "stopsWithin": [...], "numberSuffix": [...], "trainType": [...], "destination": [...], "estimate": false, "note": ...}],
    /// "note": ..., "sources": [{"url": ..., "checked": "2026-10-18"}]}}}
    init(data: Data) throws {
        struct File: Decodable {
            struct Rule: Decodable {
                let cars: Int
                let stopsWithin: [String]?
                let numberSuffix: [String]?
                let trainType: [String]?
                let destination: [String]?
                let estimate: Bool?
                let note: String?
            }

            struct Source: Decodable {
                let url: String
                let checked: String
            }

            struct Railway: Decodable {
                let name: String?
                let cars: Int
                let mixed: Bool?
                let verified: Bool?
                let rules: [Rule]?
                let note: String?
                let sources: [Source]?
            }

            let fetched: String?
            let railways: [String: Railway]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var railways: [String: Entry] = [:]
        for (id, railway) in file.railways where railway.cars > 0 {
            let rules = (railway.rules ?? []).filter { $0.cars > 0 }.map { rule in
                Rule(cars: rule.cars, stopsWithin: rule.stopsWithin.map { Set($0) }, numberSuffixes: rule.numberSuffix.map { Set($0) },
                     trainTypes: rule.trainType.map { Set($0) }, destinations: rule.destination.map { Set($0) },
                     isEstimate: rule.estimate ?? false, note: rule.note ?? "")
            }
            railways[id] = Entry(name: railway.name ?? "", cars: railway.cars, mixed: railway.mixed ?? false, verified: railway.verified ?? true, rules: rules,
                                 note: railway.note ?? "", sources: (railway.sources ?? []).map { Source(url: $0.url, checked: $0.checked) })
        }
        self.init(fetched: file.fetched ?? "", railways: railways)
    }

    func entry(for railwayID: String) -> Entry? { railways[railwayID] }

    static let bundled: TrainCarCatalog = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "railway_cars", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? TrainCarCatalog(data: data) else {
            return TrainCarCatalog(railways: [:])
        }
        return catalog
    }()

    private final class BundleToken {}
}

/// 列車の両数を決める。優先の順: データの両数 → 設定の路線ごとの上書き → 表の規則 → 表の代表の両数 → 路線の種類ごとの目安。
enum TrainCarResolver {
    struct Result: Equatable {
        var cars: Int
        /// 列車ごとに見分けられず、目安の両数
        var isEstimate: Bool
    }

    struct Context {
        var entry: TrainCarCatalog.Entry?
        /// 設定の路線ごとの上書き
        var override: Int?
        /// 路線の種類ごとの目安(表にない路線)
        var kindDefault: Int

        init(entry: TrainCarCatalog.Entry?, override: Int?, kindDefault: Int) {
            self.entry = entry
            self.override = override
            self.kindDefault = kindDefault
        }

        @MainActor
        init(railwayID: String, kind: RailwayKind, settings: AppSettings, catalog: TrainCarCatalog = .bundled) {
            self.init(entry: catalog.entry(for: railwayID), override: settings.scopeCarOverrides[railwayID],
                      kindDefault: settings.scopeCars(for: kind))
        }
    }

    static func cars(for train: LineSchedule.Train?, schedule: LineSchedule, context: Context) -> Result {
        if let cars = train?.cars, cars > 0 { return Result(cars: cars, isEstimate: false) }
        // 上書きは、利用者が決めた値なので目安とは書かない
        if let override = context.override, override > 0 { return Result(cars: override, isEstimate: false) }
        guard let entry = context.entry else { return Result(cars: context.kindDefault, isEstimate: true) }
        if let train, let rule = entry.rules.first(where: { $0.matches(train, stationIDs: schedule.stationIDs) }) {
            return Result(cars: rule.cars, isEstimate: rule.isEstimate)
        }
        return Result(cars: entry.cars, isEstimate: entry.mixed || !entry.verified)
    }
}

extension BoardLine {
    /// 列車の先頭の、路線の線に沿った距離。路線の線がないか、駅が線にないときは nil。
    func along(of position: TrainPosition) -> Double? {
        guard let ride, let fromID = stationID(position.fromStation), let toID = stationID(position.toStation),
              let pair = ride.alongPair(fromID, toID) else { return nil }
        return pair.from + (pair.to - pair.from) * min(1, max(0, position.fraction))
    }

    /// 列車の先頭のいる区間の線路の高さ。路線の線がなければ nil。
    func trackHeight(of position: TrainPosition, elevated: Double, underground: Double) -> TrackHeightModel.Height? {
        guard let ride, let along = along(of: position) else { return nil }
        return ride.trackHeight(atAlong: along, elevated: elevated, underground: underground)
    }

    /// 列車の両数(スコープと同じ決め方)
    @MainActor
    func cars(of position: TrainPosition, settings: AppSettings) -> TrainCarResolver.Result {
        let context = TrainCarResolver.Context(railwayID: railwayID, kind: RailwayKind.classify(railwayID: railwayID, name: name), settings: settings)
        return TrainCarResolver.cars(for: schedule.trains.first { $0.number == position.number }, schedule: schedule, context: context)
    }
}

import Foundation

/// 気象庁の震度観測点の一覧から、名前・緯度・経度・都道府県番号だけを抜き出してアプリに同梱した表。
/// 通信では取得しない。作り直すときは scripts/update_jma_stations.py を手元で実行する。
struct IntensityStationTable {
    struct Station: Equatable {
        var latitude: Double
        var longitude: Double
        /// 都道府県番号(1〜47)
        var prefecture: Int
    }

    /// 取得日(yyyy-MM-dd)
    let fetched: String
    /// 観測点名 → 位置。観測点名は全国で重複がない(2026-09-20に確認)。
    let stations: [String: Station]

    init(fetched: String, stations: [String: Station]) {
        self.fetched = fetched
        self.stations = stations
    }

    /// 同梱ファイルの形式: {"fetched": "2026-09-20", "stations": [[名前, 緯度, 経度, 都道府県番号], ...]}
    init(data: Data) throws {
        struct Row: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let prefecture: Int

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                name = try container.decode(String.self)
                latitude = try container.decode(Double.self)
                longitude = try container.decode(Double.self)
                prefecture = try container.decode(Int.self)
            }
        }
        struct File: Decodable {
            let fetched: String
            let stations: [Row]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        fetched = file.fetched
        var table: [String: Station] = [:]
        table.reserveCapacity(file.stations.count)
        for row in file.stations {
            table[row.name] = Station(latitude: row.latitude, longitude: row.longitude, prefecture: row.prefecture)
        }
        stations = table
    }

    /// 同梱した表。最初に使うときに一度だけ読む。読めなければ空の表(地図に点が出ないだけで、ほかは動く)。
    static let bundled: IntensityStationTable = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "jma_intensity_stations", withExtension: "json"),
              let data = try? Data(contentsOf: url), let table = try? IntensityStationTable(data: data) else {
            return IntensityStationTable(fetched: "", stations: [:])
        }
        return table
    }()

    private final class BundleToken {}
}

/// 地図に描く、観測点ごとの震度
struct MapIntensityDot: Equatable {
    var latitude: Double
    var longitude: Double
    /// P2P地震情報の震度の値(10=震度1 … 70=震度7)
    var scale: Int
}

enum QuakeMapDots {
    struct Result: Equatable {
        /// 震度の小さい順(あとに描く大きい震度が上に重なる)
        var dots: [MapIntensityDot]
        /// 一覧の観測点名と対応しなかった観測点(地図には出さず、一覧だけに出す)
        var unmatched: [QuakePoint]
    }

    /// 観測点名で位置を対応付ける。同じ観測点が複数あれば、大きいほうの震度を使う。
    static func make(points: [QuakePoint], table: IntensityStationTable) -> Result {
        var best: [String: Int] = [:]
        var unmatched: [QuakePoint] = []
        for point in points where point.scale > 0 {
            if table.stations[point.name] != nil {
                best[point.name] = max(best[point.name] ?? 0, point.scale)
            } else {
                unmatched.append(point)
            }
        }
        let dots = best.compactMap { name, scale -> MapIntensityDot? in
            table.stations[name].map { MapIntensityDot(latitude: $0.latitude, longitude: $0.longitude, scale: scale) }
        }
        .sorted { a, b in
            if a.scale != b.scale { return a.scale < b.scale }
            if a.latitude != b.latitude { return a.latitude < b.latitude }
            return a.longitude < b.longitude
        }
        return Result(dots: dots, unmatched: unmatched)
    }

    /// 凡例に出す震度(大きい順)
    static func legendScales(_ dots: [MapIntensityDot]) -> [Int] {
        Array(Set(dots.map(\.scale))).sorted(by: >)
    }
}

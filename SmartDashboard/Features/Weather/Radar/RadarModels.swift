import Foundation

/// 気象庁の targetTimes_N1.json / N2.json の1要素。
/// 公式のAPIではないため、形式が変わったらデコードに失敗し、画面にその旨を表示する。
struct RadarTargetTime: Decodable, Equatable {
    let basetime: String
    let validtime: String
    let elements: [String]?
}

/// レーダーの1コマ
struct RadarFrame: Equatable, Identifiable, Hashable {
    let basetime: String
    let validtime: String
    let isForecast: Bool

    var id: String { "\(basetime)/\(validtime)" }
    var date: Date? { RadarTimeline.parse(validtime) }
}

enum RadarTimeline {
    static let observedURL = URL(string: "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json")!
    static let forecastURL = URL(string: "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N2.json")!
    static let pageURL = URL(string: "https://www.jma.go.jp/bosai/nowc/")!
    static let element = "hrpns"

    /// 時刻は UTC の yyyyMMddHHmmss
    static func parse(_ text: String) -> Date? {
        guard text.count == 14, text.allSatisfy(\.isNumber) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: text)
    }

    /// 最新の実況
    static func latestObserved(_ observed: [RadarTargetTime]) -> RadarFrame? {
        observed
            .filter { $0.elements?.contains(element) ?? true }
            .filter { parse($0.validtime) != nil && parse($0.basetime) != nil }
            .max { $0.validtime < $1.validtime }
            .map { RadarFrame(basetime: $0.basetime, validtime: $0.validtime, isForecast: false) }
    }

    /// 最新の実況より先の予測(5分刻み、1時間先まで)。最新の basetime のものだけを使う。
    static func forecasts(_ forecast: [RadarTargetTime], after observed: RadarFrame) -> [RadarFrame] {
        let usable = forecast
            .filter { $0.elements?.contains(element) ?? true }
            .filter { parse($0.validtime) != nil && parse($0.basetime) != nil }
        guard let latestBase = usable.map(\.basetime).max() else { return [] }
        return usable
            .filter { $0.basetime == latestBase && $0.validtime > observed.validtime }
            .sorted { $0.validtime < $1.validtime }
            .prefix(12)
            .map { RadarFrame(basetime: $0.basetime, validtime: $0.validtime, isForecast: true) }
    }
}

enum RadarTiles {
    /// タイルが提供されるズーム。実際に確認したところ偶数の 4, 6, 8, 10 だけで、
    /// 奇数や11以上は「空のタイル」が HTTP 200 で返る。
    static let availableZooms = [4, 6, 8, 10]

    /// 表示ズームに対して取得するズーム。間のズームは1つ下の偶数を拡大して使う(通信量も少ない)。
    static func sourceZoom(for z: Int) -> Int {
        let clamped = min(max(z, availableZooms[0]), availableZooms[availableZooms.count - 1])
        return clamped % 2 == 0 ? clamped : clamped - 1
    }

    /// 表示するタイルに対応する、取得元のタイルと、その中で使う範囲(0〜1)
    static func source(for tile: TileCoord) -> (tile: TileCoord, unitRect: CGRect)? {
        let sourceZ = sourceZoom(for: tile.z)
        guard tile.z >= sourceZ else { return nil }
        let shift = tile.z - sourceZ
        let scale = 1 << shift
        let source = TileCoord(z: sourceZ, x: tile.x >> shift, y: tile.y >> shift)
        let size = 1.0 / Double(scale)
        let rect = CGRect(x: Double(tile.x % scale) * size, y: Double(tile.y % scale) * size, width: size, height: size)
        return (source, rect)
    }

    static func url(frame: RadarFrame, tile: TileCoord) -> URL {
        URL(string: "https://www.jma.go.jp/bosai/jmatile/data/nowc/\(frame.basetime)/none/\(frame.validtime)/surf/\(RadarTimeline.element)/\(tile.z)/\(tile.x)/\(tile.y).png")!
    }
}

/// 凡例(降水の強さと色)。気象庁のナウキャストの配色。
struct RadarLegendItem: Identifiable {
    let label: String
    let red: Double
    let green: Double
    let blue: Double
    var id: String { label }

    static let all: [RadarLegendItem] = [
        RadarLegendItem(label: "〜1", red: 242, green: 242, blue: 255),
        RadarLegendItem(label: "1〜5", red: 160, green: 210, blue: 255),
        RadarLegendItem(label: "5〜10", red: 33, green: 140, blue: 255),
        RadarLegendItem(label: "10〜20", red: 0, green: 65, blue: 255),
        RadarLegendItem(label: "20〜30", red: 250, green: 245, blue: 0),
        RadarLegendItem(label: "30〜50", red: 255, green: 153, blue: 0),
        RadarLegendItem(label: "50〜80", red: 255, green: 40, blue: 0),
        RadarLegendItem(label: "80〜", red: 180, green: 0, blue: 104),
    ]
}

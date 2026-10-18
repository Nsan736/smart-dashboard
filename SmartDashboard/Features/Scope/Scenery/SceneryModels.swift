import CoreGraphics
import Foundation

/// 景色の表示の層
enum SceneryLayer: String, CaseIterable, Identifiable, Codable {
    case mountains
    case skyline
    case water
    case places

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mountains: return "山"
        case .skyline: return "稜線"
        case .water: return "海・湖・川"
        case .places: return "地名"
        }
    }

    var symbol: String {
        switch self {
        case .mountains: return "mountain.2"
        case .skyline: return "chart.line.flattrend.xyaxis"
        case .water: return "water.waves"
        case .places: return "mappin.and.ellipse"
        }
    }

    /// 初めてのときにオンにする層(地名は任意)
    static let defaults: [SceneryLayer] = [.mountains, .skyline, .water]

    /// 保存した並び(文字列)から読む。知らないものは捨てる。
    static func decode(_ raw: [String]?) -> [SceneryLayer] {
        guard let raw else { return defaults }
        return allCases.filter { raw.contains($0.rawValue) }
    }
}

/// 景色の範囲(km)の選択肢。150km 以上は、保存するデータ量の目安を出して確かめてから広げる
enum SceneryRadius {
    static let choices = [30, 50, 100, 150, 200, 300, 350]
    static let initial = 100
    static let confirmFrom = 150
    /// 水部・注記(ベクトルタイル)を使う範囲の上限(m)。それより遠くの水面は、地平線の下になることが多いため
    static let vectorLimit = 100_000.0

    static func clamped(_ value: Int) -> Int {
        choices.contains(value) ? value : initial
    }
}

/// 国土地理院「日本の主な山岳標高」(Resources/mountains.json)
struct MountainCatalog {
    struct Entry: Equatable {
        var index: Int
        var name: String
        /// 山頂名(「箱根山」の「神山」など)。なければ空
        var peak: String
        var elevation: Double
        var latitude: Double
        var longitude: Double
        var prefecture: String

        /// 表示名(山頂名があれば「神山(箱根山)」)
        var displayName: String { peak.isEmpty ? name : "\(peak)(\(name))" }
        /// 印に添える短い名前
        var shortName: String { peak.isEmpty ? name : peak }
    }

    var entries: [Entry]
    var version: String
    var fetched: String

    static let empty = MountainCatalog(entries: [], version: "", fetched: "")

    static let bundled: MountainCatalog = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "mountains", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return load(data)
    }()

    private final class BundleToken {}

    /// 形式: {"version": "...", "fetched": "...", "mountains": [[名前, 山頂名, 標高, 緯度, 経度, 都道府県], ...]}
    static func load(_ data: Data) -> MountainCatalog {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["mountains"] as? [[Any]] else { return .empty }
        var entries: [Entry] = []
        for row in rows where row.count >= 6 {
            guard let name = row[0] as? String, let peak = row[1] as? String,
                  let elevation = (row[2] as? NSNumber)?.doubleValue, let latitude = (row[3] as? NSNumber)?.doubleValue,
                  let longitude = (row[4] as? NSNumber)?.doubleValue else { continue }
            entries.append(Entry(index: entries.count, name: name, peak: peak, elevation: elevation, latitude: latitude,
                                 longitude: longitude, prefecture: row[5] as? String ?? ""))
        }
        return MountainCatalog(entries: entries, version: root["version"] as? String ?? "", fetched: root["fetched"] as? String ?? "")
    }
}

/// 景色に出す山(現在地からの方角・距離・仰角と、見えるか)
struct SceneryMountain: Equatable, Identifiable {
    var entry: MountainCatalog.Entry
    var bearing: Double
    var distance: Double
    var angle: Double
    var visibility: Skyline.Visibility
    var priority: Double

    var id: Int { entry.index }
    var isHidden: Bool { visibility == .hidden }
}

enum MountainSelection {
    /// 優先の度合い: 高い山・近い山ほど大きい。見えない山は後ろにする。
    static func priority(elevation: Double, distance: Double, visibility: Skyline.Visibility) -> Double {
        let score = (max(elevation, 0) + 300) / sqrt(max(distance / 1000, 1))
        return visibility == .hidden ? score * 0.1 : score
    }

    /// 半径の中の山を、優先の順に並べる。skyline があれば、手前の地形に隠れているかを調べる。
    static func select(catalog: [MountainCatalog.Entry], latitude: Double, longitude: Double, eye: Double, radius: Double,
                       skyline: Skyline?) -> [SceneryMountain] {
        let dLat = radius / 111_320
        let dLon = radius / (111_320 * max(cos(latitude * .pi / 180), 0.01))
        var result: [SceneryMountain] = []
        for entry in catalog {
            // 先に四角で大まかに絞る
            guard abs(entry.latitude - latitude) <= dLat, abs(entry.longitude - longitude) <= dLon else { continue }
            let distance = WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: entry.latitude, longitude: entry.longitude)
            guard distance <= radius, distance >= 50 else { continue }
            let bearing = WaypointMath.bearing(fromLatitude: latitude, longitude: longitude, toLatitude: entry.latitude, longitude: entry.longitude)
            let angle = WaypointElevation.angle(targetAltitude: entry.elevation, observerAltitude: eye, distance: distance)
            let visibility = skyline?.visibility(bearing: bearing, distance: distance, angle: angle) ?? .unknown
            result.append(SceneryMountain(entry: entry, bearing: bearing, distance: distance, angle: angle, visibility: visibility,
                                          priority: priority(elevation: entry.elevation, distance: distance, visibility: visibility)))
        }
        return result.sorted { $0.priority > $1.priority }
    }
}

/// 文字が重ならないように、印の上に段を分けて名前を置く(優先の高い順に、空いている一番下の段へ)
enum SceneryLabelLayout {
    struct Item: Equatable {
        var id: Int
        /// 文字の中心の x(pt)
        var x: CGFloat
        var width: CGFloat
    }

    static let rows = 3
    static let gap: CGFloat = 6

    /// items は優先の高い順。返り値は id → 段(0が一番下)。置けなかったものは入らない(印だけを描く)。
    static func place(_ items: [Item], rows: Int = rows, gap: CGFloat = gap) -> [Int: Int] {
        var occupied: [[ClosedRange<CGFloat>]] = Array(repeating: [], count: rows)
        var result: [Int: Int] = [:]
        for item in items {
            let range = (item.x - item.width / 2 - gap / 2)...(item.x + item.width / 2 + gap / 2)
            for row in 0..<rows where !occupied[row].contains(where: { $0.overlaps(range) }) {
                occupied[row].append(range)
                result[item.id] = row
                break
            }
        }
        return result
    }

    /// 文字の幅の見積もり(毎コマ文字を測らないため。全角は文字の大きさ、半角はその0.6倍)
    static func estimatedWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        text.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? fontSize * 0.6 : fontSize) }
    }
}

/// 地平線の近くに出す名前(川・地名)
struct SceneryLabel: Equatable {
    var name: String
    var kind: SceneryPlaceName.Kind
    var bearing: Double
    var distance: Double
    var angle: Double
}

/// 景色の計算の結果(カメラ表示が毎コマ使う。計算はメインスレッドの外で行う)
struct SceneryScene: Equatable {
    var latitude: Double
    var longitude: Double
    var eye: Double
    var radius: Double
    var skyline: Skyline?
    var ridges: [RidgeLine]
    var mountains: [SceneryMountain]
    var water: [WaterBand]
    var labels: [SceneryLabel]
    /// 標高タイルで調べられた方角の割合(0〜1)
    var coverage: Double
    var computedAt: Date
}

enum SceneryText {
    static func distance(_ meters: Double) -> String {
        if meters < 1000 { return "\(Int(meters.rounded()))m" }
        let km = meters / 1000
        return km < 10 ? String(format: "%.1fkm", km) : "\(Int(km.rounded()))km"
    }

    static func elevation(_ meters: Double) -> String {
        "\(Int(meters.rounded()))m"
    }
}

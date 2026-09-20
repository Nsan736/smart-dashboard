import Foundation

/// P2P地震情報 JSON API v2 の /history?codes=551 の応答(地震情報)。使う項目だけを読む。
struct P2PQuakeItem: Decodable {
    struct Hypocenter: Decodable {
        let name: String?
        let magnitude: Double?
        let depth: Double?
        let latitude: Double?
        let longitude: Double?
    }

    struct Earthquake: Decodable {
        let time: String
        let hypocenter: Hypocenter?
        let maxScale: Int?
        let domesticTsunami: String?
        let foreignTsunami: String?
    }

    struct Issue: Decodable {
        let type: String?
        let time: String?
        let correct: String?
    }

    struct Point: Decodable {
        let pref: String
        let addr: String?
        let scale: Int
    }

    let earthquake: Earthquake
    let issue: Issue?
    let points: [Point]?

    static func decode(_ data: Data) throws -> [P2PQuakeItem] {
        try JSONDecoder().decode([P2PQuakeItem].self, from: data)
    }

    /// 報の詳しさ。震度速報 < 震源に関する情報 < 震源・震度に関する情報 < 各地の震度に関する情報。
    var detailRank: Int {
        switch issue?.type {
        case "DetailScale": return 4
        case "ScaleAndDestination": return 3
        case "Destination", "Foreign": return 2
        case "ScalePrompt": return 1
        default: return 0
        }
    }
}

/// 震度。P2P地震情報の値(10=震度1、45=5弱、50=5強、55=6弱、60=6強、70=7、46=5弱以上と推定)に合わせる。
enum SeismicScale {
    static let choices: [Int] = [10, 20, 30, 40, 45, 50, 55, 60, 70]

    static func label(_ scale: Int) -> String {
        switch scale {
        case 10: return "1"
        case 20: return "2"
        case 30: return "3"
        case 40: return "4"
        case 45: return "5弱"
        case 46: return "5弱以上(推定)"
        case 50: return "5強"
        case 55: return "6弱"
        case 60: return "6強"
        case 70: return "7"
        default: return "不明"
        }
    }
}

/// 観測点ごとの震度
struct QuakePoint: Codable, Equatable {
    var prefecture: String
    var name: String
    var scale: Int
}

/// 表示とキャッシュに使う地震(1件)。同じ地震の複数の報をまとめたもの。
struct Quake: Codable, Equatable, Identifiable {
    var time: Date
    /// 震源地。震度速報だけで震源が未発表のときは nil。
    var place: String?
    var magnitude: Double?
    /// 最大震度(P2P地震情報の値)。不明なら nil。
    var maxScale: Int?
    /// 都道府県ごとの最大震度
    var prefectureScales: [String: Int]
    /// 以下は詳細画面用。古いキャッシュにはない。
    var depth: Double?
    var latitude: Double?
    var longitude: Double?
    var domesticTsunami: String?
    var foreignTsunami: String?
    var points: [QuakePoint]?
    /// もとにした報の種類(一番新しく詳しい報)と、その発表時刻
    var reportType: String?
    var reportedAt: Date?
    /// 報が更新されて、震源やマグニチュードなどの内容が変わった
    var wasRevised: Bool?
    var id: Date { time }

    func scale(inPrefecture prefecture: String?) -> Int? {
        prefecture.flatMap { prefectureScales[$0] }
    }

    /// 内容の比較に使う値(震源地、マグニチュード、深さ)
    fileprivate var essentials: String {
        "\(place ?? "-")|\(magnitude.map { String(format: "%.1f", $0) } ?? "-")|\(depth.map { String(format: "%.0f", $0) } ?? "-")"
    }

    var hasHypocenter: Bool { place != nil }
}

enum QuakeList {
    static let displayLimit = 5

    /// 同じ地震について複数の報(震度速報、震源に関する情報、各地の震度に関する情報)が出るので、発生時刻でまとめる。
    /// 内容は、一番詳しく新しい報のものを使う(その報にない項目だけ、ほかの報で補う)。新しい順に最大 limit 件。
    static func make(_ items: [P2PQuakeItem], limit: Int = displayLimit) -> [Quake] {
        var groups: [Date: [P2PQuakeItem]] = [:]
        for item in items {
            guard let time = parseTime(item.earthquake.time) else { continue }
            groups[time, default: []].append(item)
        }
        return groups.keys.sorted(by: >).prefix(limit).compactMap { time in
            groups[time].map { combine($0, time: time) }
        }
    }

    /// 1つの地震の報をまとめる
    static func combine(_ reports: [P2PQuakeItem], time: Date) -> Quake {
        // 詳しい順。同じ詳しさなら新しい順
        let ordered = reports.sorted { a, b in
            if a.detailRank != b.detailRank { return a.detailRank > b.detailRank }
            return (a.issue?.time ?? "") > (b.issue?.time ?? "")
        }
        var quake = Quake(time: time, place: nil, magnitude: nil, maxScale: nil, prefectureScales: [:])
        var essentials = Set<String>()
        for report in ordered {
            let hypocenter = report.earthquake.hypocenter
            if let name = hypocenter?.name, !name.isEmpty {
                var probe = Quake(time: time, place: name, magnitude: nil, maxScale: nil, prefectureScales: [:])
                probe.magnitude = hypocenter?.magnitude.flatMap { $0 >= 0 ? $0 : nil }
                probe.depth = hypocenter?.depth.flatMap { $0 >= 0 ? $0 : nil }
                essentials.insert(probe.essentials)
                if quake.place == nil {
                    quake.place = name
                    quake.magnitude = probe.magnitude
                    quake.depth = probe.depth
                    if let latitude = hypocenter?.latitude, let longitude = hypocenter?.longitude, abs(latitude) <= 90, abs(longitude) <= 180 {
                        quake.latitude = latitude
                        quake.longitude = longitude
                    }
                }
            }
            if let scale = report.earthquake.maxScale, scale > 0 { quake.maxScale = max(quake.maxScale ?? 0, scale) }
            if quake.domesticTsunami == nil, let value = report.earthquake.domesticTsunami { quake.domesticTsunami = value }
            if quake.foreignTsunami == nil, let value = report.earthquake.foreignTsunami { quake.foreignTsunami = value }
            if quake.points == nil, let points = report.points, !points.isEmpty {
                quake.points = points.filter { $0.scale > 0 }.map { QuakePoint(prefecture: $0.pref, name: $0.addr ?? "", scale: $0.scale) }
            }
            for point in report.points ?? [] where point.scale > 0 {
                quake.prefectureScales[point.pref] = max(quake.prefectureScales[point.pref] ?? 0, point.scale)
            }
        }
        if let best = ordered.first {
            quake.reportType = best.issue?.type
            quake.reportedAt = best.issue?.time.flatMap { parseTime(String($0.prefix(19))) }
            // 震源やマグニチュードが報の間で変わったか、訂正の報のとき
            let corrected = best.issue?.correct.map { $0 != "None" && $0 != "Unknown" } ?? false
            quake.wasRevised = essentials.count > 1 || corrected
        }
        return quake
    }

    /// 取得した一覧を、前回までの一覧に足す。1回の取得は件数を絞っているので、小さな地震が続くと
    /// 24時間以内の大きな地震が押し出されることがある。直近24時間の分と、新しい順に limit 件は残す。
    /// 前回と比べて震源やマグニチュードが変わっていたら、「更新あり」の印を付ける。
    static func merge(old: [Quake], new: [Quake], now: Date, limit: Int = displayLimit) -> [Quake] {
        var byTime: [Date: Quake] = [:]
        for quake in old { byTime[quake.time] = quake }
        for quake in new {
            var updated = quake
            if let previous = byTime[quake.time] {
                if previous.wasRevised == true { updated.wasRevised = true }
                if previous.hasHypocenter, quake.hasHypocenter, previous.essentials != quake.essentials { updated.wasRevised = true }
                // 新しい取得に詳細がなければ(一覧から押し出される直前の報など)、前回の詳細を残す
                if updated.points == nil { updated.points = previous.points }
                if !updated.hasHypocenter, previous.hasHypocenter { updated = previous }
            }
            byTime[quake.time] = updated
        }
        let sorted = byTime.values.sorted { $0.time > $1.time }
        return sorted.enumerated().filter { index, quake in
            index < limit || now.timeIntervalSince(quake.time) <= 24 * 3600
        }.map(\.element)
    }

    /// ホームのカード用: 直近24時間で、最大震度が設定値以上のもの
    static func recent(_ quakes: [Quake], minimumScale: Int, now: Date, within: TimeInterval = 24 * 3600) -> [Quake] {
        quakes.filter { quake in
            let age = now.timeIntervalSince(quake.time)
            return age >= 0 && age <= within && (quake.maxScale ?? 0) >= minimumScale
        }
    }

    /// "2026/09/19 21:23:00"(日本時間)
    static func parseTime(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter.date(from: text)
    }

    static func magnitudeText(_ magnitude: Double?) -> String {
        magnitude.map { String(format: "M%.1f", $0) } ?? "M不明"
    }

    /// 報の種類の日本語名
    static func reportName(_ type: String?) -> String {
        switch type {
        case "DetailScale": return "各地の震度に関する情報"
        case "ScaleAndDestination": return "震源・震度に関する情報"
        case "Destination": return "震源に関する情報"
        case "ScalePrompt": return "震度速報"
        case "Foreign": return "遠地地震に関する情報"
        default: return "地震情報"
        }
    }

    /// 「深さ10km」「ごく浅い」「深さ不明」
    static func depthText(_ depth: Double?) -> String {
        guard let depth else { return "深さ不明" }
        return depth == 0 ? "ごく浅い" : "深さ\(Int(depth.rounded()))km"
    }
}

/// 津波の情報(P2P地震情報の値を、分かりやすい日本語にする)
enum QuakeTsunami {
    enum Tone: Equatable {
        case none
        case caution
        case warning
        case unknown
    }

    static func domestic(_ value: String?) -> (text: String, tone: Tone) {
        switch value {
        case "None": return ("この地震による津波の心配はありません", .none)
        case "Checking": return ("津波の有無を調査中です", .caution)
        case "NonEffective": return ("若干の海面変動があるかもしれませんが、被害の心配はありません", .caution)
        case "Watch": return ("津波注意報が発表されています", .warning)
        case "Warning": return ("津波警報などが発表されています。気象庁の情報を確認してください", .warning)
        default: return ("津波の情報は不明です", .unknown)
        }
    }

    /// 海外での津波。情報がないとき(None / Unknown)は nil で、表示しない。
    static func foreign(_ value: String?) -> (text: String, tone: Tone)? {
        switch value {
        case "Checking": return ("海外での津波の有無を調査中です", .caution)
        case "NonEffectiveNearby": return ("震源の近くで小さな津波の可能性がありますが、被害の心配はありません", .caution)
        case "WarningNearby": return ("震源の近くで津波の可能性があります", .warning)
        case "WarningPacific": return ("太平洋で津波の可能性があります", .warning)
        case "WarningPacificWide": return ("太平洋の広い範囲で津波の可能性があります", .warning)
        case "WarningIndian": return ("インド洋で津波の可能性があります", .warning)
        case "WarningIndianWide": return ("インド洋の広い範囲で津波の可能性があります", .warning)
        case "Potential": return ("一般に、この規模の地震では津波の可能性があります", .caution)
        default: return nil
        }
    }
}

/// 各地の震度を「震度 → 都道府県 → 観測点」の階層にする
struct QuakeIntensityGroup: Equatable, Identifiable {
    struct Prefecture: Equatable, Identifiable {
        var name: String
        var points: [String]
        var isHome: Bool
        var id: String { name }
    }

    var scale: Int
    var prefectures: [Prefecture]
    var id: Int { scale }

    var pointCount: Int { prefectures.reduce(0) { $0 + $1.points.count } }

    /// 震度の大きい順。同じ震度の中では、現在地の都道府県を先頭にし、あとは観測点の多い順(同数なら名前の順)。
    static func make(_ points: [QuakePoint], homePrefecture: String?) -> [QuakeIntensityGroup] {
        var byScale: [Int: [String: [String]]] = [:]
        for point in points {
            byScale[point.scale, default: [:]][point.prefecture, default: []].append(point.name)
        }
        return byScale.keys.sorted(by: >).map { scale in
            let prefectures = (byScale[scale] ?? [:]).map { name, names in
                Prefecture(name: name, points: names.sorted(), isHome: name == homePrefecture)
            }
            .sorted { a, b in
                if a.isHome != b.isHome { return a.isHome }
                if a.points.count != b.points.count { return a.points.count > b.points.count }
                return a.name < b.name
            }
            return QuakeIntensityGroup(scale: scale, prefectures: prefectures)
        }
    }
}

struct QuakeSnapshot: Codable, Equatable {
    var quakes: [Quake]
}

import Foundation

/// P2P地震情報 JSON API v2 の /history?codes=551 の応答(地震情報)。使う項目だけを読む。
struct P2PQuakeItem: Decodable {
    struct Hypocenter: Decodable {
        let name: String?
        let magnitude: Double?
        let depth: Double?
    }

    struct Earthquake: Decodable {
        let time: String
        let hypocenter: Hypocenter?
        let maxScale: Int?
    }

    struct Issue: Decodable {
        let type: String?
    }

    struct Point: Decodable {
        let pref: String
        let scale: Int
    }

    let earthquake: Earthquake
    let issue: Issue?
    let points: [Point]?

    static func decode(_ data: Data) throws -> [P2PQuakeItem] {
        try JSONDecoder().decode([P2PQuakeItem].self, from: data)
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

/// 表示とキャッシュに使う地震(1件)
struct Quake: Codable, Equatable, Identifiable {
    var time: Date
    /// 震源地。震度速報だけで震源が未発表のときは nil。
    var place: String?
    var magnitude: Double?
    /// 最大震度(P2P地震情報の値)。不明なら nil。
    var maxScale: Int?
    /// 都道府県ごとの最大震度
    var prefectureScales: [String: Int]
    var id: Date { time }

    func scale(inPrefecture prefecture: String?) -> Int? {
        prefecture.flatMap { prefectureScales[$0] }
    }
}

enum QuakeList {
    static let displayLimit = 5

    /// 同じ地震について複数の報(震度速報、震源に関する情報、各地の震度に関する情報)が出るので、発生時刻でまとめる。
    /// 新しい順に最大 limit 件。
    static func make(_ items: [P2PQuakeItem], limit: Int = displayLimit) -> [Quake] {
        var order: [Date] = []
        var merged: [Date: Quake] = [:]
        for item in items {
            guard let time = parseTime(item.earthquake.time) else { continue }
            var quake = merged[time] ?? Quake(time: time, place: nil, magnitude: nil, maxScale: nil, prefectureScales: [:])
            if merged[time] == nil { order.append(time) }
            if quake.place == nil, let name = item.earthquake.hypocenter?.name, !name.isEmpty { quake.place = name }
            if quake.magnitude == nil, let magnitude = item.earthquake.hypocenter?.magnitude, magnitude >= 0 { quake.magnitude = magnitude }
            if let scale = item.earthquake.maxScale, scale > 0 { quake.maxScale = max(quake.maxScale ?? 0, scale) }
            for point in item.points ?? [] where point.scale > 0 {
                quake.prefectureScales[point.pref] = max(quake.prefectureScales[point.pref] ?? 0, point.scale)
            }
            merged[time] = quake
        }
        return order.sorted(by: >).prefix(limit).compactMap { merged[$0] }
    }

    /// 取得した一覧を、前回までの一覧に足す。1回の取得は件数を絞っているので、小さな地震が続くと
    /// 24時間以内の大きな地震が押し出されることがある。直近24時間の分と、新しい順に limit 件は残す。
    static func merge(old: [Quake], new: [Quake], now: Date, limit: Int = displayLimit) -> [Quake] {
        var byTime: [Date: Quake] = [:]
        for quake in old { byTime[quake.time] = quake }
        for quake in new { byTime[quake.time] = quake }
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
}

struct QuakeSnapshot: Codable, Equatable {
    var quakes: [Quake]
}

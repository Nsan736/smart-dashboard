import Foundation

enum Formatters {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    /// 「たった今」「12分前」「3時間前」「2日前」
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "たった今" }
        if seconds < 3600 { return "\(seconds / 60)分前" }
        if seconds < 86400 { return "\(seconds / 3600)時間前" }
        return "\(seconds / 86400)日前"
    }

    static func ageLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "未取得" }
        return "\(age(of: date, now: now))の情報"
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()
}

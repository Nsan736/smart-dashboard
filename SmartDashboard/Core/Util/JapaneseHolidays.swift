import Foundation

enum DayType: String, Codable {
    case weekday
    case saturday
    case holiday
}

/// 祝日の簡易判定(現行の祝日法の規則に基づく。臨時の祝日移動には対応しない)
enum JapaneseHolidays {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        c.locale = Locale(identifier: "ja_JP")
        return c
    }()

    static func dayType(of date: Date) -> DayType {
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let y = c.year, let m = c.month, let d = c.day, let w = c.weekday else { return .weekday }
        if w == 1 || isHoliday(year: y, month: m, day: d) { return .holiday }
        return w == 7 ? .saturday : .weekday
    }

    static func isHoliday(year: Int, month: Int, day: Int) -> Bool {
        if isBaseHoliday(year: year, month: month, day: day) { return true }
        guard let date = makeDate(year, month, day) else { return false }
        let weekday = calendar.component(.weekday, from: date)

        // 振替休日: 直前に連続する祝日をさかのぼり、その中に日曜があれば休み
        if weekday != 1 {
            var cursor = date
            while let prev = calendar.date(byAdding: .day, value: -1, to: cursor), isBase(prev) {
                if calendar.component(.weekday, from: prev) == 1 { return true }
                cursor = prev
            }
        }
        // 国民の休日: 前後が祝日に挟まれた平日
        if weekday != 1,
           let prev = calendar.date(byAdding: .day, value: -1, to: date),
           let next = calendar.date(byAdding: .day, value: 1, to: date),
           isBase(prev), isBase(next) {
            return true
        }
        return false
    }

    private static func isBase(_ date: Date) -> Bool {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return isBaseHoliday(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
    }

    private static func isBaseHoliday(year y: Int, month m: Int, day d: Int) -> Bool {
        switch (m, d) {
        case (1, 1), (2, 11), (2, 23), (4, 29), (5, 3), (5, 4), (5, 5), (8, 11), (11, 3), (11, 23):
            return true
        default:
            break
        }
        if m == 1, d == nthMonday(2, year: y, month: 1) { return true }
        if m == 7, d == nthMonday(3, year: y, month: 7) { return true }
        if m == 9, d == nthMonday(3, year: y, month: 9) { return true }
        if m == 10, d == nthMonday(2, year: y, month: 10) { return true }
        if m == 3, d == springEquinoxDay(y) { return true }
        if m == 9, d == autumnEquinoxDay(y) { return true }
        return false
    }

    static func springEquinoxDay(_ year: Int) -> Int {
        Int(20.8431 + 0.242194 * Double(year - 1980)) - (year - 1980) / 4
    }

    static func autumnEquinoxDay(_ year: Int) -> Int {
        Int(23.2488 + 0.242194 * Double(year - 1980)) - (year - 1980) / 4
    }

    private static func nthMonday(_ n: Int, year: Int, month: Int) -> Int {
        guard let first = makeDate(year, month, 1) else { return 0 }
        let weekday = calendar.component(.weekday, from: first)
        let firstMonday = 1 + (9 - weekday) % 7
        return firstMonday + (n - 1) * 7
    }

    private static func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date? {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
    }
}

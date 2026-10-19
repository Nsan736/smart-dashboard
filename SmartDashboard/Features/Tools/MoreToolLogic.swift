import CoreGraphics
import Foundation

// 内蔵ツールのうち Swift のままのもの(世界時計・メトロノーム)と、JSON のリスト型・計算型が使う部品のロジック。
// ほかの内蔵ツールは v0.9.33 で JavaScript 版(examples/tools/src/builtin)だけにした。

// MARK: - 世界時計

enum WorldClock {
    struct City: Equatable, Identifiable {
        var id: String
        var name: String
        var zone: String
    }

    /// タイムゾーンのデータは iOS のものを使う(夏時間も含む)。通信はしない。
    static let cities: [City] = [
        City(id: "tokyo", name: "東京", zone: "Asia/Tokyo"),
        City(id: "seoul", name: "ソウル", zone: "Asia/Seoul"),
        City(id: "beijing", name: "北京", zone: "Asia/Shanghai"),
        City(id: "taipei", name: "台北", zone: "Asia/Taipei"),
        City(id: "hongkong", name: "香港", zone: "Asia/Hong_Kong"),
        City(id: "bangkok", name: "バンコク", zone: "Asia/Bangkok"),
        City(id: "singapore", name: "シンガポール", zone: "Asia/Singapore"),
        City(id: "delhi", name: "デリー", zone: "Asia/Kolkata"),
        City(id: "dubai", name: "ドバイ", zone: "Asia/Dubai"),
        City(id: "istanbul", name: "イスタンブール", zone: "Europe/Istanbul"),
        City(id: "moscow", name: "モスクワ", zone: "Europe/Moscow"),
        City(id: "cairo", name: "カイロ", zone: "Africa/Cairo"),
        City(id: "paris", name: "パリ", zone: "Europe/Paris"),
        City(id: "berlin", name: "ベルリン", zone: "Europe/Berlin"),
        City(id: "rome", name: "ローマ", zone: "Europe/Rome"),
        City(id: "london", name: "ロンドン", zone: "Europe/London"),
        City(id: "utc", name: "協定世界時(UTC)", zone: "UTC"),
        City(id: "saopaulo", name: "サンパウロ", zone: "America/Sao_Paulo"),
        City(id: "newyork", name: "ニューヨーク", zone: "America/New_York"),
        City(id: "chicago", name: "シカゴ", zone: "America/Chicago"),
        City(id: "denver", name: "デンバー", zone: "America/Denver"),
        City(id: "losangeles", name: "ロサンゼルス", zone: "America/Los_Angeles"),
        City(id: "vancouver", name: "バンクーバー", zone: "America/Vancouver"),
        City(id: "honolulu", name: "ホノルル", zone: "Pacific/Honolulu"),
        City(id: "auckland", name: "オークランド", zone: "Pacific/Auckland"),
        City(id: "sydney", name: "シドニー", zone: "Australia/Sydney"),
    ]

    static let defaultIDs = ["london", "newyork", "losangeles", "sydney"]
    static let japan = TimeZone(identifier: "Asia/Tokyo") ?? .current

    /// 保存した文字列(カンマ区切りのID)を、都市の一覧にする。知らないIDは捨てる。
    static func decode(_ text: String) -> [City] {
        text.split(separator: ",").compactMap { id in cities.first { $0.id == id } }
    }

    static func encode(_ list: [City]) -> String { list.map(\.id).joined(separator: ",") }

    /// 日本との時差(秒)。その時点の夏時間を含む。
    static func offsetFromJapan(_ zone: TimeZone, at date: Date) -> Int {
        zone.secondsFromGMT(for: date) - japan.secondsFromGMT(for: date)
    }

    /// 「日本と同じ」「−14時間」「+3時間30分」
    static func offsetText(_ seconds: Int) -> String {
        guard seconds != 0 else { return "日本と同じ" }
        let minutes = abs(seconds) / 60
        var text = (seconds < 0 ? "−" : "+") + "\(minutes / 60)時間"
        if minutes % 60 != 0 { text += "\(minutes % 60)分" }
        return text
    }

    /// 日本の日付から見た、その都市の日付のずれ(−1=前日、0=同じ日、1=翌日)
    static func dayDifference(_ zone: TimeZone, at date: Date) -> Int {
        func dayNumber(_ zone: TimeZone) -> Int {
            Int((Double(Int(date.timeIntervalSince1970) + zone.secondsFromGMT(for: date)) / 86400).rounded(.down))
        }
        return dayNumber(zone) - dayNumber(japan)
    }

    static func dayText(_ difference: Int) -> String {
        switch difference {
        case 0: return "同じ日"
        case 1: return "翌日"
        case -1: return "前日"
        default: return difference > 0 ? "\(difference)日後" : "\(-difference)日前"
        }
    }

    static func timeText(_ zone: TimeZone, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = zone
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date)
    }
}

// MARK: - メトロノーム

enum MetronomeLogic {
    static let bpmRange = 30...240

    static func clamped(_ bpm: Int) -> Int { min(max(bpm, bpmRange.lowerBound), bpmRange.upperBound) }

    /// 1拍のサンプル数
    static func framesPerBeat(bpm: Int, sampleRate: Double) -> Int {
        Int((sampleRate * 60 / Double(clamped(bpm))).rounded())
    }

    /// 開始からの経過時間 → 小節の中の拍(0始まり)
    static func beatIndex(elapsed: TimeInterval, bpm: Int, beatsPerBar: Int) -> Int {
        guard elapsed >= 0, beatsPerBar > 0 else { return 0 }
        return Int(elapsed / (60 / Double(clamped(bpm)))) % beatsPerBar
    }

    /// タップの時刻からテンポを求める。2秒以上空いたら、そこから数え直す。タップが2回未満なら nil。
    static func tapTempo(_ taps: [TimeInterval]) -> Int? {
        var recent: [TimeInterval] = []
        for time in taps {
            if let last = recent.last, time - last > 2 { recent = [] }
            recent.append(time)
        }
        let used = Array(recent.suffix(6))
        guard used.count >= 2, let first = used.first, let last = used.last, last > first else { return nil }
        return clamped(Int((60 * Double(used.count - 1) / (last - first)).rounded()))
    }

    /// 1小節ぶんの波形。各拍の先頭に短いクリック音(1拍目は高い音)。accent が false なら、全部同じ音。
    static func barSamples(bpm: Int, beatsPerBar: Int, accent: Bool, sampleRate: Double) -> [Float] {
        let perBeat = framesPerBeat(bpm: bpm, sampleRate: sampleRate)
        let beats = max(beatsPerBar, 1)
        var samples = [Float](repeating: 0, count: perBeat * beats)
        let clickFrames = min(Int(sampleRate * 0.03), perBeat)
        for beat in 0..<beats {
            let frequency = (accent && beat == 0) ? 1760.0 : 1100.0
            for frame in 0..<clickFrames {
                let time = Double(frame) / sampleRate
                let envelope = exp(-time * 120)
                samples[beat * perBeat + frame] = Float(sin(2 * .pi * frequency * time) * envelope * 0.8)
            }
        }
        return samples
    }
}

// MARK: - ルーレットの円盤

enum RouletteWheel {
    /// 針は真上。項目 i は、真上から時計回りに i×(360/数) 〜 (i+1)×(360/数) の扇形。
    /// 円盤を時計回りに rotation 度回したとき、針の下にくる項目。
    static func index(atRotation rotation: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let segment = 360 / Double(count)
        var angle = (-rotation).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        return min(Int(angle / segment), count - 1)
    }

    /// 項目 index の扇形の中(fraction: 0〜1 の位置)で止まる回転角。今の角度から、少なくとも turns 回転ぶん先。
    static func stopRotation(current: Double, index: Int, count: Int, turns: Int, fraction: Double) -> Double {
        guard count > 0 else { return current }
        let segment = 360 / Double(count)
        let inside = min(max(fraction, 0.1), 0.9)
        var target = (-(Double(index) + inside) * segment).truncatingRemainder(dividingBy: 360)
        if target < 0 { target += 360 }
        let minimum = current + Double(turns) * 360
        let base = (minimum / 360).rounded(.down) * 360 + target
        return base >= minimum ? base : base + 360
    }

    /// 円盤に書く名前の省略(全角を2、半角を1として units まで)
    static func shortName(_ name: String, units: Int) -> String {
        var used = 0
        var result = ""
        for character in name {
            let width = isHalfWidth(character) ? 1 : 2
            if used + width > units {
                return result + "…"
            }
            used += width
            result.append(character)
        }
        return result
    }

    /// ASCII と半角カタカナを半角とみなす
    static func isHalfWidth(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.value < 0x7F || (0xFF61...0xFF9F).contains($0.value) }
    }
}

// MARK: - 日付(JSON の計算型の date の入力欄)

enum DateCalc {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }

    /// 2つの日付の間の日数(to − from)。時刻は無視する。
    static func days(from: Date, to: Date) -> Int {
        let calendar = calendar
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}

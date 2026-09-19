import CoreGraphics
import Foundation
import ImageIO

/// 降水の強さの段階。0は雨なし、1〜8は気象庁ナウキャストのタイルの配色の順。
/// 配色は実際のタイルのPNGパレットで確認したもの(2026-09-19)。強度の区切りは気象庁の凡例による。
enum RainLevel {
    /// (R, G, B, 下限mm/h, 上限mm/h)
    static let table: [(r: Int, g: Int, b: Int, lower: Double, upper: Double?)] = [
        (242, 242, 255, 0, 1),
        (160, 210, 255, 1, 5),
        (33, 140, 255, 5, 10),
        (0, 65, 255, 10, 20),
        (250, 245, 0, 20, 30),
        (255, 153, 0, 30, 50),
        (255, 40, 0, 50, 80),
        (180, 0, 104, 80, nil),
    ]

    /// 透明なら0。色が表のどれかに十分近ければその段階。どれにも近くなければnil(仕様変更の可能性)。
    static func level(r: Int, g: Int, b: Int, a: Int) -> Int? {
        if a < 128 { return 0 }
        var best: (index: Int, distance: Int)?
        for (index, entry) in table.enumerated() {
            let distance = abs(entry.r - r) + abs(entry.g - g) + abs(entry.b - b)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best, best.distance <= 36 else { return nil }
        return best.index + 1
    }

    /// 気象庁の予報用語に合わせた表現
    static func label(_ level: Int) -> String {
        switch level {
        case ...0: return "雨なし"
        case 1: return "弱い雨"
        case 2, 3: return "雨"
        case 4: return "やや強い雨"
        case 5: return "強い雨"
        case 6: return "激しい雨"
        case 7: return "非常に激しい雨"
        default: return "猛烈な雨"
        }
    }

    static func rangeText(_ level: Int) -> String {
        guard level >= 1, level <= table.count else { return "0 mm/h" }
        let entry = table[level - 1]
        if let upper = entry.upper { return String(format: "%.0f〜%.0f mm/h", entry.lower, upper) }
        return String(format: "%.0f mm/h以上", entry.lower)
    }

    /// グラフ用の代表値(mm/h)
    static func representative(_ level: Int) -> Double {
        guard level >= 1, level <= table.count else { return 0 }
        let entry = table[level - 1]
        return entry.upper.map { (entry.lower + $0) / 2 } ?? entry.lower
    }
}

/// タイルのPNGから、指定したピクセルの周囲の降水の段階を読む
enum RainPixelReader {
    /// 256x256のRGBAに展開する。行は上から順。
    static func rgba(from data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 256, image.height == 256 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256 * 256 * 4)
        let ok = buffer.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(
                data: pointer.baseAddress, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
            return true
        }
        return ok ? buffer : nil
    }

    /// 地点のピクセルと、その周囲(radiusピクセル)の最大の段階を返す。
    /// 雨の境目では1ピクセルのずれで結果が変わるので、周囲も見て「降っている」側に倒す。
    /// 読めない色があればnil。
    static func level(in data: Data, x: Int, y: Int, radius: Int = 1) -> Int? {
        guard let pixels = rgba(from: data) else { return nil }
        let x = min(max(x, 0), 255)
        let y = min(max(y, 0), 255)
        var result = 0
        for yy in max(0, y - radius)...min(255, y + radius) {
            for xx in max(0, x - radius)...min(255, x + radius) {
                let offset = (yy * 256 + xx) * 4
                guard let level = RainLevel.level(r: Int(pixels[offset]), g: Int(pixels[offset + 1]),
                                                  b: Int(pixels[offset + 2]), a: Int(pixels[offset + 3])) else { return nil }
                result = max(result, level)
            }
        }
        return result
    }
}

/// 現在地の直近1時間の降水(実況1点と、5分刻みの予測)
struct RainNowcast: Codable, Equatable {
    struct Point: Codable, Equatable, Identifiable {
        var time: Date
        var isForecast: Bool
        var level: Int
        var id: Date { time }
    }

    var latitude: Double
    var longitude: Double
    var points: [Point]
}

/// 雨の要約。0〜60分はナウキャスト、その先はOpen-Meteo(予報モデル)を使う。
struct RainOutlook: Equatable {
    var headline: String
    /// 60分より先(予報モデル)
    var later: String?
    /// ナウキャストが使えなかったときの注記
    var note: String?

    static let fallbackNote = "ナウキャストを取得できないため、予報モデルの値で表示しています"
    /// 実況がこれより古ければ使わない
    static let maxObservedAge: TimeInterval = 20 * 60

    static func make(nowcast: RainNowcast?, modelSlots: [WeatherSnapshot.RainSlot], now: Date) -> RainOutlook? {
        if let headline = nowcastHeadline(nowcast, now: now) {
            return RainOutlook(headline: headline, later: laterText(modelSlots, now: now), note: nil)
        }
        guard let text = RainSummary.text(slots: modelSlots, now: now) else { return nil }
        return RainOutlook(headline: text, later: nil, note: fallbackNote)
    }

    static func nowcastHeadline(_ nowcast: RainNowcast?, now: Date) -> String? {
        guard let points = nowcast?.points.sorted(by: { $0.time < $1.time }),
              let observed = points.last(where: { !$0.isForecast }),
              now.timeIntervalSince(observed.time) <= maxObservedAge,
              now.timeIntervalSince(observed.time) >= -5 * 60 else { return nil }
        let future = points.filter { $0.isForecast && $0.time > observed.time && $0.time <= observed.time.addingTimeInterval(3600) }
        func minutes(_ point: RainNowcast.Point) -> Int {
            max(5, Int((point.time.timeIntervalSince(now) / 300).rounded()) * 5)
        }
        if observed.level == 0 {
            guard let start = future.first(where: { $0.level > 0 }) else {
                return future.isEmpty ? "今は降っていません" : "今は降っていません。1時間は雨の予想なし"
            }
            return "今は降っていません。\(minutes(start))分後から\(RainLevel.label(start.level))の予想"
        }
        let label = RainLevel.label(observed.level)
        guard let stop = future.first(where: { $0.level == 0 }) else {
            return future.isEmpty ? "今、\(label)" : "今、\(label)。1時間は降り続く予想"
        }
        return "今、\(label)。\(minutes(stop))分ほどでやむ予想"
    }

    /// 1〜2時間後。Open-Meteoの値なので「予報」と明記する。
    static func laterText(_ slots: [WeatherSnapshot.RainSlot], now: Date) -> String? {
        let later = slots.filter { $0.time >= now.addingTimeInterval(55 * 60) }
        guard !later.isEmpty else { return nil }
        let rainy = later.contains { $0.precipitation >= RainSummary.threshold }
        return rainy ? "1〜2時間後は雨の予報あり(予報モデル)" : "1〜2時間後は雨の予報なし(予報モデル)"
    }
}

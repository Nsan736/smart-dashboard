import Foundation

/// 山頂に太陽・月が重なる日時(ダイヤモンド富士・パール富士など)
struct SummitAlignment: Identifiable, Equatable {
    var id: String { "\(body.rawValue).\(Int(date.timeIntervalSince1970))" }
    var body: SkyBody
    /// 中心が山頂に一番近づく時刻
    var date: Date
    var isRising: Bool
    /// 中心と山頂の角度のずれ(度)
    var separation: Double
    /// 月の輝いている割合(太陽は nil)
    var illumination: Double?
}

/// 山頂に重なる日の探し方。1日ごとに、太陽・月の見かけの高さ(大気の屈折を含む)が山頂の見かけの仰角を横切る時刻を探し、
/// その前後で中心と山頂の角度が一番小さくなる時刻を求める。±0.25°(太陽・月の半径くらい)以内を候補にする
enum SummitAlignmentSearch {
    static let tolerance = 0.25
    /// 横切る時刻の方角が、これより山頂からずれていたら、近づく時刻を調べない(度)
    static let screenAzimuth = 1.5

    /// 2つの方向(方角・高さ)の角度(度)
    static func separation(azimuth a1: Double, altitude h1: Double, azimuth a2: Double, altitude h2: Double) -> Double {
        let d = Astronomy.degree
        let cosine = sin(h1 * d) * sin(h2 * d) + cos(h1 * d) * cos(h2 * d) * cos((a1 - a2) * d)
        return acos(max(-1, min(1, cosine))) / d
    }

    /// 1つの天体を days 日分調べる。progress は 0〜1 を受け取り、false を返したら途中でやめる
    static func search(_ body: SkyBody, from start: Date, days: Int, latitude: Double, longitude: Double,
                       peakBearing: Double, peakAngle: Double, tolerance: Double = tolerance,
                       progress: (Double) -> Bool = { _ in true }) -> [SummitAlignment] {
        var result: [SummitAlignment] = []
        let first = SkyEvents.startOfDay(start)
        for day in 0..<max(days, 0) {
            if day % 5 == 0, !progress(Double(day) / Double(days)) { break }
            let dayStart = first.addingTimeInterval(Double(day) * 86_400)
            let dayEnd = dayStart.addingTimeInterval(86_400)
            let value: (Date) -> Double = { date in
                body.horizontal(date, latitude: latitude, longitude: longitude).apparentAltitude - peakAngle
            }
            for rising in [true, false] {
                for crossing in SkyEvents.crossings(from: dayStart, to: dayEnd, rising: rising, value: value) {
                    let position = body.horizontal(crossing, latitude: latitude, longitude: longitude)
                    guard abs(WaypointMath.difference(from: peakBearing, to: position.azimuth)) <= screenAzimuth else { continue }
                    guard let best = closest(body, around: crossing, latitude: latitude, longitude: longitude,
                                             peakBearing: peakBearing, peakAngle: peakAngle),
                          best.separation <= tolerance else { continue }
                    let illumination = body == .moon ? Astronomy.moonPhase(best.date).illumination : nil
                    result.append(SummitAlignment(body: body, date: best.date, isRising: rising, separation: best.separation,
                                                  illumination: illumination))
                }
            }
        }
        _ = progress(1)
        return result.sorted { $0.date < $1.date }
    }

    /// 横切る時刻の前後20分で、中心と山頂の角度が一番小さくなる時刻(20秒ごとに調べてから、前後を細かく)
    static func closest(_ body: SkyBody, around center: Date, latitude: Double, longitude: Double,
                        peakBearing: Double, peakAngle: Double) -> (date: Date, separation: Double)? {
        func distance(_ date: Date) -> Double {
            let position = body.horizontal(date, latitude: latitude, longitude: longitude)
            return separation(azimuth: position.azimuth, altitude: position.apparentAltitude, azimuth: peakBearing, altitude: peakAngle)
        }
        var bestDate = center
        var best = distance(center)
        for offset in stride(from: -1200.0, through: 1200, by: 20) {
            let date = center.addingTimeInterval(offset)
            let value = distance(date)
            if value < best { best = value; bestDate = date }
        }
        let coarse = bestDate
        for offset in stride(from: -20.0, through: 20, by: 1) {
            let date = coarse.addingTimeInterval(offset)
            let value = distance(date)
            if value < best { best = value; bestDate = date }
        }
        return (bestDate, best)
    }
}

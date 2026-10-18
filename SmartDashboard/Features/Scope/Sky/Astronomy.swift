import Foundation

/// 太陽と月の位置の計算(端末の中だけ。通信しない)。
/// - 太陽: NOAA の太陽の位置の式(Meeus『Astronomical Algorithms』25章の低い精度の式。方角・高さで約0.01°)
/// - 月: Meeus 47章の主な項(経度32項・緯度30項・距離。経度で約0.01〜0.03°)と、地平の視差の補正
/// - 大気の屈折: Bennett の式(地平線の近くで約0.5°。−1°より下では0)
/// 角度は度。方角は北から時計回り、高さは水平で0
enum Astronomy {
    static let degree = Double.pi / 180
    static let astronomicalUnit = 149_597_870.7
    static let earthRadiusKm = 6378.14

    /// ユリウス日
    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// J2000.0 からのユリウス世紀
    static func centuries(_ date: Date) -> Double {
        (julianDay(date) - 2_451_545.0) / 36_525
    }

    static func normalized(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    static func sinD(_ x: Double) -> Double { sin(x * degree) }
    static func cosD(_ x: Double) -> Double { cos(x * degree) }

    /// 赤道座標(赤経・赤緯、度)と、地球からの距離(km)
    struct Equatorial: Equatable {
        var rightAscension: Double
        var declination: Double
        var distanceKm: Double
    }

    /// 地平座標(方角・高さ、度)
    struct Horizontal: Equatable {
        /// 方角(北から時計回り)
        var azimuth: Double
        /// 大気の屈折を考えない高さ
        var altitude: Double
        /// 見かけの高さ(大気の屈折を足したもの)
        var apparentAltitude: Double
    }

    /// 黄道の傾き(度、章動を含む)と、章動による経度のずれ(度)
    static func obliquityAndNutation(_ t: Double) -> (obliquity: Double, nutation: Double) {
        let omega = 125.04452 - 1934.136261 * t
        let sunLongitude = 280.4665 + 36000.7698 * t
        let moonLongitude = 218.3165 + 481267.8813 * t
        let nutation = (-17.20 * sinD(omega) - 1.32 * sinD(2 * sunLongitude) - 0.23 * sinD(2 * moonLongitude) + 0.21 * sinD(2 * omega)) / 3600
        let mean = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = mean + (9.20 * cosD(omega) + 0.57 * cosD(2 * sunLongitude) + 0.10 * cosD(2 * moonLongitude) - 0.09 * cosD(2 * omega)) / 3600
        return (obliquity, nutation)
    }

    /// 太陽の見かけの位置(NOAA の式)
    static func sun(_ date: Date) -> Equatorial {
        let t = centuries(date)
        let l0 = normalized(280.46646 + t * (36000.76983 + t * 0.0003032))
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sinD(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sinD(2 * m) * (0.019993 - 0.000101 * t) + sinD(3 * m) * 0.000289
        let trueLongitude = l0 + c
        let trueAnomaly = m + c
        let radius = 1.000001018 * (1 - e * e) / (1 + e * cosD(trueAnomaly))
        let omega = 125.04 - 1934.136 * t
        let lambda = trueLongitude - 0.00569 - 0.00478 * sinD(omega)
        let epsilon = obliquityAndNutation(t).obliquity
        let ra = normalized(atan2(cosD(epsilon) * sinD(lambda), cosD(lambda)) / degree)
        let dec = asin(sinD(epsilon) * sinD(lambda)) / degree
        return Equatorial(rightAscension: ra, declination: dec, distanceKm: radius * astronomicalUnit)
    }

    /// 太陽の見かけの黄経(度。夏至=90°、冬至=270°)
    static func sunLongitude(_ date: Date) -> Double {
        let t = centuries(date)
        let l0 = 280.46646 + t * (36000.76983 + t * 0.0003032)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let c = sinD(m) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sinD(2 * m) * (0.019993 - 0.000101 * t) + sinD(3 * m) * 0.000289
        let omega = 125.04 - 1934.136 * t
        return normalized(l0 + c - 0.00569 - 0.00478 * sinD(omega))
    }

    // Meeus 表 47.A(D, M, M', F, 経度の係数(1e-6度), 距離の係数(0.001km))
    private static let moonLongitudeTerms: [(Double, Double, Double, Double, Double, Double)] = [
        (0, 0, 1, 0, 6288774, -20905355), (2, 0, -1, 0, 1274027, -3699111), (2, 0, 0, 0, 658314, -2955968),
        (0, 0, 2, 0, 213618, -569925), (0, 1, 0, 0, -185116, 48888), (0, 0, 0, 2, -114332, -3149),
        (2, 0, -2, 0, 58793, 246158), (2, -1, -1, 0, 57066, -152138), (2, 0, 1, 0, 53322, -170733),
        (2, -1, 0, 0, 45758, -204586), (0, 1, -1, 0, -40923, -129620), (1, 0, 0, 0, -34720, 108743),
        (0, 1, 1, 0, -30383, 104755), (2, 0, 0, -2, 15327, 10321), (0, 0, 1, 2, -12528, 0),
        (0, 0, 1, -2, 10980, 79661), (4, 0, -1, 0, 10675, -34782), (0, 0, 3, 0, 10034, -23210),
        (4, 0, -2, 0, 8548, -21636), (2, 1, -1, 0, -7888, 24208), (2, 1, 0, 0, -6766, 30824),
        (1, 0, -1, 0, -5163, -8379), (1, 1, 0, 0, 4987, -16675), (2, -1, 1, 0, 4036, -12831),
        (2, 0, 2, 0, 3994, -10445), (4, 0, 0, 0, 3861, -11650), (2, 0, -3, 0, 3665, 14403),
        (0, 1, -2, 0, -2689, -7003), (2, 0, -1, 2, -2602, 0), (2, -1, -2, 0, 2390, 10056),
        (1, 0, 1, 0, -2348, 6322), (2, -2, 0, 0, 2236, -9884),
    ]

    // Meeus 表 47.B(D, M, M', F, 緯度の係数(1e-6度))
    private static let moonLatitudeTerms: [(Double, Double, Double, Double, Double)] = [
        (0, 0, 0, 1, 5128122), (0, 0, 1, 1, 280602), (0, 0, 1, -1, 277693), (2, 0, 0, -1, 173237),
        (2, 0, -1, 1, 55413), (2, 0, -1, -1, 46271), (2, 0, 0, 1, 32573), (0, 0, 2, 1, 17198),
        (2, 0, 1, -1, 9266), (0, 0, 2, -1, 8822), (2, -1, 0, -1, 8216), (2, 0, -2, -1, 4324),
        (2, 0, 1, 1, 4200), (2, 1, 0, -1, -3359), (2, -1, -1, 1, 2463), (2, -1, 0, 1, 2211),
        (2, -1, -1, -1, 2065), (0, 1, -1, -1, -1870), (4, 0, -1, -1, 1828), (0, 1, 0, 1, -1794),
        (0, 0, 0, 3, -1749), (0, 1, -1, 1, -1565), (1, 0, 0, 1, -1491), (0, 1, 1, 1, -1475),
        (0, 1, 1, -1, -1410), (0, 1, 0, -1, -1344), (1, 0, 0, -1, -1335), (0, 0, 3, 1, 1107),
        (4, 0, 0, -1, 1021), (4, 0, -1, 1, 833),
    ]

    /// 月の見かけの位置(地球の中心から。Meeus 47章の主な項)
    static func moon(_ date: Date) -> Equatorial {
        let t = centuries(date)
        let lp = 218.3164477 + t * (481267.88123421 + t * (-0.0015786 + t * (1 / 538841 - t / 65_194_000)))
        let d = 297.8501921 + t * (445267.1114034 + t * (-0.0018819 + t * (1 / 545868 - t / 113_065_000)))
        let m = 357.5291092 + t * (35999.0502909 + t * (-0.0001536 + t / 24_490_000))
        let mp = 134.9633964 + t * (477198.8675055 + t * (0.0087414 + t * (1 / 69699 - t / 14_712_000)))
        let f = 93.2720950 + t * (483202.0175233 + t * (-0.0036539 + t * (-1 / 3_526_000 + t / 863_310_000)))
        let a1 = 119.75 + 131.849 * t
        let a2 = 53.09 + 479264.290 * t
        let a3 = 313.45 + 481266.484 * t
        let e = 1 - t * (0.002516 + 0.0000074 * t)
        var sumL = 0.0, sumR = 0.0, sumB = 0.0
        for term in moonLongitudeTerms {
            let argument = term.0 * d + term.1 * m + term.2 * mp + term.3 * f
            let factor = abs(term.1) == 1 ? e : (abs(term.1) == 2 ? e * e : 1)
            sumL += term.4 * factor * sinD(argument)
            sumR += term.5 * factor * cosD(argument)
        }
        for term in moonLatitudeTerms {
            let argument = term.0 * d + term.1 * m + term.2 * mp + term.3 * f
            let factor = abs(term.1) == 1 ? e : (abs(term.1) == 2 ? e * e : 1)
            sumB += term.4 * factor * sinD(argument)
        }
        sumL += 3958 * sinD(a1) + 1962 * sinD(lp - f) + 318 * sinD(a2)
        sumB += -2235 * sinD(lp) + 382 * sinD(a3) + 175 * sinD(a1 - f) + 175 * sinD(a1 + f) + 127 * sinD(lp - mp) - 115 * sinD(lp + mp)
        let (epsilon, nutation) = obliquityAndNutation(t)
        let lambda = normalized(lp + sumL / 1_000_000 + nutation)
        let beta = sumB / 1_000_000
        let distance = 385_000.56 + sumR / 1000
        let ra = normalized(atan2(sinD(lambda) * cosD(epsilon) - tan(beta * degree) * sinD(epsilon), cosD(lambda)) / degree)
        let dec = asin(sinD(beta) * cosD(epsilon) + cosD(beta) * sinD(epsilon) * sinD(lambda)) / degree
        return Equatorial(rightAscension: ra, declination: dec, distanceKm: distance)
    }

    /// グリニッジ平均恒星時(度)
    static func siderealTime(_ date: Date) -> Double {
        let jd = julianDay(date)
        let t = (jd - 2_451_545.0) / 36_525
        return normalized(280.46061837 + 360.98564736629 * (jd - 2_451_545.0) + t * t * (0.000387933 - t / 38_710_000))
    }

    /// 大気の屈折(度。Bennett の式。高さは屈折を考えない高さ)
    static func refraction(altitude: Double) -> Double {
        guard altitude > -1.5 else { return 0 }
        let h = max(altitude, -1)
        return 1.02 / tan((h + 10.3 / (h + 5.11)) * degree) / 60
    }

    /// 地平座標。parallax: 地平の視差を補正する(月)
    static func horizontal(_ position: Equatorial, date: Date, latitude: Double, longitude: Double, parallax: Bool = false) -> Horizontal {
        let hourAngle = normalized(siderealTime(date) + longitude - position.rightAscension)
        let altitude = asin(sinD(latitude) * sinD(position.declination) + cosD(latitude) * cosD(position.declination) * cosD(hourAngle)) / degree
        let azimuth = normalized(atan2(sinD(hourAngle), cosD(hourAngle) * sinD(latitude) - tan(position.declination * degree) * cosD(latitude)) / degree + 180)
        var topocentric = altitude
        if parallax {
            let horizontalParallax = asin(earthRadiusKm / position.distanceKm) / degree
            topocentric -= horizontalParallax * cosD(altitude)
        }
        return Horizontal(azimuth: azimuth, altitude: topocentric, apparentAltitude: topocentric + refraction(altitude: topocentric))
    }

    static func sunHorizontal(_ date: Date, latitude: Double, longitude: Double) -> Horizontal {
        horizontal(sun(date), date: date, latitude: latitude, longitude: longitude)
    }

    static func moonHorizontal(_ date: Date, latitude: Double, longitude: Double) -> Horizontal {
        horizontal(moon(date), date: date, latitude: latitude, longitude: longitude, parallax: true)
    }

    /// 見かけの半径(度)
    static func sunSemidiameter(_ date: Date) -> Double { 959.63 / 3600 / (sun(date).distanceKm / astronomicalUnit) }
    static func moonSemidiameter(_ date: Date) -> Double { asin(1737.4 / moon(date).distanceKm) / degree }

    /// 月の満ち欠け
    struct MoonPhase: Equatable {
        /// 輝いている部分の割合(0=新月、1=満月)
        var illumination: Double
        /// 満ちていく途中(新月 → 満月)
        var isWaxing: Bool
        /// 月齢の目安(日、0〜29.5。太陽と月の黄経の差から)
        var age: Double
    }

    static func moonPhase(_ date: Date) -> MoonPhase {
        let s = sun(date), m = moon(date)
        let cosElongation = sinD(s.declination) * sinD(m.declination)
            + cosD(s.declination) * cosD(m.declination) * cosD(s.rightAscension - m.rightAscension)
        let elongation = acos(max(-1, min(1, cosElongation)))
        let phaseAngle = atan2(s.distanceKm * sin(elongation), m.distanceKm - s.distanceKm * cos(elongation))
        let illumination = (1 + cos(phaseAngle)) / 2
        // 黄経の差の代わりに赤経の差で、満ちていくか欠けていくかを決める(0〜180°なら満ちていく)
        let difference = normalized(m.rightAscension - s.rightAscension)
        return MoonPhase(illumination: illumination, isWaxing: difference < 180, age: difference / 360 * 29.530589)
    }
}

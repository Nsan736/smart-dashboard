import Foundation

/// 地形の標高を引く(本物は TerrainGrid、テストでは決まった地形)
protocol TerrainSampling {
    func sample(latitude: Double, longitude: Double, distance: Double) -> TerrainGrid.Sample
}

extension TerrainGrid: TerrainSampling {}

/// 水部を引く(本物は WaterMap)。水なら水の区域の番号。
protocol WaterSampling {
    func component(latitude: Double, longitude: Double) -> Int?
}

/// 方角ごとの、見える地形の高さ(仰角)。地点の仰角と同じ計算(WaypointElevation)で、地球の丸みと大気の屈折を補正する。
struct Skyline: Equatable {
    /// 方角の刻み(度)
    static let defaultStep = 0.5

    struct Step: Equatable {
        /// 現在地からの距離(m)
        var distance: Float
        /// そこまでで一番高く見える仰角(度)
        var angle: Float
    }

    /// 1つの方角の結果。見える高さが上がった所を近い順に持つ(最後が地平線)。
    struct Ray: Equatable {
        var steps: [Step] = []
        /// 地形のデータがなくて調べられなかった距離(m)。nil なら、半径まで調べられた。
        var missingFrom: Float?

        var horizon: Step? { steps.last }

        /// distance より手前で、一番高く見える仰角。手前に何もなければ nil。
        func occludingAngle(before distance: Double) -> Double? {
            var best: Float?
            for step in steps {
                if Double(step.distance) >= distance { break }
                best = step.angle
            }
            return best.map(Double.init)
        }
    }

    enum Visibility: Equatable {
        case visible
        /// 手前の地形に隠れている
        case hidden
        /// 手前の地形のデータがなくて分からない
        case unknown
    }

    var latitude: Double
    var longitude: Double
    /// 目の高さ(m、海面から)
    var eye: Double
    var radius: Double
    var step: Double
    var rays: [Ray]

    var rayCount: Int { rays.count }

    func index(forBearing bearing: Double) -> Int {
        let normalized = (bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int((normalized / step).rounded()) % max(rays.count, 1)
    }

    func ray(atBearing bearing: Double) -> Ray { rays[index(forBearing: bearing)] }

    /// 地平線の仰角(度)
    func horizonAngle(atBearing bearing: Double) -> Double? {
        ray(atBearing: bearing).horizon.map { Double($0.angle) }
    }

    /// 半径まで調べられた方角の割合(0〜1)
    var coverage: Double {
        guard !rays.isEmpty else { return 0 }
        return Double(rays.filter { $0.missingFrom == nil }.count) / Double(rays.count)
    }

    /// 手前の地形に対して、その目標(方角・距離・仰角)が見えるか。目標のすぐ手前(2%か300m)の地形は、目標そのものなので数えない。
    /// 隣の方角も見て、どちらかで見えていれば見えるとする(山頂は方角の刻みの間にあることがあるため)。
    func visibility(bearing: Double, distance: Double, angle: Double, tolerance: Double = 0.05) -> Visibility {
        guard !rays.isEmpty else { return .unknown }
        let limit = distance - max(300, distance * 0.02)
        let center = index(forBearing: bearing)
        var sawUnknown = false
        var sawHidden = false
        for offset in [0, -1, 1] {
            let ray = rays[(center + offset + rays.count) % rays.count]
            if let missing = ray.missingFrom, Double(missing) < limit {
                sawUnknown = true
                continue
            }
            guard let blocking = ray.occludingAngle(before: limit) else { return .visible }
            if angle >= blocking - tolerance { return .visible }
            sawHidden = true
        }
        return sawHidden ? .hidden : (sawUnknown ? .unknown : .visible)
    }
}

/// 山の一覧の山頂(粗い標高タイルで低く出る山頂を補う)
struct SkylinePeak: Equatable {
    var latitude: Double
    var longitude: Double
    var elevation: Double
}

/// 見えた水面(方角ごとに一番手前のもの)
struct WaterHit: Equatable {
    var component: Int
    var distance: Double
    var latitude: Double
    var longitude: Double
    var angle: Double
    /// 標高タイルで海(データなし)だった
    var isSea: Bool
}

enum SkylineCalculator {
    /// 調べ始める距離(m)と、刻み(近くは25m、遠くは距離の1.2%)
    static let firstDistance = 25.0
    static func nextDistance(after distance: Double) -> Double {
        distance + max(25, distance * 0.012)
    }
    /// 見える高さが、これより上がったときだけ記録する(度)
    static let recordThreshold: Float = 0.02
    /// 山頂の補い: この距離より遠い山だけ(近くは細かい標高タイルで足りる)。山頂を中心に、半径3km・傾き0.25の円すいとして高さを足す
    static let peakMinimumDistance = 30_000.0
    static let peakConeRadius = 3_000.0
    static let peakConeSlope = 0.25

    /// 方角ごとに、近くを通る山頂(道のりの上の位置と、横のずれ)
    struct RayPeak {
        var along: Double
        var across: Double
        var elevation: Double
    }

    static func rayPeaks(_ peaks: [SkylinePeak], latitude: Double, longitude: Double, radius: Double, step: Double, count: Int) -> [[RayPeak]] {
        var result = Array(repeating: [RayPeak](), count: count)
        for peak in peaks {
            let d = WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: peak.latitude, longitude: peak.longitude)
            guard d > peakMinimumDistance, d <= radius + peakConeRadius else { continue }
            let b = WaypointMath.bearing(fromLatitude: latitude, longitude: longitude, toLatitude: peak.latitude, longitude: peak.longitude)
            let halfWidth = atan(peakConeRadius / d) * 180 / .pi
            let first = Int(floor((b - halfWidth) / step)), last = Int(ceil((b + halfWidth) / step))
            for k in first...last {
                let index = ((k % count) + count) % count
                let offset = (b - Double(k) * step) * .pi / 180
                let across = abs(d * sin(offset))
                guard across < peakConeRadius else { continue }
                result[index].append(RayPeak(along: d * cos(offset), across: across, elevation: peak.elevation))
            }
        }
        for index in result.indices { result[index].sort { $0.along < $1.along } }
        return result
    }

    /// 稜線を計算する。water を渡すと、方角ごとに一番手前の見える水面も返す。
    static func compute(latitude: Double, longitude: Double, eye: Double, radius: Double, terrain: TerrainSampling,
                        water: WaterSampling? = nil, peaks: [SkylinePeak] = [],
                        step: Double = Skyline.defaultStep) -> (skyline: Skyline, water: [WaterHit?]) {
        let count = max(1, Int((360 / step).rounded()))
        let peaksByRay = peaks.isEmpty ? [] : rayPeaks(peaks, latitude: latitude, longitude: longitude, radius: radius, step: step, count: count)
        var rays: [Skyline.Ray] = []
        rays.reserveCapacity(count)
        var hits: [WaterHit?] = Array(repeating: nil, count: water == nil ? 0 : count)
        let lat0 = latitude * .pi / 180
        let lon0 = longitude * .pi / 180
        let sinLat0 = sin(lat0), cosLat0 = cos(lat0)
        for index in 0..<count {
            let bearing = Double(index) * step * .pi / 180
            let sinB = sin(bearing), cosB = cos(bearing)
            var ray = Skyline.Ray()
            var best = -Float.greatestFiniteMagnitude
            var distance = firstDistance
            let nearPeaks = peaksByRay.isEmpty ? [] : peaksByRay[index]
            while distance <= radius {
                // 大円の上で、方角 bearing に distance 進んだ点
                let delta = distance / WaypointElevation.earthRadius
                let sinD = sin(delta), cosD = cos(delta)
                let sinLat = sinLat0 * cosD + cosLat0 * sinD * cosB
                let lat = asin(sinLat)
                let lon = lon0 + atan2(sinB * sinD * cosLat0, cosD - sinLat0 * sinLat)
                let latDeg = lat * 180 / .pi, lonDeg = lon * 180 / .pi
                let sample = terrain.sample(latitude: latDeg, longitude: lonDeg, distance: distance)
                guard var height = sample.height else {
                    ray.missingFrom = Float(distance)
                    break
                }
                // 近くを通る山頂の円すいの高さで補う(粗いタイルでは山頂が低く出るため)
                for peak in nearPeaks where abs(distance - peak.along) < peakConeRadius {
                    let offset = ((distance - peak.along) * (distance - peak.along) + peak.across * peak.across).squareRoot()
                    height = max(height, peak.elevation - peakConeSlope * offset)
                }
                let angle = Float(WaypointElevation.angle(targetAltitude: height, observerAltitude: eye, distance: distance))
                if let water, hits[index] == nil, angle >= best, let component = water.component(latitude: latDeg, longitude: lonDeg) {
                    hits[index] = WaterHit(component: component, distance: distance, latitude: latDeg, longitude: lonDeg,
                                           angle: Double(angle), isSea: sample == .sea)
                }
                if angle > best {
                    if let last = ray.steps.last, angle - last.angle < recordThreshold {
                        // 少しずつ上がるときは、最後の記録を更新するだけにして、数を抑える
                        ray.steps[ray.steps.count - 1] = Skyline.Step(distance: Float(distance), angle: angle)
                    } else {
                        ray.steps.append(Skyline.Step(distance: Float(distance), angle: angle))
                    }
                    best = angle
                }
                var next = nextDistance(after: distance)
                // 山頂の位置を飛ばさないように、その距離でも調べる
                if let special = nearPeaks.first(where: { $0.along > distance && $0.along < next }) { next = special.along }
                distance = next
            }
            rays.append(ray)
        }
        return (Skyline(latitude: latitude, longitude: longitude, eye: eye, radius: radius, step: step, rays: rays), hits)
    }
}

/// 描く稜線の線(方角と仰角の点の並び)。代表の距離で濃さを変える。
struct RidgeLine: Equatable {
    struct Point: Equatable {
        var bearing: Double
        var angle: Double
    }

    var points: [Point]
    /// 代表の距離(m、点の距離の中央値)
    var distance: Double
    /// 地平線(一番奥の稜線)
    var isHorizon: Bool

    /// 濃さ(近いほど濃い。1km で0.95、10km で0.6、100km で0.25)
    static func opacity(distance: Double) -> Double {
        min(0.95, max(0.25, 0.95 - 0.35 * log10(max(distance, 1000) / 1000)))
    }

    static func lineWidth(distance: Double) -> Double {
        min(2.4, max(1.0, 2.4 - 0.6 * log10(max(distance, 1000) / 1000)))
    }
}

enum RidgeExtractor {
    /// 1つの方角で、稜線とみなす点: 次に見える所まで距離が開いている(その奥は手前の稜線より低く、谷になっている)所と、地平線
    static let gapRatio: Float = 1.15
    static let gapMeters: Float = 200
    /// 1つの方角で使う稜線の数(地平線を除く)
    static let maxRidgesPerRay = 4
    /// 隣の方角の点とつなぐ距離の比
    static let linkRatio = 1.25
    static let minimumPoints = 3

    static func ridges(of ray: Skyline.Ray) -> [(step: Skyline.Step, isHorizon: Bool)] {
        guard let horizon = ray.horizon else { return [] }
        var result: [(step: Skyline.Step, isHorizon: Bool)] = []
        for i in 0..<(ray.steps.count - 1) {
            let current = ray.steps[i], next = ray.steps[i + 1]
            if next.distance > current.distance * gapRatio + gapMeters {
                result.append((step: current, isHorizon: false))
            }
        }
        // 近い稜線を優先する(遠い稜線は地平線と重なりやすい)
        if result.count > maxRidgesPerRay { result = Array(result.prefix(maxRidgesPerRay)) }
        result.append((step: horizon, isHorizon: true))
        return result
    }

    /// 方角ごとの稜線の点を、隣の方角で距離の近い点とつないで線にする
    static func lines(from skyline: Skyline) -> [RidgeLine] {
        struct Open {
            var points: [RidgeLine.Point]
            var distances: [Float]
            var isHorizon: Bool
            var lastIndex: Int
        }
        var open: [Open] = []
        var finished: [RidgeLine] = []
        func close(_ line: Open) {
            guard line.points.count >= minimumPoints else { return }
            let sorted = line.distances.sorted()
            finished.append(RidgeLine(points: line.points, distance: Double(sorted[sorted.count / 2]), isHorizon: line.isHorizon))
        }
        for (index, ray) in skyline.rays.enumerated() {
            let bearing = Double(index) * skyline.step
            var next: [Open] = []
            var used = Set<Int>()
            for (step, isHorizon) in ridges(of: ray) {
                let point = RidgeLine.Point(bearing: bearing, angle: Double(step.angle))
                // 前の方角から続く線のうち、距離が一番近いもの
                var bestIndex: Int?
                var bestRatio = linkRatio
                for (k, line) in open.enumerated() where !used.contains(k) && line.isHorizon == isHorizon {
                    let last = Double(line.distances.last ?? 0)
                    let ratio = max(last, Double(step.distance)) / max(min(last, Double(step.distance)), 1)
                    if ratio <= bestRatio {
                        bestRatio = ratio
                        bestIndex = k
                    }
                }
                if let k = bestIndex {
                    used.insert(k)
                    var line = open[k]
                    line.points.append(point)
                    line.distances.append(step.distance)
                    line.lastIndex = index
                    next.append(line)
                } else {
                    next.append(Open(points: [point], distances: [step.distance], isHorizon: isHorizon, lastIndex: index))
                }
            }
            for (k, line) in open.enumerated() where !used.contains(k) { close(line) }
            open = next
        }
        for line in open { close(line) }
        return finished
    }
}

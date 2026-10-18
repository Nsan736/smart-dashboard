import Foundation

/// オブジェクトの中の座標(m)。x=右、y=前、z=上
typealias ObjectPoint = SIMD3<Double>

/// 形の1つの面(多角形)。頂点はオブジェクトの中の座標
struct ObjectFace: Equatable {
    var vertices: [ObjectPoint]
    var color: String
    var opacity: Double
}

/// 形を面に分ける。軽さのため、丸い形は少ない面で近似する(円柱・円錐は12角形、球は経度10×緯度6)。
enum ObjectGeometry {
    static let roundSegments = 12
    static let sphereLongitudes = 10
    static let sphereLatitudes = 6

    /// 粗い版(遠いとき): 円柱・円錐は6角形、球は経度6×緯度3
    static let lowRoundSegments = 6
    static let lowSphereLongitudes = 6
    static let lowSphereLatitudes = 3

    /// 大きさ1の形の面(中心が原点、各辺が −0.5〜0.5)
    static func unitFaces(_ kind: ObjectShapeKind, low: Bool = false) -> [[ObjectPoint]] {
        let roundSegments = low ? lowRoundSegments : self.roundSegments
        let sphereLongitudes = low ? lowSphereLongitudes : self.sphereLongitudes
        let sphereLatitudes = low ? lowSphereLatitudes : self.sphereLatitudes
        switch kind {
        case .box:
            let c = [ObjectPoint(-0.5, -0.5, -0.5), ObjectPoint(0.5, -0.5, -0.5), ObjectPoint(0.5, 0.5, -0.5), ObjectPoint(-0.5, 0.5, -0.5),
                     ObjectPoint(-0.5, -0.5, 0.5), ObjectPoint(0.5, -0.5, 0.5), ObjectPoint(0.5, 0.5, 0.5), ObjectPoint(-0.5, 0.5, 0.5)]
            return [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]].map { $0.map { c[$0] } }
        case .cylinder, .cone:
            let ring = circle(z: -0.5, segments: roundSegments)
            var faces: [[ObjectPoint]] = [ring.reversed()]
            if kind == .cylinder {
                let top = circle(z: 0.5, segments: roundSegments)
                faces.append(top)
                for i in 0..<roundSegments {
                    let j = (i + 1) % roundSegments
                    faces.append([ring[i], ring[j], top[j], top[i]])
                }
            } else {
                let apex = ObjectPoint(0, 0, 0.5)
                for i in 0..<roundSegments {
                    faces.append([ring[i], ring[(i + 1) % roundSegments], apex])
                }
            }
            return faces
        case .sphere:
            var faces: [[ObjectPoint]] = []
            func point(_ lat: Int, _ lon: Int) -> ObjectPoint {
                let theta = Double(lat) / Double(sphereLatitudes) * .pi - .pi / 2
                let phi = Double(lon) / Double(sphereLongitudes) * 2 * .pi
                return ObjectPoint(0.5 * cos(theta) * sin(phi), 0.5 * cos(theta) * cos(phi), 0.5 * sin(theta))
            }
            for lat in 0..<sphereLatitudes {
                for lon in 0..<sphereLongitudes {
                    let a = point(lat, lon), b = point(lat, lon + 1), c = point(lat + 1, lon + 1), d = point(lat + 1, lon)
                    // 極の近くは三角形になる
                    if lat == 0 { faces.append([a, c, d]) } else if lat == sphereLatitudes - 1 { faces.append([a, b, d]) } else { faces.append([a, b, c, d]) }
                }
            }
            return faces
        case .pyramid:
            let base = [ObjectPoint(-0.5, -0.5, -0.5), ObjectPoint(0.5, -0.5, -0.5), ObjectPoint(0.5, 0.5, -0.5), ObjectPoint(-0.5, 0.5, -0.5)]
            let apex = ObjectPoint(0, 0, 0.5)
            var faces: [[ObjectPoint]] = [base.reversed()]
            for i in 0..<4 { faces.append([base[i], base[(i + 1) % 4], apex]) }
            return faces
        case .plane:
            return [[ObjectPoint(-0.5, 0, -0.5), ObjectPoint(0.5, 0, -0.5), ObjectPoint(0.5, 0, 0.5), ObjectPoint(-0.5, 0, 0.5)]]
        }
    }

    private static func circle(z: Double, segments: Int) -> [ObjectPoint] {
        (0..<segments).map { i in
            let a = Double(i) / Double(segments) * 2 * .pi
            return ObjectPoint(0.5 * sin(a), 0.5 * cos(a), z)
        }
    }

    /// 回転(度): ロール(右が下がる)→ ピッチ(前が上がる)→ ヨー(上から見て時計回り)
    static func rotate(_ p: ObjectPoint, yaw: Double, pitch: Double, roll: Double) -> ObjectPoint {
        let r = roll * .pi / 180, pt = pitch * .pi / 180, y = yaw * .pi / 180
        // ロール: 前の軸のまわり
        var v = ObjectPoint(p.x * cos(r) + p.z * sin(r), p.y, -p.x * sin(r) + p.z * cos(r))
        // ピッチ: 右の軸のまわり
        v = ObjectPoint(v.x, v.y * cos(pt) - v.z * sin(pt), v.y * sin(pt) + v.z * cos(pt))
        // ヨー: 上の軸のまわり(時計回り)
        return ObjectPoint(v.x * cos(y) + v.y * sin(y), -v.x * sin(y) + v.y * cos(y), v.z)
    }

    /// 形の面(オブジェクトの中の座標)。low: 丸い形を粗くする
    static func faces(of shape: ObjectShape, low: Bool = false) -> [ObjectFace] {
        let size = ObjectPoint(shape.width, shape.kind == .plane ? 0 : shape.depth, shape.height)
        let center = ObjectPoint(shape.x, shape.y, shape.z + shape.height / 2)
        return unitFaces(shape.kind, low: low).map { face in
            ObjectFace(vertices: face.map { rotate($0 * size, yaw: shape.yaw, pitch: shape.pitch, roll: shape.roll) + center },
                       color: shape.color, opacity: shape.opacity)
        }
    }

    static func faces(of object: ScopeObject) -> [ObjectFace] {
        object.shapes.flatMap { faces(of: $0) }
    }

    /// 形の大きさ(一番長い辺、m)。遠いときに省く形を決めるのに使う
    static func size(of shape: ObjectShape) -> Double {
        max(shape.width, shape.kind == .plane ? 0 : shape.depth, shape.height)
    }

    /// 粗い版の面と、その面の形の大きさ(遠いときに、小さい形を省くため)
    static func lowFaces(of object: ScopeObject) -> [(face: ObjectFace, size: Double)] {
        object.shapes.flatMap { shape in faces(of: shape, low: true).map { (face: $0, size: size(of: shape)) } }
    }

    /// 全体を囲む1つの箱(もっと遠いとき)。色は一番大きい形の色、不透明度は形の平均
    static func boundingBoxFaces(of object: ScopeObject) -> [ObjectFace] {
        let points = faces(of: object).flatMap(\.vertices)
        guard let first = points.first else { return [] }
        var lo = first, hi = first
        for p in points {
            lo = ObjectPoint(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = ObjectPoint(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        let largest = object.shapes.max { volume($0) < volume($1) }
        let opacity = object.shapes.map(\.opacity).reduce(0, +) / Double(max(object.shapes.count, 1))
        let size = hi - lo
        let center = (hi + lo) / 2
        return unitFaces(.box).map { face in
            ObjectFace(vertices: face.map { $0 * size + center }, color: largest?.color ?? ObjectShape.defaultColor, opacity: opacity)
        }
    }

    static func volume(_ shape: ObjectShape) -> Double {
        shape.width * (shape.kind == .plane ? 0.1 : shape.depth) * shape.height
    }

    /// 置いたときの向きと倍率を反映した点(x=東、y=北、z=上。置いた場所の地面からの高さ)
    static func placed(_ p: ObjectPoint, heading: Double, scale: Double, heightAboveGround: Double) -> ObjectPoint {
        let h = heading * .pi / 180
        let s = p * scale
        // 前(y)が方角 heading、右(x)が heading+90°
        let east = s.x * cos(h) + s.y * sin(h)
        let north = -s.x * sin(h) + s.y * cos(h)
        return ObjectPoint(east, north, s.z + heightAboveGround)
    }

    /// オブジェクトの中心(原点)からの一番遠い点までの距離(m、倍率1)
    static func radius(of object: ScopeObject) -> Double {
        faces(of: object).flatMap(\.vertices).map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }.max() ?? 0
    }

    /// 大きさ(幅・奥行き・高さ、倍率1)。全部の頂点を囲む箱
    static func extent(of object: ScopeObject) -> (width: Double, depth: Double, height: Double) {
        let points = faces(of: object).flatMap(\.vertices)
        guard let first = points.first else { return (0, 0, 0) }
        var lo = first, hi = first
        for p in points {
            lo = ObjectPoint(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = ObjectPoint(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return (hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
    }

    /// 足元の形(上から見た輪郭。凸包)。東・北の m(置いた向きと倍率を反映)
    static func footprint(of object: ScopeObject, heading: Double, scale: Double) -> [SIMD2<Double>] {
        let points = faces(of: object).flatMap(\.vertices).map { p -> SIMD2<Double> in
            let q = placed(p, heading: heading, scale: scale, heightAboveGround: 0)
            return SIMD2(q.x, q.y)
        }
        return convexHull(points)
    }

    /// 凸包(反時計回り。Andrew の方法)
    static func convexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 1e-9 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Double>] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 1e-9 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

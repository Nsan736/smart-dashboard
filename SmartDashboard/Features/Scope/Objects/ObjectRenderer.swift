import SwiftUI

/// カメラ表示に描くオブジェクト(置いたものと、その形の面)
struct ObjectDrawInput {
    struct Item {
        var placement: ObjectPlacement
        var object: ScopeObject
        /// オブジェクトの中の座標の面(作るたびに計算しないよう、先に作っておく)
        var faces: [ObjectFace]
        /// 粗い版の面と、その面の形の大きさ(遠いときに、小さい形を省く)
        var lowFaces: [(face: ObjectFace, size: Double)]
        /// 全体を囲む1つの箱(もっと遠いとき)
        var boxFaces: [ObjectFace]
        /// 原点から一番遠い点までの距離(倍率1)
        var radius: Double
        /// 高さ(倍率1)
        var height: Double

        init(placement: ObjectPlacement, object: ScopeObject) {
            self.placement = placement
            self.object = object
            faces = ObjectGeometry.faces(of: object)
            lowFaces = ObjectGeometry.lowFaces(of: object)
            boxFaces = ObjectGeometry.boundingBoxFaces(of: object)
            radius = ObjectGeometry.radius(of: object)
            height = ObjectGeometry.extent(of: object).height
        }

        func faceCount(_ level: ObjectLOD) -> Int {
            switch level {
            case .full: return faces.count
            case .medium: return lowFaces.count
            case .box: return boxFaces.count
            case .ring: return 0
            }
        }
    }

    var items: [Item]
    /// 現在地(位置のデバッグの間は仮想の位置)
    var user: GeoPoint
    /// 自分の目の高さ(m)。分からなければ、オブジェクトの地面 + 手の高さ
    var observerAltitude: Double?
    var handHeight: Double

    static func make(placements: [ObjectPlacement], objects: [ScopeObject], user: GeoPoint, observerAltitude: Double?,
                     handHeight: Double) -> ObjectDrawInput {
        let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items: [Item] = placements.filter { !$0.isHidden }.compactMap { placement in
            guard let object = byID[placement.objectID] else { return nil }
            return Item(placement: placement, object: object)
        }
        return ObjectDrawInput(items: items, user: user, observerAltitude: observerAltitude, handHeight: handHeight)
    }
}

/// 距離(画面での大きさ)に応じた簡略化の段階
enum ObjectLOD: Int, Comparable, CaseIterable {
    /// すべての形(丸い形は12角形・経度10×緯度6)
    case full
    /// 丸い形を粗くし(6角形・経度6×緯度3)、画面で小さい形(一番長い辺が2pt未満)を省く
    case medium
    /// 全体を囲む1つの箱
    case box
    /// 地点と同じリングの印
    case ring

    static func < (a: ObjectLOD, b: ObjectLOD) -> Bool { a.rawValue < b.rawValue }

    /// 画面での半径(pt)から決める段階
    static let fullRadius: CGFloat = 80
    static let mediumRadius: CGFloat = 25
    static let boxRadius: CGFloat = 10
    /// medium で省く形の大きさ(画面で、pt)
    static let minimumShapeSize: CGFloat = 2

    static func level(radiusOnScreen: CGFloat) -> ObjectLOD {
        if radiusOnScreen >= fullRadius { return .full }
        if radiusOnScreen >= mediumRadius { return .medium }
        if radiusOnScreen >= boxRadius { return .box }
        return .ring
    }

    var coarser: ObjectLOD { ObjectLOD(rawValue: rawValue + 1) ?? .ring }

    struct Candidate {
        var id: Int
        var radiusOnScreen: CGFloat
        var faceCounts: [ObjectLOD: Int]
    }

    /// 面の数の上限(budget)の中で、段階を決める。画面で大きく見えるもの(近いもの・大きいもの)から割り当て、
    /// 残りに入らなければ、1段ずつ粗くする(最後はリングの印。印は面を使わない)
    static func plan(_ candidates: [Candidate], budget: Int) -> [Int: ObjectLOD] {
        var remaining = budget
        var result: [Int: ObjectLOD] = [:]
        for candidate in candidates.sorted(by: { $0.radiusOnScreen > $1.radiusOnScreen }) {
            var level = Self.level(radiusOnScreen: candidate.radiusOnScreen)
            while level != .ring, candidate.faceCounts[level] ?? 0 > remaining { level = level.coarser }
            result[candidate.id] = level
            remaining -= candidate.faceCounts[level] ?? 0
        }
        return result
    }
}

/// オブジェクトを、電車の車両の箱と同じ投影(ScopeTrainRenderer.project)と地球の丸みの補正で、カメラ表示の Canvas に描く。
/// 面は遠いものから塗る(画家のアルゴリズム)。半透明の面は裏側も描くので、ガラスのように奥が透けて見える。
/// 画面での大きさに応じて簡略化し(ObjectLOD)、1コマの面は maxFaces まで(大きく見えるものから割り当てる)。
enum ObjectRenderer {
    /// 1コマに塗る面の上限
    static let maxFaces = 2000
    /// 光の向き(北と上の間から)。面の向きで明るさを変え、立体に見せる
    static let light = Vector3(x: 0.35, y: 0.2, z: 1).unit

    struct DrawFace {
        var points: [CGPoint]
        var fill: Color
        var stroke: Color?
        var depth: Double
        /// 同じ塗りの面を1つの Path にまとめるための目印(色と明るさの段階)
        var key: String
    }

    struct Ring {
        var placementID: UUID
        var point: CGPoint
        var target: ScopeTarget
    }

    struct HitArea {
        var placementID: UUID
        var rect: CGRect
        var distance: Double
    }

    struct Label {
        var text: String
        var point: CGPoint
    }

    struct Layout {
        var faces: [DrawFace] = []
        var rings: [Ring] = []
        var labels: [Label] = []
        var hits: [HitArea] = []
        /// 置いたもの → 使った段階
        var levels: [UUID: ObjectLOD] = [:]
    }

    /// 地面の標高(分からなければ、自分の高さ − 手の高さ。それも分からなければ0)
    static func ground(_ placement: ObjectPlacement, observerAltitude: Double?, handHeight: Double) -> Double {
        placement.groundElevation ?? observerAltitude.map { $0 - handHeight } ?? 0
    }

    /// オブジェクトの中の点を、現在地から見た基準の座標系(x=北、y=西、z=上。目の高さが0)のベクトルにする
    static func vector(_ p: ObjectPoint, placement: ObjectPlacement, base: (x: Double, y: Double), groundRelative: Double) -> Vector3 {
        let q = ObjectGeometry.placed(p, heading: placement.heading, scale: placement.scale, heightAboveGround: placement.heightAboveGround)
        return Vector3(x: base.y + q.y, y: -(base.x + q.x), z: groundRelative + q.z)
    }

    /// 画面での長さ(pt)。奥行き depth の所の、長さ length(m)
    static func screenLength(_ length: Double, depth: Double, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> CGFloat {
        guard depth > ScopeTrainRenderer.nearPlane else { return .infinity }
        return CGFloat(length / depth / max(tangents.horizontal, 0.0001)) * size.width / 2
    }

    static func layout(_ input: ObjectDrawInput, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double),
                       size: CGSize) -> Layout {
        var layout = Layout()
        let screen = CGRect(origin: .zero, size: size)
        struct Prepared {
            var item: ObjectDrawInput.Item
            var base: (x: Double, y: Double)
            var distance: Double
            var groundRelative: Double
            var centerVector: Vector3
            var depth: Double
            var radiusOnScreen: CGFloat
        }
        // 1. 画面での大きさを求める
        var prepared: [Prepared] = []
        for item in input.items {
            let placement = item.placement
            let base = GeoMath.local(GeoPoint(placement.latitude, placement.longitude), origin: input.user)
            let distance = (base.x * base.x + base.y * base.y).squareRoot()
            let ground = Self.ground(placement, observerAltitude: input.observerAltitude, handHeight: input.handHeight)
            let eye = input.observerAltitude ?? ground + input.handHeight
            // 地面との高低差と、地球の丸みによる見かけの低下(地点・電車と同じ計算)
            let groundRelative = ground - eye - WaypointElevation.curvatureDrop(distance: distance)
            let centerVector = vector(ObjectPoint(0, 0, item.height / 2), placement: placement, base: base, groundRelative: groundRelative)
            let depth = Vector3.dot(centerVector, attitude.forward)
            let reach = item.radius * placement.scale
            // 自分より後ろにあって、自分を包んでもいないものは描かない
            if depth <= ScopeTrainRenderer.nearPlane, distance > reach { continue }
            prepared.append(Prepared(item: item, base: base, distance: distance, groundRelative: groundRelative, centerVector: centerVector,
                                     depth: depth, radiusOnScreen: screenLength(reach, depth: depth, tangents: tangents, size: size)))
        }
        // 2. 面の上限の中で、段階を決める(大きく見えるものから)
        let plan = ObjectLOD.plan(prepared.indices.map { index in
            let item = prepared[index].item
            return ObjectLOD.Candidate(id: index, radiusOnScreen: prepared[index].radiusOnScreen,
                                       faceCounts: Dictionary(uniqueKeysWithValues: ObjectLOD.allCases.map { ($0, item.faceCount($0)) }))
        }, budget: maxFaces)

        var faces: [DrawFace] = []
        for (index, entry) in prepared.enumerated() {
            let placement = entry.item.placement
            let level = plan[index] ?? .ring
            layout.levels[placement.id] = level
            if level == .ring {
                // 遠いものは、地点と同じリングの印
                guard let point = ScopeTrainRenderer.project(entry.centerVector, attitude: attitude, tangents: tangents, size: size),
                      screen.contains(point) else { continue }
                let color = entry.item.object.shapes.first?.color ?? ObjectShape.defaultColor
                let mark = ScopeMark(id: placement.id.uuidString, name: placement.name, latitude: placement.latitude,
                                     longitude: placement.longitude, color: ObjectColor.color(color))
                layout.rings.append(Ring(placementID: placement.id, point: point, target: ScopeTarget(mark: mark, bearing: 0, distance: entry.distance)))
                let ring = WaypointMarkStyle.ringDiameter / 2 + 4
                layout.hits.append(HitArea(placementID: placement.id, rect: CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2),
                                           distance: entry.distance))
                continue
            }
            let source: [ObjectFace]
            switch level {
            case .full: source = entry.item.faces
            case .box: source = entry.item.boxFaces
            default:
                // 画面で小さい形は省く
                let minimum = Double(ObjectLOD.minimumShapeSize)
                source = entry.item.lowFaces.filter {
                    Double(screenLength($0.size * placement.scale, depth: entry.depth, tangents: tangents, size: size)) >= minimum
                }.map { $0.face }
            }
            var bounds = CGRect.null
            for face in source {
                let vectors = face.vertices.map { vector($0, placement: placement, base: entry.base, groundRelative: entry.groundRelative) }
                // 自分の後ろ側に回り込む面は描かない
                let projected = vectors.map { ScopeTrainRenderer.project($0, attitude: attitude, tangents: tangents, size: size) }
                guard projected.allSatisfy({ $0 != nil }) else { continue }
                let points = projected.compactMap { $0 }
                let faceBounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                bounds = bounds.union(faceBounds)
                guard faceBounds.intersects(screen) else { continue }
                let meanDepth = vectors.reduce(0) { $0 + Vector3.dot($1, attitude.forward) } / Double(vectors.count)
                // 明るさは段階に丸めて、同じ塗りの面をまとめやすくする
                let shade = (shading(vectors) / 0.08).rounded() * 0.08
                let rgb = ObjectColor.rgb(face.color) ?? (1, 0, 0)
                let fill = Color(red: rgb.r * shade, green: rgb.g * shade, blue: rgb.b * shade).opacity(face.opacity)
                // 縁の線は、近くの細かい表示のときだけ(線を引く分の負荷を減らす)
                let stroke = level == .full ? Color(red: rgb.r * 0.5, green: rgb.g * 0.5, blue: rgb.b * 0.5).opacity(min(1, face.opacity + 0.3)) : nil
                faces.append(DrawFace(points: points, fill: fill, stroke: stroke, depth: meanDepth,
                                      key: "\(face.color)|\(shade)|\(face.opacity)|\(level.rawValue)"))
            }
            guard !bounds.isNull, bounds.intersects(screen) else { continue }
            layout.hits.append(HitArea(placementID: placement.id, rect: bounds.insetBy(dx: -12, dy: -12), distance: entry.distance))
            layout.labels.append(Label(text: "\(placement.name)  \(SceneryText.distance(entry.distance))", point: CGPoint(x: bounds.midX, y: bounds.minY - 12)))
        }
        // 遠い面から描く。それでも上限を超えるときは、近い面を残す
        let ordered = faces.sorted { $0.depth > $1.depth }
        layout.faces = ordered.count > maxFaces ? Array(ordered.suffix(maxFaces)) : ordered
        // リングは遠いものから(近いものが手前)
        layout.rings.sort { $0.target.distance > $1.target.distance }
        return layout
    }

    /// 面の明るさ(0.62〜1)。面の向きと光の向きの角度で決める(裏と表は同じ明るさ)
    static func shading(_ vectors: [Vector3]) -> Double {
        guard vectors.count >= 3 else { return 1 }
        let a = Vector3(x: vectors[1].x - vectors[0].x, y: vectors[1].y - vectors[0].y, z: vectors[1].z - vectors[0].z)
        let b = Vector3(x: vectors[2].x - vectors[0].x, y: vectors[2].y - vectors[0].y, z: vectors[2].z - vectors[0].z)
        let normal = Vector3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x).unit
        return 0.62 + 0.38 * abs(Vector3.dot(normal, light))
    }

    /// 描く順のまま、続けて同じ塗りの面を1つの Path にまとめて、塗る回数を減らす
    static func batches(_ faces: [DrawFace]) -> [(path: Path, fill: Color, stroke: Color?)] {
        var result: [(path: Path, fill: Color, stroke: Color?)] = []
        var currentKey: String?
        var path = Path()
        var fill = Color.clear
        var stroke: Color?
        for face in faces {
            if face.key != currentKey {
                if currentKey != nil { result.append((path, fill, stroke)) }
                currentKey = face.key
                path = Path()
                fill = face.fill
                stroke = face.stroke
            }
            path.addLines(face.points)
            path.closeSubpath()
        }
        if currentKey != nil { result.append((path, fill, stroke)) }
        return result
    }

    static func draw(_ context: inout GraphicsContext, layout: Layout) {
        for batch in batches(layout.faces) {
            context.fill(batch.path, with: .color(batch.fill), style: FillStyle(eoFill: false))
            if let stroke = batch.stroke { context.stroke(batch.path, with: .color(stroke), lineWidth: 0.6) }
        }
        for ring in layout.rings {
            ScopeOverlay.drawMark(&context, at: ring.point, target: ring.target)
        }
        for label in layout.labels {
            SceneryRenderer.drawTag(&context, text: label.text, at: label.point, color: .white, fontSize: 12, weight: .semibold, background: 0.55)
        }
    }

    /// タップした所のオブジェクト(重なっていれば近いもの)
    static func hit(_ location: CGPoint, layout: Layout) -> UUID? {
        layout.hits.filter { $0.rect.contains(location) }.min { $0.distance < $1.distance }?.placementID
    }
}

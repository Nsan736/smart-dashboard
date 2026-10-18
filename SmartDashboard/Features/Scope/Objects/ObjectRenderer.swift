import SwiftUI

/// カメラ表示に描くオブジェクト(置いたものと、その形の面)
struct ObjectDrawInput {
    struct Item {
        var placement: ObjectPlacement
        var object: ScopeObject
        /// オブジェクトの中の座標の面(作るたびに計算しないよう、先に作っておく)
        var faces: [ObjectFace]
        /// 原点から一番遠い点までの距離(倍率1)
        var radius: Double
        /// 高さ(倍率1)
        var height: Double
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
            return Item(placement: placement, object: object, faces: ObjectGeometry.faces(of: object),
                        radius: ObjectGeometry.radius(of: object), height: ObjectGeometry.extent(of: object).height)
        }
        return ObjectDrawInput(items: items, user: user, observerAltitude: observerAltitude, handHeight: handHeight)
    }
}

/// オブジェクトを、電車の車両の箱と同じ投影(ScopeTrainRenderer.project)と地球の丸みの補正で、カメラ表示の Canvas に描く。
/// 面は遠いものから塗る(画家のアルゴリズム)。半透明の面は裏側も描くので、ガラスのように奥が透けて見える。
/// 画面で小さすぎるもの(半径が minimumRadius 未満)は、地点と同じリングの印にする。
enum ObjectRenderer {
    /// 画面での半径(pt)がこれ未満なら、リングの印
    static let minimumRadius: CGFloat = 10
    /// 1コマに塗る面の上限(近いものから)
    static let maxFaces = 2000
    /// 光の向き(北と上の間から)。面の向きで明るさを変え、立体に見せる
    static let light = Vector3(x: 0.35, y: 0.2, z: 1).unit

    struct DrawFace {
        var points: [CGPoint]
        var fill: Color
        var stroke: Color
        var depth: Double
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

    static func layout(_ input: ObjectDrawInput, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double),
                       size: CGSize) -> Layout {
        var layout = Layout()
        var faces: [DrawFace] = []
        let screen = CGRect(origin: .zero, size: size)
        for item in input.items {
            let placement = item.placement
            let base = GeoMath.local(GeoPoint(placement.latitude, placement.longitude), origin: input.user)
            let distance = (base.x * base.x + base.y * base.y).squareRoot()
            let ground = Self.ground(placement, observerAltitude: input.observerAltitude, handHeight: input.handHeight)
            let eye = input.observerAltitude ?? ground + input.handHeight
            // 地面との高低差と、地球の丸みによる見かけの低下(地点・電車と同じ計算)
            let groundRelative = ground - eye - WaypointElevation.curvatureDrop(distance: distance)
            let middle = ObjectPoint(0, 0, item.height / 2)
            let centerVector = vector(middle, placement: placement, base: base, groundRelative: groundRelative)
            let depth = Vector3.dot(centerVector, attitude.forward)
            let color = placement.isHidden ? "#888888" : (item.object.shapes.first?.color ?? ObjectShape.defaultColor)
            let radiusOnScreen: CGFloat = depth > ScopeTrainRenderer.nearPlane
                ? CGFloat(item.radius * placement.scale / depth / max(tangents.horizontal, 0.0001)) * size.width / 2
                : .infinity
            if radiusOnScreen < minimumRadius {
                // 遠いものは、地点と同じリングの印
                guard let point = ScopeTrainRenderer.project(centerVector, attitude: attitude, tangents: tangents, size: size),
                      screen.contains(point) else { continue }
                let mark = ScopeMark(id: placement.id.uuidString, name: placement.name, latitude: placement.latitude,
                                     longitude: placement.longitude, color: ObjectColor.color(color))
                let target = ScopeTarget(mark: mark, bearing: 0, distance: distance)
                layout.rings.append(Ring(placementID: placement.id, point: point, target: target))
                let ring = WaypointMarkStyle.ringDiameter / 2 + 4
                layout.hits.append(HitArea(placementID: placement.id, rect: CGRect(x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2),
                                           distance: distance))
                continue
            }
            var bounds = CGRect.null
            for face in item.faces {
                let vectors = face.vertices.map { vector($0, placement: placement, base: base, groundRelative: groundRelative) }
                // 自分の後ろ側に回り込む面は描かない
                let projected = vectors.map { ScopeTrainRenderer.project($0, attitude: attitude, tangents: tangents, size: size) }
                guard projected.allSatisfy({ $0 != nil }) else { continue }
                let points = projected.compactMap { $0 }
                let faceBounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                bounds = bounds.union(faceBounds)
                guard faceBounds.intersects(screen) else { continue }
                let meanDepth = vectors.reduce(0) { $0 + Vector3.dot($1, attitude.forward) } / Double(vectors.count)
                let shade = shading(vectors)
                let rgb = ObjectColor.rgb(face.color) ?? (1, 0, 0)
                let fill = Color(red: rgb.r * shade, green: rgb.g * shade, blue: rgb.b * shade).opacity(face.opacity)
                let stroke = Color(red: rgb.r * 0.5, green: rgb.g * 0.5, blue: rgb.b * 0.5).opacity(min(1, face.opacity + 0.3))
                faces.append(DrawFace(points: points, fill: fill, stroke: stroke, depth: meanDepth))
            }
            guard !bounds.isNull, bounds.intersects(screen) else { continue }
            layout.hits.append(HitArea(placementID: placement.id, rect: bounds.insetBy(dx: -12, dy: -12), distance: distance))
            layout.labels.append(Label(text: "\(placement.name)  \(SceneryText.distance(distance))", point: CGPoint(x: bounds.midX, y: bounds.minY - 12)))
        }
        // 遠い面から描く。多すぎるときは、近い面を残す
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

    static func draw(_ context: inout GraphicsContext, layout: Layout) {
        for face in layout.faces {
            var path = Path()
            path.addLines(face.points)
            path.closeSubpath()
            context.fill(path, with: .color(face.fill))
            context.stroke(path, with: .color(face.stroke), lineWidth: 0.6)
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

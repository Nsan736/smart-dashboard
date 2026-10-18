import SwiftUI

/// 景色の描き方の設定(層と、隠れた山を出すか)
struct SceneryDrawOptions: Equatable {
    var layers: Set<SceneryLayer>
    var showsHiddenMountains: Bool
    /// 山の高さの強調(仰角に掛ける倍率。1 なら実際の見え方)
    var heightScale: Double = 1
}

/// 設定の「山の高さの強調」(景色の稜線・山・水面・地名の仰角に掛ける)
enum SceneryHeightScale {
    static let choices: [Double] = [1, 1.5, 2]

    static func label(_ value: Double) -> String {
        value == 1 ? "1倍(実際の見え方)" : String(format: "%.1f倍", value).replacingOccurrences(of: ".0倍", with: "倍")
    }
}

/// カメラ表示の Canvas に、景色(稜線・水面の帯・川と地名・山)を描く。毎コマ、画面に入るものだけを投影して描く。
/// 地点・電車の印と同じ Canvas の中で、印より先に(奥に)描く。
enum SceneryRenderer {
    static let mountainFontSize: CGFloat = 12
    static let labelFontSize: CGFloat = 11
    static let rowHeight: CGFloat = 17
    static let markerWidth: CGFloat = 14
    static let markerHeight: CGFloat = 11
    /// 1コマに描く山の数の上限(優先の高い順)
    static let maxMountains = 30
    static let waterColor = Color(red: 0.25, green: 0.65, blue: 1.0)

    struct MountainItem {
        var mountain: SceneryMountain
        var point: CGPoint
        var row: Int?
    }

    struct Layout {
        var ridges: [(path: Path, opacity: Double, width: Double)] = []
        var water: [(path: Path, label: CGPoint?, band: WaterBand)] = []
        var labels: [(point: CGPoint, label: SceneryLabel)] = []
        var mountains: [MountainItem] = []
    }

    /// 画面の中心の方角から離れすぎた点は、投影せずに飛ばす(度)
    static func viewLimit(tangents: (horizontal: Double, vertical: Double)) -> Double {
        atan(max(tangents.horizontal, tangents.vertical)) * 180 / .pi + 12
    }

    static func layout(scene: SceneryScene, options: SceneryDrawOptions, attitude: CameraAttitude,
                       tangents: (horizontal: Double, vertical: Double), size: CGSize) -> Layout {
        var layout = Layout()
        let center = attitude.azimuth
        let limit = viewLimit(tangents: tangents)
        func inView(_ bearing: Double) -> Bool { abs(WaypointMath.difference(from: center, to: bearing)) <= limit }
        let scale = options.heightScale
        func project(_ bearing: Double, _ angle: Double) -> CGPoint? {
            WaypointProjection.point(bearing: bearing, elevation: angle * scale, attitude: attitude, tangents: tangents, viewSize: size)
        }

        if options.layers.contains(.skyline) {
            // 遠い稜線から描く(近い稜線が手前)
            for line in scene.ridges.sorted(by: { $0.distance > $1.distance }) {
                var path = Path()
                var penDown = false
                for point in line.points {
                    guard inView(point.bearing), let p = project(point.bearing, point.angle) else {
                        penDown = false
                        continue
                    }
                    if penDown { path.addLine(to: p) } else { path.move(to: p); penDown = true }
                }
                if !path.isEmpty {
                    layout.ridges.append((path, RidgeLine.opacity(distance: line.distance), RidgeLine.lineWidth(distance: line.distance)))
                }
            }
        }

        if options.layers.contains(.water) {
            for band in scene.water where inView(band.centerBearing) || band.width > limit {
                var path = Path()
                var penDown = false
                var bearing = band.startBearing
                while bearing <= band.endBearing + 0.001 {
                    if inView(bearing), let p = project(bearing, band.angle) {
                        if penDown { path.addLine(to: p) } else { path.move(to: p); penDown = true }
                    } else {
                        penDown = false
                    }
                    bearing += 1
                }
                guard !path.isEmpty else { continue }
                layout.water.append((path, project(band.centerBearing, band.angle), band))
            }
            for label in scene.labels where label.kind == .river && inView(label.bearing) {
                if let p = project(label.bearing, label.angle) { layout.labels.append((p, label)) }
            }
        }
        if options.layers.contains(.places) {
            for label in scene.labels where label.kind == .place && inView(label.bearing) {
                if let p = project(label.bearing, label.angle) { layout.labels.append((p, label)) }
            }
        }

        if options.layers.contains(.mountains) {
            var items: [MountainItem] = []
            for mountain in scene.mountains where options.showsHiddenMountains || !mountain.isHidden {
                guard items.count < maxMountains, inView(mountain.bearing),
                      let p = project(mountain.bearing, mountain.angle) else { continue }
                items.append(MountainItem(mountain: mountain, point: p, row: nil))
            }
            // 優先の高い順(scene.mountains の並び)に、重ならない段へ名前を置く
            let rows = SceneryLabelLayout.place(items.indices.map { index in
                SceneryLabelLayout.Item(id: index, x: items[index].point.x,
                                        width: SceneryLabelLayout.estimatedWidth(mountainText(items[index].mountain), fontSize: mountainFontSize))
            })
            for index in items.indices { items[index].row = rows[index] }
            layout.mountains = items
        }
        return layout
    }

    static func mountainText(_ mountain: SceneryMountain) -> String {
        "\(mountain.entry.shortName) \(SceneryText.elevation(mountain.entry.elevation))・\(SceneryText.distance(mountain.distance))"
    }

    static func draw(_ context: inout GraphicsContext, layout: Layout) {
        for ridge in layout.ridges {
            // 暗い縁取りの上に白い線(明るい空でも、暗い山でも見えるように)
            context.stroke(ridge.path, with: .color(Color.black.opacity(ridge.opacity * 0.45)),
                           style: StrokeStyle(lineWidth: ridge.width + 1.6, lineCap: .round, lineJoin: .round))
            context.stroke(ridge.path, with: .color(Color.white.opacity(ridge.opacity)),
                           style: StrokeStyle(lineWidth: ridge.width, lineCap: .round, lineJoin: .round))
        }
        for water in layout.water {
            context.stroke(water.path, with: .color(waterColor.opacity(0.5)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            if let point = water.label {
                drawTag(&context, text: "\(water.band.name) \(SceneryText.distance(water.band.distance))", at: CGPoint(x: point.x, y: point.y + 14),
                        color: waterColor, fontSize: labelFontSize)
            }
        }
        for item in layout.labels {
            let color: Color = item.label.kind == .river ? waterColor : Color.white.opacity(0.85)
            context.fill(Path(ellipseIn: CGRect(x: item.point.x - 2.5, y: item.point.y - 2.5, width: 5, height: 5)), with: .color(color))
            drawTag(&context, text: "\(item.label.name) \(SceneryText.distance(item.label.distance))", at: CGPoint(x: item.point.x, y: item.point.y - 12),
                    color: color, fontSize: labelFontSize)
        }
        // 優先の低いものから描き、優先の高い山が上に来るようにする
        for item in layout.mountains.reversed() {
            drawMountain(&context, item: item)
        }
    }

    static func drawMountain(_ context: inout GraphicsContext, item: MountainItem) {
        let hidden = item.mountain.isHidden
        let p = item.point
        // 山の形の印(頂点が山頂の位置)
        var marker = Path()
        marker.move(to: p)
        marker.addLine(to: CGPoint(x: p.x - markerWidth / 2, y: p.y + markerHeight))
        marker.addLine(to: CGPoint(x: p.x + markerWidth / 2, y: p.y + markerHeight))
        marker.closeSubpath()
        if hidden {
            context.stroke(marker, with: .color(Color.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
        } else {
            context.fill(marker, with: .color(Color(red: 0.55, green: 0.38, blue: 0.22)))
            context.stroke(marker, with: .color(.white), lineWidth: 1.2)
        }
        guard let row = item.row else { return }
        let text = mountainText(item.mountain) + (hidden ? "(見えない)" : "")
        let labelY = p.y - 6 - CGFloat(row) * rowHeight - rowHeight / 2
        if row > 0 {
            var leader = Path()
            leader.move(to: CGPoint(x: p.x, y: p.y - 2))
            leader.addLine(to: CGPoint(x: p.x, y: labelY + rowHeight / 2 - 2))
            context.stroke(leader, with: .color(Color.white.opacity(hidden ? 0.3 : 0.6)), lineWidth: 0.8)
        }
        drawTag(&context, text: text, at: CGPoint(x: p.x, y: labelY), color: hidden ? Color.white.opacity(0.55) : .white,
                fontSize: mountainFontSize, weight: .semibold, background: hidden ? 0.25 : 0.5)
    }

    /// 背景つきの文字(中心の位置)
    static func drawTag(_ context: inout GraphicsContext, text: String, at center: CGPoint, color: Color, fontSize: CGFloat,
                        weight: Font.Weight = .medium, background: Double = 0.45) {
        let resolved = context.resolve(Text(text).font(.system(size: fontSize, weight: weight)).foregroundColor(color))
        let size = resolved.measure(in: CGSize(width: 260, height: 40))
        let rect = CGRect(x: center.x - size.width / 2 - 4, y: center.y - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color.black.opacity(background)))
        context.draw(resolved, in: rect.insetBy(dx: 4, dy: 1))
    }

    /// タップした所に一番近い山(印から32pt以内)
    static func hitMountain(_ location: CGPoint, layout: Layout) -> SceneryMountain? {
        var best: (SceneryMountain, CGFloat)?
        for item in layout.mountains {
            let markerCenter = CGPoint(x: item.point.x, y: item.point.y + markerHeight / 2)
            var distance = hypot(location.x - markerCenter.x, location.y - markerCenter.y)
            if let row = item.row {
                let labelY = item.point.y - 6 - CGFloat(row) * rowHeight - rowHeight / 2
                distance = min(distance, hypot((location.x - item.point.x) * 0.5, location.y - labelY))
            }
            if distance <= 32, best.map({ distance < $0.1 }) ?? true { best = (item.mountain, distance) }
        }
        return best?.0
    }
}

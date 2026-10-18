import SwiftUI

/// 方角のデバッグ表示で、カメラ表示に描く東西南北の印と水平線。地点などと同じ投影(`WaypointProjection.point`)で、
/// 方角0°・90°・180°・270°(と、その間の4つ)を仰角0(水平線の高さ)にそのまま描く。
/// 実際の北に「北」が重なれば投影は正しく、ずれていれば投影かカメラの向きの値がおかしい。
enum ScopeCompassRose {
    struct Mark: Equatable {
        var name: String
        var bearing: Double
        var point: CGPoint
        /// 東西南北(大きく描く)か、その間(小さく描く)か
        var isCardinal: Bool
    }

    static let names = ["北", "北東", "東", "南東", "南", "南西", "西", "北西"]

    /// 画面に入る印
    static func marks(attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> [Mark] {
        names.enumerated().compactMap { item in
            let index = item.offset
            let name = item.element
            let bearing = Double(index) * 45
            guard let point = WaypointProjection.point(bearing: bearing, elevation: 0, attitude: attitude, tangents: tangents, viewSize: size) else {
                return nil
            }
            return Mark(name: name, bearing: bearing, point: point, isCardinal: index % 2 == 0)
        }
    }

    /// 水平線(方角1°ごとの、仰角0の点を結んだ線)
    static func horizon(attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> Path {
        var path = Path()
        var penDown = false
        for step in 0...360 {
            guard let point = WaypointProjection.point(bearing: Double(step), elevation: 0, attitude: attitude, tangents: tangents, viewSize: size) else {
                penDown = false
                continue
            }
            if penDown { path.addLine(to: point) } else { path.move(to: point); penDown = true }
        }
        return path
    }

    /// 画面の中央の方角と、その方角に一番近い印(「中央 123° → 南東(135°)の印が右に12°」)
    static func centerText(azimuth: Double) -> String {
        let index = Int((WaypointMath.normalized(azimuth) + 22.5) / 45) % 8
        let bearing = Double(index) * 45
        let offset = WaypointMath.difference(from: azimuth, to: bearing)
        let side: String
        if abs(offset) < 0.5 {
            side = "が中央"
        } else {
            side = offset > 0 ? "の印が右に\(Int(offset.rounded()))°" : "の印が左に\(Int((-offset).rounded()))°"
        }
        return "中央 \(Int(WaypointMath.normalized(azimuth).rounded()))° → \(names[index])(\(Int(bearing))°)" + side
    }

    /// 仰角の目盛り(−2°〜+10°、1°ごと。v0.9.29)。地平線(0°)は黄色の線で別に描く
    static let rulerDegrees = Array(-2...10).filter { $0 != 0 }

    /// 仰角 elevation の横線(今の向きの左右60°の範囲で、画面に入る部分)
    static func elevationLine(_ elevation: Double, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> Path {
        var path = Path()
        var penDown = false
        for step in -60...60 {
            let bearing = attitude.azimuth + Double(step)
            guard let point = WaypointProjection.point(bearing: bearing, elevation: elevation, attitude: attitude, tangents: tangents, viewSize: size) else {
                penDown = false
                continue
            }
            if penDown { path.addLine(to: point) } else { path.move(to: point); penDown = true }
        }
        return path
    }

    /// 画面の中央の方角での、仰角 elevation の高さ(画面の y。画面の外なら nil)
    static func elevationY(_ elevation: Double, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> CGFloat? {
        WaypointProjection.point(bearing: attitude.azimuth, elevation: elevation, attitude: attitude, tangents: tangents, viewSize: size)?.y
    }

    static func drawRuler(_ context: inout GraphicsContext, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) {
        for degrees in rulerDegrees {
            let path = elevationLine(Double(degrees), attitude: attitude, tangents: tangents, size: size)
            context.stroke(path, with: .color(Color.white.opacity(degrees % 5 == 0 ? 0.7 : 0.4)),
                           style: StrokeStyle(lineWidth: degrees % 5 == 0 ? 1 : 0.6, dash: [4, 3]))
            guard let y = elevationY(Double(degrees), attitude: attitude, tangents: tangents, size: size) else { continue }
            let label = context.resolve(Text(String(format: "%+d°", degrees)).font(.system(size: 10, weight: .semibold)).foregroundColor(.white))
            context.draw(label, at: CGPoint(x: size.width - 20, y: y), anchor: .center)
        }
    }

    static func draw(_ context: inout GraphicsContext, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) {
        drawRuler(&context, attitude: attitude, tangents: tangents, size: size)
        let line = horizon(attitude: attitude, tangents: tangents, size: size)
        context.stroke(line, with: .color(Color.black.opacity(0.5)), lineWidth: 3)
        context.stroke(line, with: .color(Color.yellow.opacity(0.9)), lineWidth: 1)
        for mark in marks(attitude: attitude, tangents: tangents, size: size) {
            let tick = Path { path in
                path.move(to: CGPoint(x: mark.point.x, y: mark.point.y - (mark.isCardinal ? 14 : 8)))
                path.addLine(to: CGPoint(x: mark.point.x, y: mark.point.y + (mark.isCardinal ? 14 : 8)))
            }
            context.stroke(tick, with: .color(.yellow), lineWidth: mark.isCardinal ? 3 : 1.5)
            let label = context.resolve(Text("\(mark.name) \(Int(mark.bearing))°")
                .font(.system(size: mark.isCardinal ? 17 : 12, weight: .bold))
                .foregroundColor(.yellow))
            let labelSize = label.measure(in: CGSize(width: 120, height: 30))
            let rect = CGRect(x: mark.point.x - labelSize.width / 2 - 4, y: mark.point.y - 18 - labelSize.height - 4,
                              width: labelSize.width + 8, height: labelSize.height + 4)
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color.black.opacity(0.6)))
            context.draw(label, in: rect.insetBy(dx: 4, dy: 2))
        }
    }
}

/// カメラ表示の上に重ねる、東西南北の印・水平線と、画面の中央の十字と方角(方角のデバッグ表示のとき)
struct ScopeCompassRoseOverlay: View {
    let attitude: CameraAttitude
    let tangents: (horizontal: Double, vertical: Double)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Canvas(rendersAsynchronously: false) { context, canvasSize in
                    ScopeCompassRose.draw(&context, attitude: attitude, tangents: tangents, size: canvasSize)
                    // 画面の中央の十字
                    let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    var cross = Path()
                    cross.move(to: CGPoint(x: center.x - 12, y: center.y))
                    cross.addLine(to: CGPoint(x: center.x + 12, y: center.y))
                    cross.move(to: CGPoint(x: center.x, y: center.y - 12))
                    cross.addLine(to: CGPoint(x: center.x, y: center.y + 12))
                    context.stroke(cross, with: .color(.white), lineWidth: 2)
                }
                Text(ScopeCompassRose.centerText(azimuth: attitude.azimuth))
                    .font(.footnote.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6), in: Capsule())
                    .position(x: size.width / 2, y: size.height / 2 + 34)
            }
        }
        .allowsHitTesting(false)
    }
}

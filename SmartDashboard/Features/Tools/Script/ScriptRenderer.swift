import SwiftUI

/// 1コマ分の描画の命令を、SwiftUI の Canvas(GraphicsContext)に描く。画面の表示と PNG の書き出しで同じものを使う。
enum ScriptRenderer {
    private struct State {
        var fill: ScriptPaint = .color(.black)
        var stroke: ScriptPaint = .color(.black)
        var lineWidth: CGFloat = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter
        var dash: [CGFloat] = []
        var font = ScriptFont()
        var textAlign = 0
        var textBaseline = 0
        var alpha = 1.0
        var smoothing = true
    }

    static func color(_ rgba: ScriptRGBA) -> Color {
        Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    static func shading(_ paint: ScriptPaint) -> GraphicsContext.Shading {
        switch paint {
        case .color(let rgba):
            return .color(color(rgba))
        case .linear(let start, let end, let stops):
            return .linearGradient(gradient(stops), startPoint: start, endPoint: end)
        case .radial(let center, let startRadius, let endRadius, let stops):
            return .radialGradient(gradient(stops), center: center, startRadius: startRadius, endRadius: endRadius)
        }
    }

    private static func gradient(_ stops: [ScriptGradientStop]) -> Gradient {
        guard !stops.isEmpty else { return Gradient(colors: [.black, .black]) }
        return Gradient(stops: stops.map { Gradient.Stop(color: color($0.color), location: $0.offset) })
    }

    private static func font(_ font: ScriptFont) -> Font {
        let design: Font.Design
        switch font.design {
        case .standard: design = .default
        case .monospaced: design = .monospaced
        case .serif: design = .serif
        case .rounded: design = .rounded
        }
        var result = Font.system(size: font.size, weight: font.bold ? .bold : .regular, design: design)
        if font.italic { result = result.italic() }
        return result
    }

    /// 文字を置く位置の基準(textAlign と textBaseline から)
    static func anchor(align: Int, baseline: Int) -> UnitPoint {
        let x: CGFloat = align == 1 ? 0.5 : align == 2 ? 1 : 0
        // alphabetic は、文字の下の線(だいたい高さの8割の位置)で近似する
        let y: CGFloat = baseline == 1 ? 0 : baseline == 2 ? 0.5 : baseline == 3 ? 1 : 0.8
        return UnitPoint(x: x, y: y)
    }

    static func draw(_ ops: [ScriptDrawOp], images: [Int: CGImage], in base: inout GraphicsContext) {
        var context = base
        let origin = context.transform
        var state = State()
        var stack: [(GraphicsContext, State)] = []
        var path = Path()

        func strokeStyle() -> StrokeStyle {
            StrokeStyle(lineWidth: state.lineWidth, lineCap: state.lineCap, lineJoin: state.lineJoin, dash: state.dash)
        }

        for op in ops {
            switch op {
            case .save:
                if stack.count < 64 { stack.append((context, state)) }
            case .restore:
                if let (savedContext, savedState) = stack.popLast() {
                    context = savedContext
                    state = savedState
                }
            case .translate(let x, let y): context.translateBy(x: x, y: y)
            case .rotate(let angle): context.rotate(by: .radians(Double(angle)))
            case .scale(let x, let y): context.scaleBy(x: x, y: y)
            case .transform(let t): context.concatenate(t)
            case .resetTransform: context.transform = origin
            case .alpha(let alpha):
                state.alpha = alpha
                context.opacity = alpha
            case .fillStyle(let paint): state.fill = paint
            case .strokeStyle(let paint): state.stroke = paint
            case .lineWidth(let width): state.lineWidth = width
            case .lineCap(let cap): state.lineCap = cap
            case .lineJoin(let join): state.lineJoin = join
            case .lineDash(let dash): state.dash = dash
            case .font(let font): state.font = font
            case .textAlign(let align): state.textAlign = align
            case .textBaseline(let baseline): state.textBaseline = baseline
            case .smoothing(let on): state.smoothing = on
            case .beginPath: path = Path()
            case .move(let point): path.move(to: point)
            case .line(let point):
                if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            case .quad(let control, let to):
                if path.isEmpty { path.move(to: control) }
                path.addQuadCurve(to: to, control: control)
            case .bezier(let control1, let control2, let to):
                if path.isEmpty { path.move(to: control1) }
                path.addCurve(to: to, control1: control1, control2: control2)
            case .arc(let center, let radius, let start, let end, let anticlockwise):
                // Canvas 2D と同じ向き(y が下向きの座標で、anticlockwise が false なら画面の時計回り)
                path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: anticlockwise)
            case .ellipse(let center, let rx, let ry, let rotation, let start, let end, let anticlockwise):
                guard rx > 0, ry > 0 else { continue }
                var unit = Path()
                let begin = CGPoint(x: cos(start), y: sin(start))
                unit.move(to: begin)
                unit.addArc(center: .zero, radius: 1, startAngle: .radians(start), endAngle: .radians(end), clockwise: anticlockwise)
                let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(rotation)).scaledBy(x: rx, y: ry)
                let shaped = unit.applying(transform)
                if path.isEmpty { path = shaped } else { path.addPath(shaped) }
            case .rect(let rect): path.addRect(rect)
            case .closePath: path.closeSubpath()
            case .fillPath: context.fill(path, with: shading(state.fill))
            case .strokePath: context.stroke(path, with: shading(state.stroke), style: strokeStyle())
            case .fillRect(let rect): context.fill(Path(rect), with: shading(state.fill))
            case .strokeRect(let rect): context.stroke(Path(rect), with: shading(state.stroke), style: strokeStyle())
            case .clearRect(let rect):
                var clearing = context
                clearing.blendMode = .clear
                clearing.opacity = 1
                clearing.fill(Path(rect), with: .color(.black))
            case .clip: context.clip(to: path)
            case .fillText(let string, let point), .strokeText(let string, let point):
                // 文字は塗りの色(グラデーションのときは最初の色)で描く。線だけの文字は、線の色で塗る。
                let paint: ScriptPaint
                if case .strokeText = op { paint = state.stroke } else { paint = state.fill }
                let text = Text(string).font(font(state.font)).foregroundColor(color(paint.flatColor))
                context.draw(text, at: point, anchor: anchor(align: state.textAlign, baseline: state.textBaseline))
            case .image(let id, let rect):
                guard let cgImage = images[id] else { continue }
                var image = Image(decorative: cgImage, scale: 1)
                if !state.smoothing { image = image.interpolation(.none) }
                context.draw(image, in: rect)
            case .imageSub(let id, let source, let dest):
                guard let cgImage = images[id], let cropped = cgImage.cropping(to: source.integral) else { continue }
                var image = Image(decorative: cropped, scale: 1)
                if !state.smoothing { image = image.interpolation(.none) }
                context.draw(image, in: dest)
            }
        }
    }
}

/// スクリプトのキャンバス(表示と、PNG の書き出しの両方で使う)
struct ScriptCanvasView: View {
    let ops: [ScriptDrawOp]
    let images: [Int: CGImage]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            ScriptRenderer.draw(ops, images: images, in: &context)
        }
    }
}

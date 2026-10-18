import CoreGraphics
import Foundation

/// 色(0〜1)
struct ScriptRGBA: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let black = ScriptRGBA(r: 0, g: 0, b: 0, a: 1)
    static let clear = ScriptRGBA(r: 0, g: 0, b: 0, a: 0)
}

/// CSS の色の書き方を読む(#rgb、#rgba、#rrggbb、#rrggbbaa、rgb()、rgba()、hsl()、hsla()、よく使う色の名前)
enum ScriptColor {
    static let names: [String: (Int, Int, Int)] = [
        "black": (0, 0, 0), "white": (255, 255, 255), "red": (255, 0, 0), "green": (0, 128, 0), "lime": (0, 255, 0),
        "blue": (0, 0, 255), "yellow": (255, 255, 0), "cyan": (0, 255, 255), "aqua": (0, 255, 255), "magenta": (255, 0, 255),
        "fuchsia": (255, 0, 255), "orange": (255, 165, 0), "purple": (128, 0, 128), "pink": (255, 192, 203), "brown": (165, 42, 42),
        "gray": (128, 128, 128), "grey": (128, 128, 128), "silver": (192, 192, 192), "navy": (0, 0, 128), "teal": (0, 128, 128),
        "olive": (128, 128, 0), "maroon": (128, 0, 0), "gold": (255, 215, 0), "skyblue": (135, 206, 235), "darkgray": (169, 169, 169),
        "lightgray": (211, 211, 211), "darkgreen": (0, 100, 0), "crimson": (220, 20, 60), "coral": (255, 127, 80), "violet": (238, 130, 238),
    ]

    static func parse(_ text: String) -> ScriptRGBA? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "transparent" { return .clear }
        if let rgb = names[s] { return ScriptRGBA(r: Double(rgb.0) / 255, g: Double(rgb.1) / 255, b: Double(rgb.2) / 255, a: 1) }
        if s.hasPrefix("#") { return hex(String(s.dropFirst())) }
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            let name = s[..<open].trimmingCharacters(in: .whitespaces)
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
            let parts = inner.replacingOccurrences(of: "/", with: " ").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            switch name {
            case "rgb", "rgba":
                guard parts.count == 3 || parts.count == 4 else { return nil }
                guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
                let a = parts.count == 4 ? alpha(parts[3]) : 1
                guard let a else { return nil }
                return ScriptRGBA(r: r, g: g, b: b, a: a)
            case "hsl", "hsla":
                guard parts.count == 3 || parts.count == 4, let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                      let sat = percent(parts[1]), let light = percent(parts[2]) else { return nil }
                let a = parts.count == 4 ? alpha(parts[3]) : 1
                guard let a else { return nil }
                let rgb = hslToRGB(h: h, s: sat, l: light)
                return ScriptRGBA(r: rgb.0, g: rgb.1, b: rgb.2, a: a)
            default:
                return nil
            }
        }
        return nil
    }

    private static func hex(_ s: String) -> ScriptRGBA? {
        guard s.allSatisfy(\.isHexDigit) else { return nil }
        let digits = Array(s)
        func value(_ chars: ArraySlice<Character>) -> Double { Double(Int(String(chars), radix: 16) ?? 0) }
        switch digits.count {
        case 3, 4:
            let v = digits.map { value([$0, $0][...]) / 255 }
            return ScriptRGBA(r: v[0], g: v[1], b: v[2], a: digits.count == 4 ? v[3] : 1)
        case 6, 8:
            let v = stride(from: 0, to: digits.count, by: 2).map { value(digits[$0..<($0 + 2)]) / 255 }
            return ScriptRGBA(r: v[0], g: v[1], b: v[2], a: digits.count == 8 ? v[3] : 1)
        default:
            return nil
        }
    }

    private static func channel(_ s: String) -> Double? {
        if s.hasSuffix("%") { return Double(s.dropLast()).map { min(max($0 / 100, 0), 1) } }
        return Double(s).map { min(max($0 / 255, 0), 1) }
    }

    private static func alpha(_ s: String) -> Double? {
        if s.hasSuffix("%") { return Double(s.dropLast()).map { min(max($0 / 100, 0), 1) } }
        return Double(s).map { min(max($0, 0), 1) }
    }

    private static func percent(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: "%", with: "")).map { min(max($0 / 100, 0), 1) }
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func component(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (component(hue + 1.0 / 3), component(hue), component(hue - 1.0 / 3))
    }
}

/// 文字の書体(CSS の font の書き方の一部: 「bold 20px sans-serif」「16px monospace」)
struct ScriptFont: Equatable {
    enum Design: Equatable {
        case standard
        case monospaced
        case serif
        case rounded
    }

    var size: Double = 10
    var bold = false
    var italic = false
    var design: Design = .standard

    static func parse(_ text: String) -> ScriptFont {
        var font = ScriptFont()
        for token in text.lowercased().split(separator: " ").map(String.init) {
            if token.hasSuffix("px"), let size = Double(token.dropLast(2)) {
                font.size = min(max(size, 1), 400)
            } else if token.hasSuffix("pt"), let size = Double(token.dropLast(2)) {
                font.size = min(max(size, 1), 400)
            } else if token == "bold" || token == "bolder" || (Int(token).map { $0 >= 600 } ?? false) {
                font.bold = true
            } else if token == "italic" || token == "oblique" {
                font.italic = true
            } else if token.contains("mono") {
                font.design = .monospaced
            } else if token == "serif" || token.contains("times") || token.contains("georgia") || token.contains("mincho") {
                font.design = .serif
            } else if token.contains("rounded") {
                font.design = .rounded
            }
        }
        return font
    }
}

struct ScriptGradientStop: Equatable {
    var offset: Double
    var color: ScriptRGBA
}

/// 塗りと線の指定
enum ScriptPaint: Equatable {
    case color(ScriptRGBA)
    case linear(start: CGPoint, end: CGPoint, stops: [ScriptGradientStop])
    case radial(center: CGPoint, startRadius: CGFloat, endRadius: CGFloat, stops: [ScriptGradientStop])

    /// 文字など、グラデーションを使えないところで使う色
    var flatColor: ScriptRGBA {
        switch self {
        case .color(let color): return color
        case .linear(_, _, let stops), .radial(_, _, _, let stops): return stops.first?.color ?? .black
        }
    }
}

/// 1コマ分の描画命令(JavaScript 側でまとめた数の列から作る)
enum ScriptDrawOp: Equatable {
    case save
    case restore
    case translate(CGFloat, CGFloat)
    case rotate(CGFloat)
    case scale(CGFloat, CGFloat)
    case transform(CGAffineTransform)
    case resetTransform
    case alpha(Double)
    case fillStyle(ScriptPaint)
    case strokeStyle(ScriptPaint)
    case lineWidth(CGFloat)
    case lineCap(CGLineCap)
    case lineJoin(CGLineJoin)
    case lineDash([CGFloat])
    case font(ScriptFont)
    /// 0: 左(start)、1: 中央、2: 右(end)
    case textAlign(Int)
    /// 0: alphabetic、1: top、2: middle、3: bottom
    case textBaseline(Int)
    case smoothing(Bool)
    case beginPath
    case move(CGPoint)
    case line(CGPoint)
    case quad(control: CGPoint, to: CGPoint)
    case bezier(control1: CGPoint, control2: CGPoint, to: CGPoint)
    case arc(center: CGPoint, radius: CGFloat, start: Double, end: Double, anticlockwise: Bool)
    case ellipse(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, rotation: Double, start: Double, end: Double, anticlockwise: Bool)
    case rect(CGRect)
    case closePath
    case fillPath
    case strokePath
    case fillRect(CGRect)
    case strokeRect(CGRect)
    case clearRect(CGRect)
    case clip
    case fillText(String, CGPoint)
    case strokeText(String, CGPoint)
    case image(id: Int, rect: CGRect)
    case imageSub(id: Int, source: CGRect, dest: CGRect)
}

/// JavaScript 側の命令の番号(ScriptPrelude と同じ値にする)
enum ScriptOpCode {
    static let save = 1.0, restore = 2.0, translate = 3.0, rotate = 4.0, scale = 5.0, transform = 6.0, resetTransform = 7.0
    static let alpha = 10.0, fillColor = 11.0, strokeColor = 12.0, fillGradient = 13.0, strokeGradient = 14.0
    static let lineWidth = 15.0, lineCap = 16.0, lineJoin = 17.0, font = 18.0, textAlign = 19.0, textBaseline = 20.0, lineDash = 21.0
    static let smoothing = 22.0
    static let beginPath = 30.0, move = 31.0, line = 32.0, quad = 33.0, bezier = 34.0, arc = 35.0, rect = 36.0, closePath = 37.0, ellipse = 38.0
    static let fill = 40.0, stroke = 41.0, fillRect = 42.0, strokeRect = 43.0, clearRect = 44.0, clip = 45.0
    static let fillText = 50.0, strokeText = 51.0
    static let image = 60.0, imageSub = 61.0
    static let linearGradient = 70.0, radialGradient = 71.0
}

/// 数の列(と文字の表)を描画命令に変える。読めない命令があれば、そこで止める(以降は描かない)。
struct ScriptDrawDecoder {
    /// 1コマの命令の数の上限(これを超えた分は描かない)
    static let maxOps = 20_000
    static let maxTextLength = 200

    /// 文字の表(JavaScript 側で、同じ文字を番号で送る)。コマをまたいで使う。
    private(set) var strings: [String] = []
    /// 色の読み取りの結果(文字の番号 → 色)
    private var colorCache: [Int: ScriptRGBA] = [:]
    private var fontCache: [Int: ScriptFont] = [:]

    /// JavaScript 側で文字の表を作り直したとき
    mutating func resetStrings() {
        strings = []
        colorCache = [:]
        fontCache = [:]
    }

    mutating func addStrings(_ new: [String]) {
        strings += new
    }

    private mutating func color(_ index: Int) -> ScriptRGBA {
        if let cached = colorCache[index] { return cached }
        let parsed = strings.indices.contains(index) ? (ScriptColor.parse(strings[index]) ?? .black) : .black
        colorCache[index] = parsed
        return parsed
    }

    private mutating func font(_ index: Int) -> ScriptFont {
        if let cached = fontCache[index] { return cached }
        let parsed = ScriptFont.parse(strings.indices.contains(index) ? strings[index] : "")
        fontCache[index] = parsed
        return parsed
    }

    private func text(_ index: Int) -> String {
        strings.indices.contains(index) ? String(strings[index].prefix(Self.maxTextLength)) : ""
    }

    mutating func decode(_ values: [Double]) -> [ScriptDrawOp] {
        var ops: [ScriptDrawOp] = []
        var gradients: [Int: ScriptPaint] = [:]
        var i = 0
        let count = values.count
        func has(_ k: Int) -> Bool { i + k <= count }
        func v(_ k: Int) -> Double { values[i + k] }
        func f(_ k: Int) -> CGFloat {
            let value = values[i + k]
            return value.isFinite ? CGFloat(value) : 0
        }
        func p(_ k: Int) -> CGPoint { CGPoint(x: f(k), y: f(k + 1)) }
        func r(_ k: Int) -> CGRect { CGRect(x: f(k), y: f(k + 1), width: f(k + 2), height: f(k + 3)) }

        while i < count, ops.count < Self.maxOps {
            let code = values[i]
            i += 1
            switch code {
            case ScriptOpCode.save: ops.append(.save)
            case ScriptOpCode.restore: ops.append(.restore)
            case ScriptOpCode.translate:
                guard has(2) else { return ops }
                ops.append(.translate(f(0), f(1))); i += 2
            case ScriptOpCode.rotate:
                guard has(1) else { return ops }
                ops.append(.rotate(f(0))); i += 1
            case ScriptOpCode.scale:
                guard has(2) else { return ops }
                ops.append(.scale(f(0), f(1))); i += 2
            case ScriptOpCode.transform:
                guard has(6) else { return ops }
                ops.append(.transform(CGAffineTransform(a: f(0), b: f(1), c: f(2), d: f(3), tx: f(4), ty: f(5)))); i += 6
            case ScriptOpCode.resetTransform: ops.append(.resetTransform)
            case ScriptOpCode.alpha:
                guard has(1) else { return ops }
                ops.append(.alpha(min(max(v(0).isFinite ? v(0) : 1, 0), 1))); i += 1
            case ScriptOpCode.fillColor, ScriptOpCode.strokeColor:
                guard has(1) else { return ops }
                let paint = ScriptPaint.color(color(Int(v(0))))
                ops.append(code == ScriptOpCode.fillColor ? .fillStyle(paint) : .strokeStyle(paint)); i += 1
            case ScriptOpCode.fillGradient, ScriptOpCode.strokeGradient:
                guard has(1) else { return ops }
                let paint = gradients[Int(v(0))] ?? .color(.black)
                ops.append(code == ScriptOpCode.fillGradient ? .fillStyle(paint) : .strokeStyle(paint)); i += 1
            case ScriptOpCode.lineWidth:
                guard has(1) else { return ops }
                ops.append(.lineWidth(max(0, min(f(0), 1000)))); i += 1
            case ScriptOpCode.lineCap:
                guard has(1) else { return ops }
                ops.append(.lineCap([CGLineCap.butt, .round, .square][min(max(Int(v(0)), 0), 2)])); i += 1
            case ScriptOpCode.lineJoin:
                guard has(1) else { return ops }
                ops.append(.lineJoin([CGLineJoin.miter, .round, .bevel][min(max(Int(v(0)), 0), 2)])); i += 1
            case ScriptOpCode.lineDash:
                guard has(1) else { return ops }
                let n = min(max(Int(v(0)), 0), 16)
                guard has(1 + n) else { return ops }
                ops.append(.lineDash((0..<n).map { max(0, f(1 + $0)) })); i += 1 + n
            case ScriptOpCode.font:
                guard has(1) else { return ops }
                ops.append(.font(font(Int(v(0))))); i += 1
            case ScriptOpCode.textAlign:
                guard has(1) else { return ops }
                ops.append(.textAlign(min(max(Int(v(0)), 0), 2))); i += 1
            case ScriptOpCode.textBaseline:
                guard has(1) else { return ops }
                ops.append(.textBaseline(min(max(Int(v(0)), 0), 3))); i += 1
            case ScriptOpCode.smoothing:
                guard has(1) else { return ops }
                ops.append(.smoothing(v(0) != 0)); i += 1
            case ScriptOpCode.beginPath: ops.append(.beginPath)
            case ScriptOpCode.move:
                guard has(2) else { return ops }
                ops.append(.move(p(0))); i += 2
            case ScriptOpCode.line:
                guard has(2) else { return ops }
                ops.append(.line(p(0))); i += 2
            case ScriptOpCode.quad:
                guard has(4) else { return ops }
                ops.append(.quad(control: p(0), to: p(2))); i += 4
            case ScriptOpCode.bezier:
                guard has(6) else { return ops }
                ops.append(.bezier(control1: p(0), control2: p(2), to: p(4))); i += 6
            case ScriptOpCode.arc:
                guard has(6) else { return ops }
                ops.append(.arc(center: p(0), radius: max(0, f(2)), start: v(3), end: v(4), anticlockwise: v(5) != 0)); i += 6
            case ScriptOpCode.ellipse:
                guard has(8) else { return ops }
                ops.append(.ellipse(center: p(0), radiusX: max(0, f(2)), radiusY: max(0, f(3)), rotation: v(4), start: v(5), end: v(6),
                                    anticlockwise: v(7) != 0)); i += 8
            case ScriptOpCode.rect:
                guard has(4) else { return ops }
                ops.append(.rect(r(0))); i += 4
            case ScriptOpCode.closePath: ops.append(.closePath)
            case ScriptOpCode.fill: ops.append(.fillPath)
            case ScriptOpCode.stroke: ops.append(.strokePath)
            case ScriptOpCode.fillRect, ScriptOpCode.strokeRect, ScriptOpCode.clearRect:
                guard has(4) else { return ops }
                let rect = r(0)
                ops.append(code == ScriptOpCode.fillRect ? .fillRect(rect) : code == ScriptOpCode.strokeRect ? .strokeRect(rect) : .clearRect(rect))
                i += 4
            case ScriptOpCode.clip: ops.append(.clip)
            case ScriptOpCode.fillText, ScriptOpCode.strokeText:
                guard has(3) else { return ops }
                let string = text(Int(v(0)))
                ops.append(code == ScriptOpCode.fillText ? .fillText(string, p(1)) : .strokeText(string, p(1))); i += 3
            case ScriptOpCode.image:
                guard has(5) else { return ops }
                ops.append(.image(id: Int(v(0)), rect: r(1))); i += 5
            case ScriptOpCode.imageSub:
                guard has(9) else { return ops }
                ops.append(.imageSub(id: Int(v(0)), source: r(1), dest: r(5))); i += 9
            case ScriptOpCode.linearGradient, ScriptOpCode.radialGradient:
                let isLinear = code == ScriptOpCode.linearGradient
                let head = isLinear ? 5 : 7
                guard has(head + 1) else { return ops }
                let id = Int(v(0))
                let stopCount = min(max(Int(v(head)), 0), 32)
                guard has(head + 1 + stopCount * 2) else { return ops }
                var stops: [ScriptGradientStop] = []
                for s in 0..<stopCount {
                    let offset = v(head + 1 + s * 2)
                    stops.append(ScriptGradientStop(offset: min(max(offset.isFinite ? offset : 0, 0), 1), color: color(Int(v(head + 2 + s * 2)))))
                }
                stops.sort { $0.offset < $1.offset }
                if isLinear {
                    gradients[id] = .linear(start: p(1), end: p(3), stops: stops)
                } else {
                    // 2つの円のグラデーションは、外側の円の中心を中心にした放射状で近似する
                    gradients[id] = .radial(center: p(4), startRadius: max(0, f(3)), endRadius: max(0, f(6)), stops: stops)
                }
                i += head + 1 + stopCount * 2
            default:
                // 知らない命令: 以降は読めないので止める
                return ops
            }
        }
        return ops
    }
}

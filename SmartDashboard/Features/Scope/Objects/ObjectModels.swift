import Foundation
import SwiftUI
import UIKit

/// オブジェクトを組み立てる基本の形
enum ObjectShapeKind: String, Codable, CaseIterable, Identifiable {
    case box
    case cylinder
    case cone
    case sphere
    case pyramid
    case plane

    var id: String { rawValue }

    var label: String {
        switch self {
        case .box: return "箱"
        case .cylinder: return "円柱"
        case .cone: return "円錐"
        case .sphere: return "球"
        case .pyramid: return "角錐"
        case .plane: return "板"
        }
    }

    var symbol: String {
        switch self {
        case .box: return "cube"
        case .cylinder: return "cylinder"
        case .cone: return "cone"
        case .sphere: return "circle"
        case .pyramid: return "pyramid"
        case .plane: return "rectangle"
        }
    }
}

/// 1つの形。大きさは m。位置は、形の底面の中心の、オブジェクトの中での位置(x=右、y=前、z=上)。
/// 回転は形の中心のまわりに、ロール(右が下がる向き)→ ピッチ(前が上がる向き)→ ヨー(上から見て時計回り)の順。
/// 板は、幅×高さの縦の板(正面が前)。奥行きは使わない。
struct ObjectShape: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: ObjectShapeKind
    var width: Double
    var depth: Double
    var height: Double
    var x = 0.0
    var y = 0.0
    var z = 0.0
    var yaw = 0.0
    var pitch = 0.0
    var roll = 0.0
    /// "#RRGGBB"
    var color: String
    var opacity: Double

    static let defaultColor = "#FF0000"
    static let defaultOpacity = 0.4

    static func make(_ kind: ObjectShapeKind, color: String = defaultColor, opacity: Double = defaultOpacity) -> ObjectShape {
        switch kind {
        case .plane: return ObjectShape(kind: kind, width: 4, depth: 0.1, height: 3, color: color, opacity: opacity)
        case .sphere: return ObjectShape(kind: kind, width: 4, depth: 4, height: 4, color: color, opacity: opacity)
        default: return ObjectShape(kind: kind, width: 4, depth: 4, height: 6, color: color, opacity: opacity)
        }
    }
}

/// 形を組み合わせたオブジェクト
struct ScopeObject: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var shapes: [ObjectShape]
    var updatedAt = Date()

    /// 形の数の上限(手で作るときも、文章から作るときの「とても細かい」と同じ)
    static let maxShapes = 300
}

/// 文章から作るときの細かさ。形の数の上限と、出力トークンの上限(思考を含む)を決める
enum ObjectDetail: String, CaseIterable, Identifiable {
    case normal
    case detailed
    case veryDetailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "ふつう"
        case .detailed: return "細かい"
        case .veryDetailed: return "とても細かい"
        }
    }

    static let initial = ObjectDetail.detailed

    /// 形の数の上限
    var maxShapes: Int {
        switch self {
        case .normal: return 30
        case .detailed: return 100
        case .veryDetailed: return 300
        }
    }

    /// 出力トークンの上限(思考を含む)。形1つは省略した書き方で約40〜60トークン。思考と検索の後の文章の分を足す
    var maxTokens: Int {
        switch self {
        case .normal: return 8_000
        case .detailed: return 24_000
        case .veryDetailed: return 56_000
        }
    }
}

/// 地図に置いたオブジェクト
struct ObjectPlacement: Codable, Equatable, Identifiable {
    var id = UUID()
    var objectID: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    /// 正面の方角(度、北=0、時計回り)
    var heading = 0.0
    /// 地面からの高さ(m)
    var heightAboveGround = 0.0
    /// 全体の大きさの倍率
    var scale = 1.0
    /// 地面の標高(m)。nil は未設定
    var groundElevation: Double?
    var elevationState: WaypointElevationState = .unset
    var isHidden = false

    static let scaleRange = 0.1...100.0
}

/// 色の文字列(#RRGGBB)と、表示の色の変換
enum ObjectColor {
    static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func color(_ hex: String) -> Color {
        let c = rgb(hex) ?? (1, 0, 0)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func uiColor(_ hex: String, alpha: Double = 1) -> UIColor {
        let c = rgb(hex) ?? (1, 0, 0)
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    static func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

/// オブジェクトの JSON(書き出し・読み込み・Claude で作る)の形式
/// {"format": 1, "type": "scope-object", "name": "塔", "shapes": [{"kind": "box", "width": 4, "depth": 4, "height": 30,
///  "x": 0, "y": 0, "z": 0, "yaw": 0, "pitch": 0, "roll": 0, "color": "#FF0000", "opacity": 0.4}]}
enum ObjectCodec {
    static let currentFormat = 1
    static let type = "scope-object"
    static let maxBytes = 400_000
    static let sizeRange = 0.01...2000.0
    static let positionRange = -2000.0...2000.0

    enum Result: Equatable {
        case success(ScopeObject)
        case failure([ToolIssue])
    }

    static func parse(_ text: String, maxShapes: Int = ScopeObject.maxShapes) -> Result {
        guard let data = text.data(using: .utf8), data.count <= maxBytes else {
            return .failure([ToolIssue(path: "", message: "大きすぎます(\(maxBytes / 1000)KBまで)")])
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure([ToolIssue(path: "", message: "JSON として読めません")])
        }
        var issues: [ToolIssue] = []
        if let format = root["format"] as? Int, format != currentFormat {
            issues.append(ToolIssue(path: "format", message: "\(currentFormat) にしてください"))
        }
        if let kind = root["type"] as? String, kind != type {
            issues.append(ToolIssue(path: "type", message: "\"\(type)\" にしてください"))
        }
        let name = String(((root["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if name.isEmpty { issues.append(ToolIssue(path: "name", message: "名前が必要です")) }
        guard let rawShapes = root["shapes"] as? [[String: Any]], !rawShapes.isEmpty else {
            issues.append(ToolIssue(path: "shapes", message: "形の配列(1〜\(maxShapes)個)が必要です"))
            return .failure(issues)
        }
        if rawShapes.count > maxShapes {
            issues.append(ToolIssue(path: "shapes", message: "多すぎます(\(maxShapes)個まで。今は\(rawShapes.count)個)"))
        }
        var shapes: [ObjectShape] = []
        for (index, raw) in rawShapes.prefix(maxShapes).enumerated() {
            let path = "shapes[\(index)]"
            guard let kindText = raw["kind"] as? String, let kind = ObjectShapeKind(rawValue: kindText) else {
                issues.append(ToolIssue(path: "\(path).kind", message: ObjectShapeKind.allCases.map(\.rawValue).joined(separator: " / ") + " のどれかにしてください"))
                continue
            }
            func number(_ key: String, default value: Double, range: ClosedRange<Double>) -> Double {
                guard let rawValue = raw[key] else { return value }
                guard let n = rawValue as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                      range.contains(n.doubleValue) else {
                    issues.append(ToolIssue(path: "\(path).\(key)", message: "\(range.lowerBound)〜\(range.upperBound)の数にしてください"))
                    return value
                }
                return n.doubleValue
            }
            var shape = ObjectShape.make(kind)
            shape.width = number("width", default: shape.width, range: sizeRange)
            shape.depth = number("depth", default: shape.depth, range: sizeRange)
            shape.height = number("height", default: shape.height, range: sizeRange)
            shape.x = number("x", default: 0, range: positionRange)
            shape.y = number("y", default: 0, range: positionRange)
            shape.z = number("z", default: 0, range: positionRange)
            shape.yaw = number("yaw", default: 0, range: -360...360)
            shape.pitch = number("pitch", default: 0, range: -360...360)
            shape.roll = number("roll", default: 0, range: -360...360)
            shape.opacity = number("opacity", default: ObjectShape.defaultOpacity, range: 0.05...1)
            if let color = raw["color"] {
                if let text = color as? String, ObjectColor.rgb(text) != nil {
                    shape.color = text.uppercased().hasPrefix("#") ? text.uppercased() : "#" + text.uppercased()
                } else {
                    issues.append(ToolIssue(path: "\(path).color", message: "\"#RRGGBB\" の形にしてください"))
                }
            }
            shapes.append(shape)
        }
        guard issues.isEmpty else { return .failure(issues) }
        return .success(ScopeObject(name: name, shapes: shapes))
    }

    /// 書き出す JSON(読み込みの形式と同じ。ID は入れない)
    static func encode(_ object: ScopeObject) -> String {
        let shapes: [[String: Any]] = object.shapes.map { shape in
            [
                "kind": shape.kind.rawValue,
                "width": round(shape.width), "depth": round(shape.depth), "height": round(shape.height),
                "x": round(shape.x), "y": round(shape.y), "z": round(shape.z),
                "yaw": round(shape.yaw), "pitch": round(shape.pitch), "roll": round(shape.roll),
                "color": shape.color, "opacity": round(shape.opacity),
            ]
        }
        let root: [String: Any] = ["format": currentFormat, "type": type, "name": object.name, "shapes": shapes]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// 書き出す数は小数第3位まで
    private static func round(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}

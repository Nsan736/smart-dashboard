import Foundation

/// 部品の読み取りの誤りを Result で返すため
extension ToolIssue: Error {}

/// 入力の部品の値
enum ScriptControlValue: Equatable {
    case number(Double)
    case bool(Bool)
    case text(String)

    /// JavaScript に渡す値
    var jsObject: Any {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value
        case .text(let value): return value
        }
    }
}

/// 入力の部品(JSON の controls か、スクリプトの ui.slider などで作る)。キャンバスの上か下に並べる。
struct ScriptControlSpec: Equatable, Identifiable {
    enum Kind: String, CaseIterable {
        case slider
        case button
        case toggle
        case text
        case choice
    }

    static let maxControls = 20
    static let maxOptions = 30

    var id: String
    var kind: Kind
    var label: String
    var min = 0.0
    var max = 1.0
    var step = 0.0
    var options: [String] = []
    var value: ScriptControlValue

    /// JSON の辞書から作る。読めなければ理由(path は場所の表示に使う)。
    static func parse(_ raw: [String: Any], path: String) -> Result<ScriptControlSpec, ToolIssue> {
        guard let id = raw["id"] as? String, !id.isEmpty, id.count <= 30,
              id.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            return .failure(ToolIssue(path: "\(path).id", message: "半角の英字か _ で始まる、英数字と _ だけの名前(30文字まで)にしてください"))
        }
        guard let typeText = raw["type"] as? String, let kind = Kind(rawValue: typeText) else {
            return .failure(ToolIssue(path: "\(path).type", message: Kind.allCases.map(\.rawValue).joined(separator: " / ") + " のどれかにしてください"))
        }
        let label = String((raw["label"] as? String ?? id).prefix(40))
        func number(_ key: String) -> Double? {
            guard let value = raw[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue.isFinite ? value.doubleValue : nil
        }
        var spec = ScriptControlSpec(id: id, kind: kind, label: label, value: .number(0))
        switch kind {
        case .slider:
            spec.min = number("min") ?? 0
            spec.max = number("max") ?? 1
            guard spec.min < spec.max else { return .failure(ToolIssue(path: "\(path).max", message: "min より大きくしてください")) }
            spec.step = Swift.max(0, number("step") ?? 0)
            spec.value = .number(Swift.min(Swift.max(number("value") ?? number("default") ?? spec.min, spec.min), spec.max))
        case .button:
            spec.value = .bool(false)
        case .toggle:
            spec.value = .bool((raw["value"] as? Bool) ?? (raw["default"] as? Bool) ?? false)
        case .text:
            spec.value = .text(String(((raw["value"] as? String) ?? (raw["default"] as? String) ?? "").prefix(200)))
        case .choice:
            guard let options = raw["options"] as? [String], !options.isEmpty, options.count <= maxOptions else {
                return .failure(ToolIssue(path: "\(path).options", message: "選択肢の文字列の配列(1〜\(maxOptions)個)にしてください"))
            }
            spec.options = options.map { String($0.prefix(40)) }
            let initial = (raw["value"] as? String) ?? (raw["default"] as? String)
            spec.value = .text(initial.flatMap { spec.options.contains($0) ? $0 : nil } ?? spec.options[0])
        }
        return .success(spec)
    }

    /// スライダーの値を、刻みと範囲に合わせる
    func snapped(_ value: Double) -> Double {
        var v = Swift.min(Swift.max(value, min), max)
        if step > 0 { v = min + ((v - min) / step).rounded() * step }
        return Swift.min(Swift.max(v, min), max)
    }
}

/// スクリプトの ui.* からの変更(JSON の文字列で届く)
enum ScriptUIChange: Equatable {
    case add(ScriptControlSpec)
    case set(id: String, value: ScriptControlValue)
    case remove(id: String)
    case invalid(String)

    static func parse(_ json: String) -> ScriptUIChange {
        guard let data = json.data(using: .utf8), let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = raw["op"] as? String, let id = raw["id"] as? String else { return .invalid("ui: 読めない指定です") }
        switch op {
        case "add":
            var fields = raw
            fields["op"] = nil
            switch ScriptControlSpec.parse(fields, path: "ui.\(raw["type"] as? String ?? "")") {
            case .success(let spec): return .add(spec)
            case .failure(let issue): return .invalid("ui: \(issue.message)")
            }
        case "set":
            if let value = raw["value"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return .set(id: id, value: .bool(value.boolValue)) }
            if let value = raw["value"] as? NSNumber { return .set(id: id, value: .number(value.doubleValue)) }
            if let value = raw["value"] as? String { return .set(id: id, value: .text(String(value.prefix(200)))) }
            return .invalid("ui.set: 値は数・真偽値・文字にしてください")
        case "remove":
            return .remove(id: id)
        default:
            return .invalid("ui: 読めない指定です")
        }
    }

    /// 部品の一覧に反映する(上限を超える追加は無視する)
    static func apply(_ changes: [ScriptUIChange], to controls: [ScriptControlSpec]) -> [ScriptControlSpec] {
        var result = controls
        for change in changes {
            switch change {
            case .add(let spec):
                if let index = result.firstIndex(where: { $0.id == spec.id }) {
                    result[index] = spec
                } else if result.count < ScriptControlSpec.maxControls {
                    result.append(spec)
                }
            case .set(let id, let value):
                guard let index = result.firstIndex(where: { $0.id == id }) else { continue }
                switch (result[index].kind, value) {
                case (.slider, .number(let number)): result[index].value = .number(result[index].snapped(number))
                case (.toggle, .bool), (.text, .text): result[index].value = value
                case (.choice, .text(let text)) where result[index].options.contains(text): result[index].value = value
                default: break
                }
            case .remove(let id):
                result.removeAll { $0.id == id }
            case .invalid:
                break
            }
        }
        return result
    }
}

/// スクリプト型のツールの中身
struct ScriptToolContent: Equatable {
    static let maxScriptLength = 100_000
    static let defaultFPS = 30

    var script: String
    var controls: [ScriptControlSpec]
    var controlsAtTop: Bool
    /// 1秒あたりのコマの数(15〜60)
    var fps: Int
    /// キャンバスの幅÷高さ。nil なら、空いている場所いっぱい。
    var aspect: Double?

    /// JSON の辞書から読む(CustomToolParser から呼ぶ)
    static func parse(_ root: [String: Any], issues: inout [ToolIssue]) -> ScriptToolContent {
        var content = ScriptToolContent(script: "", controls: [], controlsAtTop: false, fps: defaultFPS, aspect: nil)
        if let script = root["script"] as? String, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if script.count > maxScriptLength {
                issues.append(ToolIssue(path: "script", message: "長すぎます(\(maxScriptLength)文字まで)"))
            }
            content.script = script
        } else {
            issues.append(ToolIssue(path: "script", message: "スクリプトの本体(文字列)が必要です"))
        }
        if let raw = root["controls"] {
            if let list = raw as? [[String: Any]], list.count <= ScriptControlSpec.maxControls {
                var ids = Set<String>()
                for (index, item) in list.enumerated() {
                    switch ScriptControlSpec.parse(item, path: "controls[\(index)]") {
                    case .success(let spec):
                        if ids.insert(spec.id).inserted {
                            content.controls.append(spec)
                        } else {
                            issues.append(ToolIssue(path: "controls[\(index)].id", message: "同じ名前の部品があります"))
                        }
                    case .failure(let issue):
                        issues.append(issue)
                    }
                }
            } else {
                issues.append(ToolIssue(path: "controls", message: "部品の配列(\(ScriptControlSpec.maxControls)個まで)にしてください"))
            }
        }
        if let position = root["controlsPosition"] {
            switch position as? String {
            case "top": content.controlsAtTop = true
            case "bottom": content.controlsAtTop = false
            default: issues.append(ToolIssue(path: "controlsPosition", message: "top / bottom のどちらかにしてください"))
            }
        }
        if let raw = root["fps"] {
            if let fps = raw as? NSNumber, CFGetTypeID(fps) != CFBooleanGetTypeID(), (15...60).contains(fps.intValue) {
                content.fps = fps.intValue
            } else {
                issues.append(ToolIssue(path: "fps", message: "15〜60の整数にしてください"))
            }
        }
        if let raw = root["aspect"] {
            if let aspect = raw as? NSNumber, CFGetTypeID(aspect) != CFBooleanGetTypeID(), (0.25...4).contains(aspect.doubleValue) {
                content.aspect = aspect.doubleValue
            } else {
                issues.append(ToolIssue(path: "aspect", message: "0.25〜4の数(幅÷高さ)にしてください"))
            }
        }
        return content
    }
}

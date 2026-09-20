import Foundation

/// JSONで読み込むツール。プログラムは実行せず、決まった型に中身を当てはめるだけ。
/// 通信・位置情報・カメラ・ファイル・アプリのほかのデータには、一切アクセスできない(そのための項目が形式にない)。
struct CustomTool: Equatable, Identifiable {
    enum Kind: String {
        case calc
        case list
        case table
        case checklist

        var label: String {
            switch self {
            case .calc: return "計算型"
            case .list: return "リスト型"
            case .table: return "表型"
            case .checklist: return "チェックリスト型"
            }
        }
    }

    enum InputType: String {
        case number
        case choice
        case text
        case date
    }

    struct Choice: Equatable {
        var label: String
        var value: Double
    }

    struct Input: Equatable, Identifiable {
        var id: String
        var label: String
        var type: InputType
        var unit: String
        var defaultValue: Double?
        var choices: [Choice]
    }

    struct Output: Equatable, Identifiable {
        var id: Int
        var label: String
        var formula: String
        var expression: ToolExpression
        var decimals: Int
        var unit: String
        /// "number"(数)か "days"(日数 → 「◯日」)
        var style: String
    }

    enum ListMode: String {
        case roulette
        case lottery
        case order
    }

    var id: String
    var name: String
    var summary: String
    var symbol: String
    var category: ToolCategory
    var keywords: [String]
    var kind: Kind
    var inputs: [Input] = []
    var outputs: [Output] = []
    var listMode: ListMode = .roulette
    var items: [String] = []
    var columns: [String] = []
    var rows: [[String]] = []
}

/// 形式の誤り。どこが違うかが分かるように、場所(path)を付ける。
struct ToolIssue: Equatable, Identifiable {
    var path: String
    var message: String
    var id: String { path + message }
}

enum CustomToolParser {
    static let currentFormat = 1
    static let maxBytes = 200_000
    static let maxInputs = 20
    static let maxOutputs = 20
    static let maxItems = 500
    static let maxRows = 1000
    static let maxColumns = 12
    static let maxText = 200

    enum Result: Equatable {
        case success(CustomTool)
        case failure([ToolIssue])
    }

    static func parse(_ text: String) -> Result {
        guard text.utf8.count <= maxBytes else { return .failure([ToolIssue(path: "全体", message: "大きすぎます(\(maxBytes / 1000)KBまで)")]) }
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            return .failure([ToolIssue(path: "全体", message: "JSONとして読めません(カンマや引用符の抜けがないか確認してください)")])
        }
        guard let root = object as? [String: Any] else {
            return .failure([ToolIssue(path: "全体", message: "一番外側は { } のオブジェクトにしてください")])
        }
        var issues: [ToolIssue] = []
        func string(_ dictionary: [String: Any], _ key: String, path: String, required: Bool, limit: Int = maxText) -> String {
            guard let value = dictionary[key] else {
                if required { issues.append(ToolIssue(path: path, message: "必要な項目です")) }
                return ""
            }
            guard let text = value as? String else {
                issues.append(ToolIssue(path: path, message: "文字列にしてください"))
                return ""
            }
            if required, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(ToolIssue(path: path, message: "空にはできません")) }
            if text.count > limit { issues.append(ToolIssue(path: path, message: "長すぎます(\(limit)文字まで)")) }
            return text
        }
        func number(_ value: Any?) -> Double? {
            // true / false を数として受け取らない
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.doubleValue
        }

        if let format = number(root["format"]) {
            if Int(format) != currentFormat { issues.append(ToolIssue(path: "format", message: "このアプリが読めるのは format \(currentFormat) です")) }
        } else {
            issues.append(ToolIssue(path: "format", message: "必要な項目です(\(currentFormat) を指定)"))
        }
        let id = string(root, "id", path: "id", required: true, limit: 60)
        if !id.isEmpty, id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) == nil {
            issues.append(ToolIssue(path: "id", message: "半角の英数字と . _ - だけにしてください"))
        }
        let name = string(root, "name", path: "name", required: true, limit: 40)
        let summary = string(root, "description", path: "description", required: false)
        var symbol = string(root, "icon", path: "icon", required: false, limit: 60)
        if !symbol.isEmpty, symbol.range(of: "^[a-z0-9.]+$", options: .regularExpression) == nil {
            issues.append(ToolIssue(path: "icon", message: "SF Symbols の名前(半角の小文字・数字・ピリオド)にしてください"))
        }
        if symbol.isEmpty { symbol = "wrench.and.screwdriver" }
        var category = ToolCategory.other
        if root["category"] != nil {
            let raw = string(root, "category", path: "category", required: false)
            if let value = ToolCategory(rawValue: raw) {
                category = value
            } else {
                issues.append(ToolIssue(path: "category", message: "\(ToolCategory.allCases.map(\.rawValue).joined(separator: " / ")) のどれかにしてください"))
            }
        }
        var keywords: [String] = []
        if let raw = root["keywords"] {
            if let list = raw as? [String], list.count <= 30 {
                keywords = list
            } else {
                issues.append(ToolIssue(path: "keywords", message: "文字列の配列(30個まで)にしてください"))
            }
        }
        let kindText = string(root, "type", path: "type", required: true)
        guard let kind = CustomTool.Kind(rawValue: kindText) else {
            if !kindText.isEmpty { issues.append(ToolIssue(path: "type", message: "calc / list / table / checklist のどれかにしてください")) }
            return .failure(issues)
        }
        var tool = CustomTool(id: id, name: name, summary: summary, symbol: symbol, category: category, keywords: keywords, kind: kind)

        func stringList(_ key: String, limit: Int) -> [String] {
            guard let raw = root[key] else {
                issues.append(ToolIssue(path: key, message: "必要な項目です"))
                return []
            }
            guard let list = raw as? [String] else {
                issues.append(ToolIssue(path: key, message: "文字列の配列にしてください"))
                return []
            }
            if list.isEmpty { issues.append(ToolIssue(path: key, message: "1つ以上入れてください")) }
            if list.count > limit { issues.append(ToolIssue(path: key, message: "多すぎます(\(limit)個まで)")) }
            for (index, item) in list.enumerated() where item.count > maxText {
                issues.append(ToolIssue(path: "\(key)[\(index)]", message: "長すぎます(\(maxText)文字まで)"))
            }
            return Array(list.prefix(limit))
        }

        switch kind {
        case .calc:
            let rawInputs = root["inputs"] as? [[String: Any]] ?? []
            if root["inputs"] == nil || (root["inputs"] as? [[String: Any]]) == nil {
                issues.append(ToolIssue(path: "inputs", message: "入力欄の配列が必要です"))
            }
            if rawInputs.count > maxInputs { issues.append(ToolIssue(path: "inputs", message: "多すぎます(\(maxInputs)個まで)")) }
            var ids = Set<String>()
            for (index, raw) in rawInputs.prefix(maxInputs).enumerated() {
                let path = "inputs[\(index)]"
                let inputID = string(raw, "id", path: "\(path).id", required: true, limit: 30)
                if !inputID.isEmpty {
                    if inputID.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                        issues.append(ToolIssue(path: "\(path).id", message: "半角の英字か _ で始まる、英数字と _ だけの名前にしてください(式の中で使うため)"))
                    } else if ToolExpression.functions[inputID] != nil || inputID == "pi" {
                        issues.append(ToolIssue(path: "\(path).id", message: "関数や定数と同じ名前は使えません"))
                    } else if !ids.insert(inputID).inserted {
                        issues.append(ToolIssue(path: "\(path).id", message: "同じ名前の入力欄があります"))
                    }
                }
                let label = string(raw, "label", path: "\(path).label", required: true, limit: 40)
                let typeText = string(raw, "type", path: "\(path).type", required: true)
                guard let type = CustomTool.InputType(rawValue: typeText) else {
                    if !typeText.isEmpty { issues.append(ToolIssue(path: "\(path).type", message: "number / choice / text / date のどれかにしてください")) }
                    continue
                }
                var choices: [CustomTool.Choice] = []
                if type == .choice {
                    let rawChoices = raw["options"] as? [[String: Any]] ?? []
                    if rawChoices.isEmpty || rawChoices.count > 30 { issues.append(ToolIssue(path: "\(path).options", message: "選択肢を1〜30個入れてください")) }
                    for (choiceIndex, rawChoice) in rawChoices.prefix(30).enumerated() {
                        let choiceLabel = string(rawChoice, "label", path: "\(path).options[\(choiceIndex)].label", required: true, limit: 40)
                        if let value = number(rawChoice["value"]) {
                            choices.append(CustomTool.Choice(label: choiceLabel, value: value))
                        } else {
                            issues.append(ToolIssue(path: "\(path).options[\(choiceIndex)].value", message: "数にしてください"))
                        }
                    }
                }
                var defaultValue: Double?
                if let rawDefault = raw["default"] {
                    defaultValue = number(rawDefault)
                    if defaultValue == nil { issues.append(ToolIssue(path: "\(path).default", message: "数にしてください")) }
                }
                tool.inputs.append(CustomTool.Input(id: inputID, label: label, type: type,
                                                    unit: string(raw, "unit", path: "\(path).unit", required: false, limit: 20),
                                                    defaultValue: defaultValue, choices: choices))
            }
            let rawOutputs = root["outputs"] as? [[String: Any]] ?? []
            if rawOutputs.isEmpty { issues.append(ToolIssue(path: "outputs", message: "出力を1つ以上入れてください")) }
            if rawOutputs.count > maxOutputs { issues.append(ToolIssue(path: "outputs", message: "多すぎます(\(maxOutputs)個まで)")) }
            for (index, raw) in rawOutputs.prefix(maxOutputs).enumerated() {
                let path = "outputs[\(index)]"
                let label = string(raw, "label", path: "\(path).label", required: true, limit: 40)
                let formula = string(raw, "formula", path: "\(path).formula", required: true, limit: ToolExpression.maxLength)
                var decimals = 0
                if let rawDecimals = raw["decimals"] {
                    if let value = number(rawDecimals), (0...8).contains(Int(value)) {
                        decimals = Int(value)
                    } else {
                        issues.append(ToolIssue(path: "\(path).decimals", message: "0〜8の整数にしてください"))
                    }
                }
                let style = raw["style"] == nil ? "number" : string(raw, "style", path: "\(path).style", required: false)
                if !["number", "days"].contains(style) { issues.append(ToolIssue(path: "\(path).style", message: "number / days のどちらかにしてください")) }
                guard !formula.isEmpty else { continue }
                do {
                    let expression = try ToolExpression(formula)
                    try expression.check(knownVariables: ids)
                    tool.outputs.append(CustomTool.Output(id: index, label: label, formula: formula, expression: expression, decimals: decimals,
                                                          unit: string(raw, "unit", path: "\(path).unit", required: false, limit: 20), style: style))
                } catch let error as ToolExpressionError {
                    issues.append(ToolIssue(path: "\(path).formula", message: error.message))
                } catch {
                    issues.append(ToolIssue(path: "\(path).formula", message: "式を読めません"))
                }
            }
        case .list:
            let modeText = root["mode"] == nil ? "roulette" : string(root, "mode", path: "mode", required: false)
            if let mode = CustomTool.ListMode(rawValue: modeText) {
                tool.listMode = mode
            } else {
                issues.append(ToolIssue(path: "mode", message: "roulette / lottery / order のどれかにしてください"))
            }
            tool.items = stringList("items", limit: maxItems)
        case .checklist:
            tool.items = stringList("items", limit: maxItems)
        case .table:
            tool.columns = stringList("columns", limit: maxColumns)
            guard let rawRows = root["rows"] as? [[Any]] else {
                issues.append(ToolIssue(path: "rows", message: "行の配列(行ごとに、列の数だけの配列)が必要です"))
                break
            }
            if rawRows.count > maxRows { issues.append(ToolIssue(path: "rows", message: "多すぎます(\(maxRows)行まで)")) }
            for (index, rawRow) in rawRows.prefix(maxRows).enumerated() {
                if rawRow.count != tool.columns.count {
                    issues.append(ToolIssue(path: "rows[\(index)]", message: "列の数(\(tool.columns.count))と合いません"))
                    continue
                }
                // 数も文字として表示する
                tool.rows.append(rawRow.map { cell in
                    if let text = cell as? String { return String(text.prefix(maxText)) }
                    if let value = number(cell) { return value == value.rounded() ? String(Int(value)) : String(value) }
                    return ""
                })
            }
        }
        return issues.isEmpty ? .success(tool) : .failure(issues)
    }

    /// 計算型の出力の書式
    static func format(_ value: Double, output: CustomTool.Output) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.minimumFractionDigits = output.decimals
        formatter.maximumFractionDigits = output.decimals
        formatter.roundingMode = .halfUp
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        if output.style == "days" { return text + "日" + output.unit }
        return output.unit.isEmpty ? text : text + " " + output.unit
    }

    /// 計算型の計算。入力欄の値(日付は1970年1月1日からの日数、テキストは文字数)から、出力ごとの結果を返す。
    static func evaluate(_ tool: CustomTool, values: [String: Double]) -> [(output: CustomTool.Output, text: String, isError: Bool)] {
        tool.outputs.map { output in
            do {
                return (output, format(try output.expression.evaluate(values), output: output), false)
            } catch let error as ToolExpressionError {
                return (output, error.message, true)
            } catch {
                return (output, "計算できません", true)
            }
        }
    }
}

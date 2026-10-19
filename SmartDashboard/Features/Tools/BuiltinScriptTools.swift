import Foundation

/// 組み込みのツールの JavaScript 版(v0.9.32)。アプリに同梱した Resources/builtin_script_tools.json から読む。
/// 元の JavaScript 版はアプリの更新で新しくなる(端末には保存しない)。中身を変えたいときは「複製して編集」で、読み込んだツール(custom)として保存する。
/// Swift の版(BuiltinTool)は、しばらく残す。
struct BuiltinScriptTool: Equatable {
    /// ファイルの名前(examples/tools/src/builtin/<file>.js)
    var file: String
    /// 置き換える前の Swift の版(一覧で、その隣に並べる)
    var replaces: BuiltinTool?
    var json: String
    var tool: CustomTool
}

enum BuiltinScriptTools {
    /// 同梱した版の ID の頭(読み込んだツールには使えない)
    static let idPrefix = "builtin-js."
    /// 一覧の名前に付ける
    static let nameSuffix = "(JavaScript 版)"

    /// 形式: {"tools": [{"file": "timer", "replaces": "timer", "json": "<ツールの JSON の文字列>"}, ...]}。読めないものは除く。
    static func load(_ data: Data) -> [BuiltinScriptTool] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["tools"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let file = item["file"] as? String, let json = item["json"] as? String,
                  case .success(let tool) = CustomToolParser.parse(json), tool.kind == .script, tool.id.hasPrefix(idPrefix) else { return nil }
            return BuiltinScriptTool(file: file, replaces: (item["replaces"] as? String).flatMap(BuiltinTool.init(rawValue:)), json: json, tool: tool)
        }
    }

    static let all: [BuiltinScriptTool] = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "builtin_script_tools", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return load(data)
    }()

    static func tool(id: String) -> BuiltinScriptTool? { all.first { $0.tool.id == id } }

    static func isReserved(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// 編集できる複製の JSON。ID と名前だけを変え、ほかはそのまま(スクリプトも)。読めなければ nil。
    /// newID は "my-<file>-<短い乱数>" など、読み込んだツールの ID として使えるもの。
    static func copyJSON(_ json: String, newID: String, name: String) -> String? {
        guard let data = json.data(using: .utf8), var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        root["id"] = newID
        root["name"] = String(name.prefix(40))
        if let summary = root["description"] as? String {
            root["description"] = summary.replacingOccurrences(of: "(JavaScript 版。「その他」→「複製して編集」で中身を変えられます)", with: "(組み込みの JavaScript 版の複製)")
        }
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    /// 複製の ID と名前(すでにある ID と重ならないように)
    static func copyIdentity(of tool: BuiltinScriptTool, existing: Set<String>, random: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) -> (id: String, name: String) {
        var id = ""
        repeat {
            id = "my-" + tool.file + "-" + String(random() % 46_656, radix: 36)
        } while existing.contains(id)
        return (id, tool.tool.name + "(コピー)")
    }

    private final class BundleToken {}
}

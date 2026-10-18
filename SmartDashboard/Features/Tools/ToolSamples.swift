import SwiftUI

/// アプリに同梱した小ツールのサンプル(examples/tools と同じもの。Resources/tool_samples.json)
struct ToolSample: Identifiable, Equatable {
    var file: String
    var json: String
    var tool: CustomTool
    var id: String { file }
}

enum ToolSampleCatalog {
    /// 形式: {"samples": [{"file": "fuel-economy", "json": "<ツールの JSON の文字列>"}, ...]}。読めないサンプルは除く。
    static func load(_ data: Data) -> [ToolSample] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["samples"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let file = item["file"] as? String, let json = item["json"] as? String,
                  case .success(let tool) = CustomToolParser.parse(json) else { return nil }
            return ToolSample(file: file, json: json, tool: tool)
        }
    }

    static let bundled: [ToolSample] = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "tool_samples", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return load(data)
    }()

    private final class BundleToken {}
}

/// サンプルの一覧。ワンタップで追加し、追加済みのものは「追加済み」と出す。
struct ToolSamplesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let samples = ToolSampleCatalog.bundled
        NavigationStack {
            List {
                let groups: [(String, [ToolSample])] = [
                    ("スクリプト型(JavaScript)", samples.filter { $0.tool.kind == .script }),
                    ("計算・リスト・表・チェックリスト", samples.filter { $0.tool.kind != .script }),
                ]
                ForEach(groups, id: \.0) { group in
                    if !group.1.isEmpty {
                        Section(group.0) {
                            ForEach(group.1) { sample in row(sample) }
                        }
                    }
                }
                if samples.isEmpty {
                    Text("サンプルを読み込めませんでした").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("サンプル")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }

    private func row(_ sample: ToolSample) -> some View {
        let added = env.tools.customSources[sample.tool.id] != nil
        return HStack(spacing: 12) {
            Image(systemName: sample.tool.symbol).font(.title3).frame(width: 30).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(sample.tool.name).font(.headline)
                Text(sample.tool.kind.label + (sample.tool.summary.isEmpty ? "" : "・" + sample.tool.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let permissions = sample.tool.script?.permissions, !permissions.isEmpty {
                    // 追加したあと、初めて開いたときに許可を求める
                    Text("使うデータ: " + permissions.map(\.title).joined(separator: "、"))
                        .font(.caption2)
                        .foregroundStyle(permissions.contains(where: \.isSensitive) ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if added {
                Text("追加済み").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            } else {
                Button("追加") { env.tools.save(sample.tool, json: sample.json) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

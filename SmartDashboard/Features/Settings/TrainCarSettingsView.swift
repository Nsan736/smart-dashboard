import SwiftUI

/// スコープの電車の、路線ごとの両数。初期値は同梱の表(TrainCarCatalog)の値で、路線ごとに上書きできる。
struct TrainCarSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    private struct Row: Identifiable {
        var id: String
        var name: String
        var entry: TrainCarCatalog.Entry?
        var kind: RailwayKind
    }

    /// 表にある路線と、登録した路線(表にないもの)。表の路線は事業者の順、登録した路線は名前の順。
    private var rows: [Row] {
        let catalog = TrainCarCatalog.bundled
        let names = env.trains.railwayNames
        var rows = catalog.railways.keys.sorted().map { id in
            let entry = catalog.railways[id]
            let name = entry.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? names[id] ?? ODPTID.tail(id)
            return Row(id: id, name: name, entry: entry, kind: RailwayKind.classify(railwayID: id, name: names[id] ?? name))
        }
        let extra = env.trains.registeredRailwayIDs.filter { catalog.railways[$0] == nil }
        rows += extra.map { id in
            let name = names[id] ?? ODPTID.tail(id)
            return Row(id: id, name: name, entry: nil, kind: RailwayKind.classify(railwayID: id, name: name))
        }.sorted { $0.name < $1.name }
        return rows
    }

    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section {
                ForEach(rows) { row in
                    rowView(row, settings: settings)
                }
            } footer: {
                Text("表の値は、各社の公式サイト(車両の紹介、事業の概要、ニュースリリース)で調べたものです(確認日 \(TrainCarCatalog.bundled.fetched))。同じ路線に両数の違う列車があり、データから見分けられない路線は、多いほうの両数を使い、列車の詳細に「両数は目安」と出します。上書きした値は、すべての列車に使います。")
            }
            Section {
                ForEach(RailwayKind.allCases) { kind in
                    Stepper(value: Binding(get: { settings.scopeCars(for: kind) }, set: { settings.scopeCarCounts[kind.rawValue] = $0 }), in: 1...16) {
                        Text("\(kind.label): \(settings.scopeCars(for: kind))両")
                    }
                }
            } header: {
                Text("表にない路線の目安")
            } footer: {
                Text("表にも上書きにもない路線は、路線の種類(路線名から判断)ごとのこの両数で描き、「両数は目安」と出します。")
            }
        }
        .navigationTitle("路線ごとの両数")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func rowView(_ row: Row, settings: AppSettings) -> some View {
        let base = row.entry?.cars ?? settings.scopeCars(for: row.kind)
        let override = settings.scopeCarOverrides[row.id]
        VStack(alignment: .leading, spacing: 4) {
            Stepper(value: Binding(get: { override ?? base }, set: { value in
                // 表の値と同じにしたら、上書きをやめる
                settings.scopeCarOverrides[row.id] = value == base ? nil : value
            }), in: 1...16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).fixedSize(horizontal: false, vertical: true)
                    Text("\(override ?? base)両" + (override != nil ? "(上書き。表の値は\(base)両)" : statusText(row.entry)))
                        .font(.caption)
                        .foregroundStyle(override != nil ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let entry = row.entry {
                ForEach(Array(entry.rules.enumerated()), id: \.offset) { _, rule in
                    Text("\(rule.cars)両: \(rule.note)").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entry.sources, id: \.url) { source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            Text("出典: \(source.url)").font(.caption2).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            if override != nil {
                Button("表の値に戻す") { settings.scopeCarOverrides[row.id] = nil }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(_ entry: TrainCarCatalog.Entry?) -> String {
        guard let entry else { return "(表にない路線。種類ごとの目安)" }
        if entry.mixed { return "(両数の違う列車が混在。目安)" }
        if !entry.verified { return "(公式の資料で未確認。目安)" }
        return entry.rules.isEmpty ? "(表の値)" : "(表の値。一部の列車は規則で見分ける)"
    }
}

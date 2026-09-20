import SwiftUI
import UniformTypeIdentifiers

/// 読み込んだツールを動かす画面。型ごとに決まった部品に中身を当てはめるだけで、プログラムは実行しない。
struct CustomToolRunner: View {
    let tool: CustomTool

    var body: some View {
        switch tool.kind {
        case .calc: CalcToolView(tool: tool)
        case .list:
            Form { ListPickerView(mode: tool.listMode, items: tool.items) }
        case .table: TableToolView(tool: tool)
        case .checklist: ChecklistToolView(tool: tool)
        }
    }
}

private struct CalcToolView: View {
    let tool: CustomTool
    @State private var numbers: [String: String] = [:]
    @State private var choices: [String: Int] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var texts: [String: String] = [:]

    var body: some View {
        Form {
            Section("入力") {
                ForEach(tool.inputs) { input in
                    switch input.type {
                    case .number:
                        HStack {
                            Text(input.label)
                            TextField("0", text: binding(input.id, fallback: input.defaultValue.map { Self.plain($0) } ?? ""))
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                            if !input.unit.isEmpty { Text(input.unit).foregroundStyle(.secondary) }
                        }
                    case .choice:
                        Picker(input.label, selection: Binding(get: { choices[input.id] ?? 0 }, set: { choices[input.id] = $0 })) {
                            ForEach(input.choices.indices, id: \.self) { Text(input.choices[$0].label).tag($0) }
                        }
                    case .date:
                        DatePicker(input.label, selection: Binding(get: { dates[input.id] ?? Date() }, set: { dates[input.id] = $0 }), displayedComponents: .date)
                    case .text:
                        TextField(input.label, text: binding(input.id, fallback: ""))
                    }
                }
            }
            Section("結果") {
                ForEach(CustomToolParser.evaluate(tool, values: values), id: \.output.id) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.output.label).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(row.text)
                            .font(row.isError ? .footnote : .title3.weight(.bold))
                            .foregroundStyle(row.isError ? Color.orange : Color.primary)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .keyboardDismissable()
    }

    private func binding(_ key: String, fallback: String) -> Binding<String> {
        // @State の辞書を、入力欄ごとの文字列として読み書きする
        let isNumber = tool.inputs.first { $0.id == key }?.type == .number
        return Binding(
            get: { (isNumber ? numbers[key] : texts[key]) ?? fallback },
            set: { if isNumber { numbers[key] = $0 } else { texts[key] = $0 } })
    }

    private static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// 式に渡す値。日付は1970年1月1日からの日数、テキストは文字数。数として読めない入力は 0。
    private var values: [String: Double] {
        var result: [String: Double] = [:]
        for input in tool.inputs {
            switch input.type {
            case .number: result[input.id] = Double(numbers[input.id] ?? "") ?? input.defaultValue ?? 0
            case .choice: result[input.id] = input.choices.indices.contains(choices[input.id] ?? 0) ? input.choices[choices[input.id] ?? 0].value : 0
            case .date: result[input.id] = Double(DateCalc.days(from: Date(timeIntervalSince1970: 0), to: dates[input.id] ?? Date()))
            case .text: result[input.id] = Double((texts[input.id] ?? "").count)
            }
        }
        return result
    }
}

private struct TableToolView: View {
    let tool: CustomTool
    @State private var query = ""

    var body: some View {
        let rows = CustomToolTable.filter(tool.rows, query: query)
        List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(zip(tool.columns, row).enumerated()), id: \.offset) { index, pair in
                            HStack(alignment: .firstTextBaseline) {
                                Text(pair.0).font(.caption).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
                                Text(pair.1).font(index == 0 ? .headline : .body).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } header: {
                Text("\(rows.count)件")
            }
        }
        .searchable(text: $query, prompt: "表の中を検索")
    }
}

enum CustomToolTable {
    /// どれかの列に、検索語(表記ゆれを吸収)を含む行
    static func filter(_ rows: [[String]], query: String) -> [[String]] {
        let word = ToolSearch.normalize(query)
        guard !word.isEmpty else { return rows }
        return rows.filter { row in row.contains { ToolSearch.normalize($0).contains(word) } }
    }
}

private struct ChecklistToolView: View {
    let tool: CustomTool
    @State private var checked: Set<String> = []

    private var key: String { "tools.checklist." + tool.id }

    var body: some View {
        List {
            Section {
                ForEach(Array(tool.items.enumerated()), id: \.offset) { _, item in
                    Button {
                        if checked.contains(item) { checked.remove(item) } else { checked.insert(item) }
                        UserDefaults.standard.set(Array(checked), forKey: key)
                    } label: {
                        HStack {
                            Image(systemName: checked.contains(item) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(checked.contains(item) ? Color.green : Color.secondary)
                            Text(item).foregroundStyle(Color.primary).strikethrough(checked.contains(item))
                        }
                    }
                }
            } header: {
                Text("\(checked.intersection(tool.items).count) / \(tool.items.count)")
            }
            Section {
                Button("すべてのチェックを外す", role: .destructive) {
                    checked = []
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
        .onAppear { checked = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    }
}

// MARK: - 読み込み

/// JSONの読み込み(ファイル、貼り付け、httpsのURL)と、保存する前の確認
struct ToolImportView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var json: String
    /// 編集のときは、もとのツールのID(IDを変えたら、別のツールとして保存する)
    private let editingID: String?
    @State private var urlText = "https://"
    @State private var isImporting = false
    @State private var isFetching = false
    @State private var message: String?

    init(json: String = "", editingID: String? = nil) {
        _json = State(initialValue: json)
        self.editingID = editingID
    }

    var body: some View {
        let result = json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : CustomToolParser.parse(json)
        NavigationStack {
            Form {
                Section {
                    Button("「ファイル」から読み込む") { isImporting = true }
                    Button("クリップボードから貼り付ける") {
                        if let text = UIPasteboard.general.string { json = text } else { message = "クリップボードに文字がありません" }
                    }
                    HStack {
                        TextField("https://…", text: $urlText)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(isFetching ? "取得中…" : "取得") { Task { await fetch() } }
                            .buttonStyle(.borderless)
                            .disabled(isFetching)
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                } header: {
                    Text("読み込む")
                } footer: {
                    Text("URLからの取得は、このボタンを押したときだけ行います(https のみ、200KBまで)。読み込んだツールは、決まった型に中身を当てはめるだけで、通信・位置情報・カメラ・ファイル・このアプリのほかのデータには一切アクセスできません。")
                }
                if let result {
                    switch result {
                    case .success(let tool): ToolPreviewSections(tool: tool)
                    case .failure(let issues):
                        Section("形式の誤り(\(issues.count)件)") {
                            ForEach(issues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(issue.message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Section("JSON(直接編集できます)") {
                    TextEditor(text: $json)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .keyboardDismissable()
            .navigationTitle(editingID == nil ? "ツールを読み込む" : "ツールを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard case .success(let tool)? = result else { return }
                        if let editingID, editingID != tool.id { env.tools.delete(customID: editingID) }
                        env.tools.save(tool, json: json)
                        dismiss()
                    }
                    .disabled(!Self.isValid(result))
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .plainText]) { outcome in
                guard case .success(let url) = outcome else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), data.count <= CustomToolParser.maxBytes, let text = String(data: data, encoding: .utf8) {
                    json = text
                    message = nil
                } else {
                    message = "読み込めませんでした(UTF-8のテキストで、200KBまで)"
                }
            }
        }
    }

    private static func isValid(_ result: CustomToolParser.Result?) -> Bool {
        if case .success? = result { return true }
        return false
    }

    private func fetch() async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme == "https", url.host != nil else {
            message = "https:// で始まるURLを入れてください"
            return
        }
        isFetching = true
        defer { isFetching = false }
        do {
            let data = try await env.http.get(url)
            guard data.count <= CustomToolParser.maxBytes, let text = String(data: data, encoding: .utf8) else {
                message = "大きすぎるか、文字として読めません(200KBまで)"
                return
            }
            json = text
            message = nil
        } catch {
            message = "取得できませんでした: \(error.localizedDescription)"
        }
    }
}

/// 保存する前に、ツールの内容(名前・型・入力欄・式)を確認する
struct ToolPreviewSections: View {
    let tool: CustomTool

    var body: some View {
        Section("内容の確認") {
            Label(tool.name, systemImage: tool.symbol).font(.headline)
            LabeledContent("型", value: tool.kind.label)
            LabeledContent("カテゴリ", value: tool.category.label)
            LabeledContent("ID", value: tool.id)
            if !tool.summary.isEmpty { Text(tool.summary).font(.footnote).foregroundStyle(.secondary) }
        }
        switch tool.kind {
        case .calc:
            Section("入力欄(\(tool.inputs.count))") {
                ForEach(tool.inputs) { input in
                    LabeledContent("\(input.label)(\(input.id))", value: input.type.rawValue + (input.choices.isEmpty ? "" : " \(input.choices.count)択"))
                }
            }
            Section("式(\(tool.outputs.count))") {
                ForEach(tool.outputs) { output in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.label)
                        Text(output.formula).font(.footnote.monospaced()).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .list:
            Section("項目(\(tool.items.count))・使い方: \(tool.listMode.rawValue)") {
                Text(tool.items.prefix(8).joined(separator: "、") + (tool.items.count > 8 ? " ほか" : "")).font(.footnote)
            }
        case .checklist:
            Section("項目(\(tool.items.count))") {
                Text(tool.items.prefix(8).joined(separator: "、") + (tool.items.count > 8 ? " ほか" : "")).font(.footnote)
            }
        case .table:
            Section("表") {
                LabeledContent("列", value: tool.columns.joined(separator: " / "))
                LabeledContent("行数", value: "\(tool.rows.count)")
            }
        }
    }
}

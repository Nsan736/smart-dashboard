import SwiftUI

/// ツールの画面を出し分ける。内蔵ツールを増やすときは、ここに1行足す。
struct ToolScreen: View {
    @Environment(AppEnvironment.self) private var env
    let tool: ToolDescriptor
    @State private var isEditing = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        content
            .navigationTitle(tool.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { env.tools.markUsed(tool.id) }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        env.tools.toggleFavorite(tool.id)
                    } label: {
                        Label("お気に入り", systemImage: env.tools.isFavorite(tool.id) ? "star.fill" : "star")
                    }
                    if case .custom(let custom) = tool.source, let json = env.tools.customSources[custom.id] {
                        Menu {
                            ShareLink(item: json, subject: Text(custom.name)) { Label("書き出す(共有)", systemImage: "square.and.arrow.up") }
                            Button {
                                isEditing = true
                            } label: {
                                Label("JSONを編集", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        } label: {
                            Label("その他", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $isEditing) {
                if case .custom(let custom) = tool.source {
                    ToolImportView(json: env.tools.customSources[custom.id] ?? "", editingID: custom.id)
                }
            }
            .confirmationDialog("このツールを削除しますか", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if case .custom(let custom) = tool.source { env.tools.delete(customID: custom.id) }
                    dismiss()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch tool.source {
        case .custom(let custom):
            // 編集して保存したら、新しい内容で表示する
            CustomToolRunner(tool: env.tools.customTools.first { $0.id == custom.id } ?? custom)
        case .builtin(let builtin):
            switch builtin {
            case .timer: TimerTabView(initialMode: 0)
            case .stopwatch: TimerTabView(initialMode: 1)
            case .dateCalc: DateCalcToolView()
            case .wareki: WarekiToolView()
            case .splitBill: SplitBillToolView()
            case .percent: PercentToolView()
            case .unitConvert: UnitConvertToolView()
            case .baseConvert: BaseConvertToolView()
            case .roulette: RouletteToolView()
            case .dice: DiceToolView()
            case .coin: CoinToolView()
            case .teams: TeamsToolView()
            case .order: OrderToolView()
            case .tournament: TournamentToolView()
            case .counter: CounterToolView()
            case .textCount: TextCountToolView()
            case .kanaConvert: KanaConvertToolView()
            case .password: PasswordToolView()
            case .flashlight: FlashlightToolView()
            }
        }
    }
}

/// 小ツールの一覧。検索、お気に入り、最近使った、カテゴリ別。
struct ToolsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var isImporting = false

    var body: some View {
        let library = env.tools
        let all = library.all
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    let favorites = library.favorites.compactMap { id in all.first { $0.id == id } }
                    if !favorites.isEmpty {
                        Section("お気に入り") { ForEach(favorites) { row($0) } }
                    }
                    let recents = library.recents.compactMap { id in all.first { $0.id == id } }.filter { !library.isFavorite($0.id) }
                    if !recents.isEmpty {
                        Section("最近使った") { ForEach(recents.prefix(5)) { row($0) } }
                    }
                    ForEach(ToolCategory.allCases) { category in
                        let tools = all.filter { $0.category == category }
                        if !tools.isEmpty {
                            Section(category.label) { ForEach(tools) { row($0) } }
                        }
                    }
                } else {
                    let found = ToolSearch.filter(all, query: query)
                    Section("\(found.count)件") {
                        ForEach(found) { row($0) }
                        if found.isEmpty { Text("見つかりませんでした").foregroundStyle(.secondary) }
                    }
                }
                Section {
                    Button {
                        isImporting = true
                    } label: {
                        Label("JSONのツールを読み込む", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("長押しで、お気に入りに追加・削除できます。お気に入りは、ホームの「小ツール」カードにも出せます。JSONの形式は、リポジトリの docs/tools-format.md にあります。")
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "名前・説明・キーワードで探す")
            .navigationTitle("小ツール")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isImporting) { ToolImportView() }
        }
    }

    private func row(_ tool: ToolDescriptor) -> some View {
        NavigationLink {
            ToolScreen(tool: tool)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: tool.symbol).font(.title3).frame(width: 30).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(tool.name).font(.headline)
                        if env.tools.isFavorite(tool.id) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                        if tool.isCustom { Text("JSON").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .contextMenu {
            Button {
                env.tools.toggleFavorite(tool.id)
            } label: {
                Label(env.tools.isFavorite(tool.id) ? "お気に入りから外す" : "お気に入りに追加",
                      systemImage: env.tools.isFavorite(tool.id) ? "star.slash" : "star")
            }
        }
    }
}

/// ホームのカード。お気に入りのツールを小さなボタンで並べる。お気に入りがなければ、何も出さない。
struct ToolsHomeCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let library = env.tools
        let all = library.all
        let favorites = library.favorites.compactMap { id in all.first { $0.id == id } }
        if !favorites.isEmpty {
            HomeCard(title: "小ツール", symbol: "wrench.and.screwdriver") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(favorites.prefix(8)) { tool in
                        NavigationLink {
                            ToolScreen(tool: tool)
                        } label: {
                            Label(tool.name, systemImage: tool.symbol)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

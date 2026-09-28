import SwiftUI
import UIKit

/// 路線の色の縦の帯
struct RailwayColorBar: View {
    let colorHex: String?
    var height: CGFloat = 28

    var body: some View {
        Capsule()
            .fill(UIColor(hex: colorHex).map { Color(uiColor: $0) } ?? Color.gray.opacity(0.4))
            .frame(width: 5, height: height)
    }
}

/// 駅ナンバリングの小さな印
struct StationCodeBadge: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.caption.monospaced().weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.6), lineWidth: 1))
    }
}

/// 同じ名前の駅をまとめた1行。名前の下に、路線ごとの駅(色・路線名・事業者名・駅ナンバリング)を並べる。
struct StationGroupRow: View {
    let group: StationSearchGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.name).font(.headline)
            ForEach(group.stations) { station in
                SearchStationLine(station: station)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SearchStationLine: View {
    let station: SearchStation

    var body: some View {
        HStack(spacing: 8) {
            RailwayColorBar(colorHex: station.colorHex)
            VStack(alignment: .leading, spacing: 1) {
                Text(station.railwayName).font(.subheadline)
                Text(station.operatorName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let code = station.code, !code.isEmpty {
                StationCodeBadge(code: code)
            }
        }
    }
}

struct SearchRailwayRow: View {
    let railway: SearchRailway

    var body: some View {
        HStack(spacing: 8) {
            RailwayColorBar(colorHex: railway.colorHex)
            VStack(alignment: .leading, spacing: 1) {
                Text(railway.name)
                Text(railway.operatorName).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 駅の一覧の状態(読み込み中、まだ取得していない事業者、「駅の一覧を取得」のボタン)
struct StationCatalogStatusSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.trains
        if store.isLoadingStationCatalog || !store.stationCatalogPending.isEmpty || store.stationCatalogError != nil || store.stationSearch == nil {
            Section {
                if store.isLoadingStationCatalog {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("駅の一覧を読み込んでいます")
                    }
                } else if !store.stationCatalogPending.isEmpty || store.stationSearch == nil {
                    Text(store.stationCatalogPending.isEmpty
                         ? "駅の一覧がまだありません。"
                         : "\(store.stationCatalogPending.joined(separator: "、"))の駅の一覧がまだありません。Wi-Fi接続中は自動で取得します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await store.ensureStationCatalog(manual: true) }
                    } label: {
                        Label("駅の一覧を取得", systemImage: "arrow.down.circle")
                    }
                }
                if let error = store.stationCatalogError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 駅と路線の検索の結果(List の中に置く)。入力が空のときは、最近検索した駅を出す。
/// 照合は索引(StationSearchIndex)だけで行い、通信しない。
struct StationSearchSections: View {
    enum Mode {
        /// 路線の登録: 駅から路線と方面を選んで登録する、路線から登録する
        case register
        /// 1つの駅(同じ名前の駅のまとまり)を選ぶ(行きたい駅、地図で表示する駅)
        case pick((StationSearchGroup) -> Void)
    }

    @Environment(AppEnvironment.self) private var env
    let query: String
    let mode: Mode

    private var isRegister: Bool {
        if case .register = mode { return true }
        return false
    }

    var body: some View {
        let store = env.trains
        let registered = store.registeredRailwayIDs
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        StationCatalogStatusSection()
        if let index = store.stationSearch {
            if text.isEmpty {
                let recent = store.recentStationSearches.compactMap { index.group(named: $0, registered: registered) }
                if !recent.isEmpty {
                    Section("最近検索した駅") {
                        ForEach(recent) { row($0) }
                    }
                }
            } else {
                let result = index.search(text, registered: registered)
                let railways = isRegister ? result.railways : []
                if !result.groups.isEmpty {
                    Section {
                        ForEach(result.groups) { row($0) }
                    } header: {
                        Text("駅")
                    } footer: {
                        Text("駅名・英語名・駅ナンバリング(例: M08)・IDの一部で探せます。")
                    }
                }
                if !railways.isEmpty {
                    Section("路線") {
                        ForEach(railways) { railway in
                            NavigationLink {
                                RailwayLoaderView(operatorID: railway.operatorID, railwayID: railway.id) { op, loaded in
                                    StationPickerView(op: op, railway: loaded)
                                }
                            } label: {
                                SearchRailwayRow(railway: railway)
                            }
                        }
                    }
                }
                if result.groups.isEmpty, railways.isEmpty {
                    Section {
                        Text("「\(text)」に一致する駅\(isRegister ? "・路線" : "")はありません").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ group: StationSearchGroup) -> some View {
        switch mode {
        case .register:
            NavigationLink {
                StationGroupRegistrationView(group: group)
            } label: {
                StationGroupRow(group: group)
            }
        case .pick(let action):
            Button {
                env.trains.addRecentStationSearch(group.name)
                action(group)
            } label: {
                StationGroupRow(group: group).foregroundStyle(Color.primary)
            }
        }
    }
}

/// 路線を読み込んでから中身を出す(検索の結果から登録の画面へ進むとき)
struct RailwayLoaderView<Content: View>: View {
    @Environment(AppEnvironment.self) private var env
    let operatorID: String
    let railwayID: String
    @ViewBuilder let content: (TrainOperator, ODPTRailway) -> Content
    @State private var railway: ODPTRailway?
    @State private var error: String?

    var body: some View {
        let op = env.trains.operatorInfo(operatorID)
        Group {
            if let railway {
                content(op, railway)
            } else if let error {
                ContentUnavailableView("路線を読み込めませんでした", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .task {
            guard railway == nil else { return }
            do {
                railway = try await env.trains.railways(of: op).first { $0.sameAs == railwayID }
                if railway == nil { error = "路線の一覧に見つかりませんでした" }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// 検索で選んだ駅の、路線ごとの登録(路線と方面を選ぶ)
struct StationGroupRegistrationView: View {
    @Environment(AppEnvironment.self) private var env
    let group: StationSearchGroup

    var body: some View {
        List {
            Section {
                ForEach(group.stations) { station in
                    let caps = env.trains.capabilities(ofRailway: station.railwayID)
                    NavigationLink {
                        RailwayLoaderView(operatorID: station.operatorID, railwayID: station.railwayID) { op, railway in
                            if caps.trainTimetable || caps.stationTimetable {
                                DirectionPickerView(op: op, railway: railway, stationID: station.id, stationName: station.name)
                            } else {
                                // 時刻表のない路線は、駅の選択を飛ばして「運行情報のみ登録」の画面へ
                                StationPickerView(op: op, railway: railway)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            SearchStationLine(station: station)
                            if !(caps.trainTimetable || caps.stationTimetable) {
                                Text("この路線は時刻表が提供されていません(運行情報のみ登録できます)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if env.trains.stations.contains(where: { $0.stationID == station.id }) {
                                Text("登録済みの方面があります").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("路線を選んで、方面を登録")
            } footer: {
                Text("路線の運行情報だけを登録するときや、ほかの駅を選ぶときは、事業者の一覧から路線を選んでください。")
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { env.trains.addRecentStationSearch(group.name) }
    }
}

/// 駅を名前で探して選ぶシート(行きたい駅、地図で表示する駅)
struct StationPickSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSelect: (StationSearchGroup) -> Void
    /// 駅の一覧を読み込んだあとにすること
    var afterLoad: (() async -> Void)? = nil
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                StationSearchSections(query: query, mode: .pick { group in
                    onSelect(group)
                    dismiss()
                })
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "駅名・駅ナンバリング・ローマ字")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                await env.trains.ensureStationCatalog(manual: false)
                await afterLoad?()
            }
        }
    }
}

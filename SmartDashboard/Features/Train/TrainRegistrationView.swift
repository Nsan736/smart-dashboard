import SwiftUI
import UIKit

/// 使えるデータの小さなラベル(運行情報/時刻表/遅れ/地図)。使えるものだけを出す。
struct CapabilityLabels: View {
    let capabilities: ODPTCapabilities

    var body: some View {
        let labels = capabilities.labels
        if !labels.isEmpty {
            // 文字を大きくしたときは2段にする
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { chips(labels) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) { chips(Array(labels.prefix(2))) }
                    HStack(spacing: 4) { chips(Array(labels.dropFirst(2))) }
                }
            }
        }
    }

    private func chips(_ labels: [String]) -> some View {
        ForEach(labels, id: \.self) { label in
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(Color.accentColor)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
    }
}

/// 事業者の検出の状態と「再検出」のボタン(登録の画面と設定で使う)
struct OperatorDiscoveryStatusRows: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let discovery = env.discovery
        if discovery.isDetecting {
            HStack(spacing: 8) {
                ProgressView()
                Text("使える事業者を調べています")
            }
        } else if let result = discovery.result {
            LabeledContent("検出した事業者", value: "\(result.operators.count)事業者・\(result.railwayCount)路線")
            Text("\(Formatters.dateTime.string(from: result.detectedAt))(\(Formatters.age(of: result.detectedAt)))に\(result.endpoint == .authenticated ? "トークンで検出" : "トークンなしで検出(公開データだけ)")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("まだ検出していません").foregroundStyle(.secondary)
        }
        if let failure = discovery.failure {
            Label(failure.message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let url = failure.url {
                // 失敗したリクエスト(トークンは含まない)
                Text(url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let note = discovery.note {
            Label(note, systemImage: "wifi")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        Button {
            Task { await env.discovery.detect(manual: true) }
        } label: {
            Label("再検出", systemImage: "arrow.clockwise")
        }
        .disabled(discovery.isDetecting)
    }
}

/// 登録の入口: 駅・路線を検索して選ぶか、事業者を選ぶ(自動で検出した事業者)
struct OperatorPickerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showsExcluded = false
    @State private var query = ""

    var body: some View {
        let discovery = env.discovery
        List {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 駅名から、その駅の路線と方面を選んで登録する
                StationSearchSections(query: query, mode: .register)
            } else {
                StationSearchSections(query: "", mode: .register)
                Section {
                    OperatorDiscoveryStatusRows()
                } header: {
                    Text("自動検出")
                } footer: {
                    Text("トークンで使える事業者・路線と、使えるデータを調べて30日間保存します(1回あたり約70KB、10回前後の通信)。期限が切れたときは、Wi-Fi接続時に調べ直します。")
                }
                Section {
                    ForEach(discovery.operators) { op in
                        NavigationLink {
                            RailwayPickerView(op: op)
                        } label: {
                            OperatorRow(op: op)
                        }
                    }
                } header: {
                    Text("事業者")
                } footer: {
                    Text("ラベルは使えるデータです(運行情報/時刻表/遅れ/地図)。路線の一覧は、検出のときに取得したものを使います。上の検索欄で、駅名から直接登録することもできます。")
                }
                if let excluded = discovery.result?.excluded, !excluded.isEmpty {
                    Section {
                        DisclosureGroup("使わない事業者(\(excluded.count))", isExpanded: $showsExcluded) {
                            ForEach(excluded) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text(item.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "駅名・路線名・駅ナンバリング")
        .navigationTitle("事業者")
        .task {
            await env.discovery.detectIfNeeded()
            await env.trains.ensureStationCatalog(manual: false)
        }
    }
}

struct OperatorRow: View {
    @Environment(AppEnvironment.self) private var env
    let op: TrainOperator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(op.name)
            if op.isFallback {
                let needsToken = op.endpoint.requiresToken && !env.hasODPTToken
                Text(needsToken ? "トークンが必要(設定で入力)" : "予備の定義(使えるデータは未確認)")
                    .font(.caption)
                    .foregroundStyle(needsToken ? Color.orange : Color.secondary)
            } else {
                CapabilityLabels(capabilities: op.capabilities)
                Text("\(op.railways.count)路線")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 路線を選ぶ(路線の色と、使えるデータのラベル。名前で検索できる)
struct RailwayPickerView: View {
    @Environment(AppEnvironment.self) private var env
    let op: TrainOperator
    @State private var railways: [ODPTRailway] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        let list = filtered
        List {
            if isLoading { ProgressView() }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(list) { railway in
                NavigationLink {
                    StationPickerView(op: op, railway: railway)
                } label: {
                    RailwayRow(railway: railway, capabilities: env.discovery.capabilities(ofRailway: railway.sameAs))
                }
            }
            if !railways.isEmpty, list.isEmpty {
                Text("見つかりません").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "路線名")
        .navigationTitle(op.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard railways.isEmpty else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                railways = try await env.trains.railways(of: op)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// 路線名(ひらがな・カタカナ・全角半角の違いを吸収)と、路線IDの末尾(ローマ字)で絞る
    private var filtered: [ODPTRailway] {
        let key = ToolSearch.normalize(query)
        guard !key.isEmpty else { return railways }
        return railways.filter { ToolSearch.normalize($0.name).contains(key) || ODPTID.tail($0.sameAs).lowercased().contains(key) }
    }
}

struct RailwayRow: View {
    let railway: ODPTRailway
    /// 検出していない路線は nil(ラベルを出さない)
    let capabilities: ODPTCapabilities?

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(UIColor(hex: railway.color).map { Color(uiColor: $0) } ?? Color.gray.opacity(0.4))
                .frame(width: 6, height: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(railway.name)
                if let capabilities {
                    CapabilityLabels(capabilities: capabilities)
                }
            }
        }
    }
}

struct StationPickerView: View {
    @Environment(AppEnvironment.self) private var env
    let op: TrainOperator
    let railway: ODPTRailway
    @State private var stations: [(id: String, name: String)] = []
    @State private var error: String?

    private var isLineRegistered: Bool {
        env.trains.lines.contains { $0.railwayID == railway.sameAs }
    }

    var body: some View {
        let caps = env.trains.capabilities(ofRailway: railway.sameAs)
        let hasTimetable = caps.trainTimetable || caps.stationTimetable
        List {
            Section {
                if !caps.trainInformation {
                    Label("この路線は運行情報が提供されていません", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else if isLineRegistered {
                    Label("この路線は登録済みです", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    Button {
                        env.trains.addLine(RegisteredLine(operatorID: op.id, railwayID: railway.sameAs, railwayName: railway.name))
                        Task { await env.trains.refreshInfoIfStale() }
                    } label: {
                        Label(hasTimetable ? "この路線の運行情報を登録" : "運行情報のみ登録", systemImage: "plus.circle")
                    }
                }
            } header: {
                Text("運行情報")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if caps.delay == false {
                        Text("この路線は列車ごとの遅れが提供されていないため、列車は時刻表どおりの位置に出し、運行情報で路線全体の状況を表示します。")
                    }
                    if !caps.stationLocation {
                        Text("この路線は駅の位置が提供されていないため、地図と路線図に表示できません。")
                    }
                }
            }
            if hasTimetable {
                Section {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    ForEach(stations, id: \.id) { station in
                        NavigationLink(station.name) {
                            DirectionPickerView(op: op, railway: railway, stationID: station.id, stationName: station.name)
                        }
                    }
                } header: {
                    Text("時刻表を使う駅")
                } footer: {
                    if !caps.trainTimetable {
                        Text("この路線は列車ごとの時刻表が提供されていないため、駅の時刻表(次の電車)だけ使えます。列車の位置・駅に重ねる電車・経路の検索は使えません。")
                    }
                }
            } else {
                Section {
                    Label("この路線は時刻表が提供されていません", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text(caps.trainInformation ? "駅の選択はありません。「運行情報のみ登録」で登録できます。" : "この路線で使える機能はありません。")
                }
            }
        }
        .navigationTitle(railway.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard stations.isEmpty, hasTimetable else { return }
            do {
                stations = try await env.trains.stationList(of: railway, op: op)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct DirectionPickerView: View {
    @Environment(AppEnvironment.self) private var env
    let op: TrainOperator
    let railway: ODPTRailway
    let stationID: String
    let stationName: String
    @State private var names: [String: String] = [:]
    @State private var registered: Set<String> = []

    var body: some View {
        let caps = env.trains.capabilities(ofRailway: railway.sameAs)
        List {
            Section {
                if railway.directions.isEmpty {
                    Text("この路線には方面の情報がありません").foregroundStyle(.secondary)
                }
                ForEach(railway.directions, id: \.self) { direction in
                    let name = names[direction] ?? ODPTID.tail(direction)
                    Button {
                        env.trains.addStation(RegisteredStation(
                            operatorID: op.id, railwayID: railway.sameAs, railwayName: railway.name,
                            stationID: stationID, stationName: stationName,
                            directionID: direction, directionName: name))
                        registered.insert(direction)
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if registered.contains(direction) || isRegistered(direction) {
                                Image(systemName: "checkmark").foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(registered.contains(direction) || isRegistered(direction))
                }
            } header: {
                Text("方面")
            } footer: {
                Text(caps.stationTimetable
                     ? "登録後、移動の画面で駅の時刻表を一度だけダウンロードしてください。以後は通信なしで次の電車を表示します。"
                     : "この路線は駅の時刻表が提供されていないため、次の電車は列車ごとの時刻表(Wi-Fi接続中に自動で保存)から出します。地図の駅をタップしてください。")
            }
        }
        .navigationTitle(stationName)
        .task { names = await env.trains.directionNames(endpoint: op.endpoint) }
    }

    private func isRegistered(_ direction: String) -> Bool {
        env.trains.stations.contains { $0.stationID == stationID && $0.directionID == direction }
    }
}

/// 検出の結果(事業者・路線ごとの使えるデータ)。設定から開く。
struct OperatorDiscoveryView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let discovery = env.discovery
        List {
            Section {
                OperatorDiscoveryStatusRows()
            } footer: {
                Text("トークンを保存したときと「再検出」で調べ、30日間保存します。期限が切れたときは、Wi-Fi接続時に調べ直します。公共交通オープンデータチャレンジ限定のライセンスの事業者は使いません。")
            }
            if let result = discovery.result {
                Section("使える事業者") {
                    ForEach(result.operators) { op in
                        DisclosureGroup {
                            ForEach(op.railways) { railway in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(railway.name).font(.subheadline)
                                    CapabilityLabels(capabilities: railway.capabilities)
                                    if !railway.capabilities.isUsable {
                                        Text("使えるデータがありません").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(op.name)
                                CapabilityLabels(capabilities: op.capabilities)
                            }
                        }
                    }
                }
                if !result.excluded.isEmpty {
                    Section("使わない事業者") {
                        ForEach(result.excluded) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                Text(item.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("通信の回数", value: "\(result.requestCount)回")
                    LabeledContent("かかった時間", value: String(format: "%.1f秒", result.duration))
                } footer: {
                    Text("受信量は、設定の「受信データ量」の「電車」に含まれます。")
                }
            }
        }
        .navigationTitle("使える事業者")
        .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI

/// 登録の入口: 事業者を選ぶ
struct OperatorPickerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(OperatorCatalog.all) { op in
                    NavigationLink {
                        RailwayPickerView(op: op)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(op.name)
                            if op.endpoint.requiresToken {
                                Text(env.hasODPTToken ? "トークン設定済み" : "トークンが必要(設定で入力)")
                                    .font(.caption)
                                    .foregroundStyle(env.hasODPTToken ? Color.secondary : Color.orange)
                            }
                        }
                    }
                }
            } footer: {
                Text("一覧は取得後30日間キャッシュします。")
            }
        }
        .navigationTitle("事業者")
    }
}

struct RailwayPickerView: View {
    @Environment(AppEnvironment.self) private var env
    let op: TrainOperator
    @State private var railways: [ODPTRailway] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if isLoading { ProgressView() }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(railways) { railway in
                NavigationLink(railway.name) {
                    StationPickerView(op: op, railway: railway)
                }
            }
        }
        .navigationTitle("路線")
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
        List {
            if op.providesTrainInformation {
                Section("運行情報") {
                    if isLineRegistered {
                        Label("この路線は登録済みです", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Button {
                            env.trains.addLine(RegisteredLine(operatorID: op.id, railwayID: railway.sameAs, railwayName: railway.name))
                            Task { await env.trains.refreshInfoIfStale() }
                        } label: {
                            Label("この路線の運行情報を登録", systemImage: "plus.circle")
                        }
                    }
                }
            }
            if op.providesStationTimetable {
                Section("時刻表を使う駅") {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    ForEach(stations, id: \.id) { station in
                        NavigationLink(station.name) {
                            DirectionPickerView(op: op, railway: railway, stationID: station.id, stationName: station.name)
                        }
                    }
                }
            }
        }
        .navigationTitle(railway.name)
        .task {
            guard stations.isEmpty, op.providesStationTimetable else { return }
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
    @Environment(\.dismiss) private var dismiss
    let op: TrainOperator
    let railway: ODPTRailway
    let stationID: String
    let stationName: String
    @State private var names: [String: String] = [:]
    @State private var registered: Set<String> = []

    var body: some View {
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
                Text("登録後、電車の画面で時刻表を一度だけダウンロードしてください。以後は通信なしで次の電車を表示します。")
            }
        }
        .navigationTitle(stationName)
        .task { names = await env.trains.directionNames(endpoint: op.endpoint) }
    }

    private func isRegistered(_ direction: String) -> Bool {
        env.trains.stations.contains { $0.stationID == stationID && $0.directionID == direction }
    }
}

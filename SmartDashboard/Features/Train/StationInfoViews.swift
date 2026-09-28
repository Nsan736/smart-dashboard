import SwiftUI

/// 下部の段で、選んだもの(駅・列車)へ自動でスクロールするときの目印
enum MovementScroll {
    static let selection = "movement.selection"
    /// 地図の行(「地図へ」のボタンで戻る先)
    static let map = "movement.map"
}

/// 駅の名前・路線・位置(路線の形と、駅の一覧から引く)
@MainActor
enum StationContext {
    struct Info {
        var name: String
        var railwayID: String?
        var railwayName: String?
        var point: GeoPoint?
        /// 乗り換えできる路線の名前
        var transfers: [String]
    }

    static func info(env: AppEnvironment, stationID: String) -> Info {
        let directory = env.trains.directory
        var name = directory?.station(stationID)?.name
        var railwayID = directory?.station(stationID)?.railwayID
        var point = directory?.station(stationID)?.point
        for (id, shape) in env.trains.shapes {
            guard let stop = shape.stops.first(where: { $0.stationID == stationID }) else { continue }
            name = name ?? stop.name
            railwayID = railwayID ?? id
            point = point ?? GeoPoint(stop.latitude, stop.longitude)
            break
        }
        let names = env.trains.railwayNames
        var transfers: [String] = []
        if let directory {
            for target in directory.transferTargets(from: stationID) {
                guard let railway = directory.station(target)?.railwayID, railway != railwayID else { continue }
                let label = names[railway] ?? directory.railwayName(of: railway)
                let stationName = directory.name(of: target)
                let text = stationName == name ? label : "\(label)(\(stationName))"
                if !transfers.contains(text) { transfers.append(text) }
            }
        }
        return Info(name: name ?? ODPTID.tail(stationID), railwayID: railwayID,
                    railwayName: railwayID.map { names[$0] ?? directory?.railwayName(of: $0) ?? ODPTID.tail($0) },
                    point: point, transfers: transfers)
    }
}

/// 「間に合う」「急げば間に合う」「間に合わない」の印
struct CatchBadge: View {
    let status: CatchStatus
    var isLong = false

    var body: some View {
        Text(isLong ? status.label : status.shortLabel)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(status == .missed ? Color.secondary : Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.color(status), in: Capsule())
    }

    static func color(_ status: CatchStatus) -> Color {
        switch status {
        case .comfortable: return .green
        case .hurry: return .orange
        case .missed: return Color(.tertiarySystemFill)
        }
    }
}

// MARK: - 駅の情報

/// 駅をタップしたときの下部の段: 駅名・路線、方面ごとの時刻表と「間に合う」、行きたい駅までの経路
struct StationInfoSections: View {
    @Environment(AppEnvironment.self) private var env
    let stationID: String
    let directionNames: [String: String]
    let onClose: () -> Void

    var body: some View {
        let info = StationContext.info(env: env, stationID: stationID)
        let user = env.movement.currentPoint
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(info.railwayName ?? "路線不明")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !info.transfers.isEmpty {
                        Text("乗り換え: " + info.transfers.joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
            }
            .id(MovementScroll.selection)
            if let point = info.point, let user {
                let distance = GeoMath.distance(user, point)
                let walk = env.settings.walkSettings
                Text("ここから約\(MovementFormat.distance(distance))・歩いて約\(Self.minutes(CatchEstimator.walkSeconds(distance: distance, settings: walk, hurry: false)))分(急げば約\(Self.minutes(CatchEstimator.walkSeconds(distance: distance, settings: walk, hurry: true)))分)")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("現在地が分からないため、間に合うかは表示しません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("駅")
        } footer: {
            Text("歩く時間は、直線距離×\(String(format: "%.1f", env.settings.walkRouteFactor))を時速\(String(format: "%.1f", env.settings.walkSpeedKmh))kmで歩き、駅の中の移動\(MovementFormat.scale(env.settings.stationAccessMinutes))分を足した目安です(設定で変えられます)。")
        }

        if let railwayID = info.railwayID, env.live.schedules[railwayID] != nil {
            Section {
                StationTimetableView(railwayID: railwayID, stationID: stationID, stationPoint: info.point, directionNames: directionNames)
            } header: {
                Text("時刻表(方面ごと)")
            } footer: {
                Text("→の時刻は、リアルタイムの遅れを反映した予定です。番線は、提供されている駅(終点・折り返しの駅など)だけに出ます。")
            }
        } else if let railwayID = info.railwayID, !env.trains.capabilities(ofRailway: railwayID).trainTimetable {
            Section {
                Text("この路線は列車ごとの時刻表が提供されていないため、方面ごとの時刻表と経路の検索は使えません。駅の時刻表を登録すると、次の電車を出せます(設定の「電車の路線・駅」)。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("時刻表")
            }
        } else {
            Section {
                Text("この路線の列車ごとの時刻表がまだありません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("時刻表を取得") {
                    Task { await env.live.ensureSchedules(manual: true) }
                }
            } header: {
                Text("時刻表")
            }
        }

        if info.railwayID.map({ env.trains.capabilities(ofRailway: $0).trainTimetable }) ?? true {
            JourneySearchSections(stationID: stationID)
        }
    }

    static func minutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }
}

/// 方面ごとの時刻表。今の時刻の付近から。1秒ごとに「間に合う」を更新する。
struct StationTimetableView: View {
    @Environment(AppEnvironment.self) private var env
    let railwayID: String
    let stationID: String
    let stationPoint: GeoPoint?
    let directionNames: [String: String]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = env.movement.currentTime(real: context.date)
            let base = env.movement.journeys.departures(railwayID: railwayID, stationID: stationID, now: now)
            let departures = StationDepartures.applyingDelays(base, delays: env.live.activeDelays(for: railwayID, now: now), now: now)
            let order = env.live.schedules[railwayID].map { TrainPositionCalculator.directions(in: $0) } ?? []
            let boards = StationDepartures.boards(departures, now: now, directionOrder: order)
            let distance = Self.distance(env.movement.currentPoint, stationPoint)
            VStack(alignment: .leading, spacing: 14) {
                if boards.isEmpty {
                    Text("この駅を出る電車はありません")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(boards) { board in
                    StationDirectionView(board: board, name: directionNames[board.direction] ?? ODPTID.tail(board.direction),
                                         now: now, distance: distance, walk: env.settings.walkSettings)
                }
            }
            .padding(.vertical, 4)
        }
    }

    static func distance(_ user: GeoPoint?, _ station: GeoPoint?) -> Double? {
        guard let user, let station else { return nil }
        return GeoMath.distance(user, station)
    }
}

struct StationDirectionView: View {
    let board: StationDirectionBoard
    let name: String
    let now: Date
    let distance: Double?
    let walk: WalkSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name + Self.destinationsText(board))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let distance {
                if let next = CatchEstimator.nextComfortable(board.departures, now: now, distance: distance, settings: walk) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("次に間に合う電車まで").font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            countdown(next)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text("次に間に合う電車まで").font(.caption).foregroundStyle(.secondary)
                            countdown(next)
                        }
                    }
                    Text("\(MovementFormat.time(next.effective))発 \(next.label)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !board.departures.isEmpty {
                    Text("表示している電車には、普通に歩くと間に合いません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(board.departures) { departure in
                StationDepartureRow(departure: departure, now: now, distance: distance, walk: walk)
            }
            if board.departures.isEmpty {
                Text("この先の電車はありません(終電のあと)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let first = board.first, let last = board.last {
                Text("始発 \(MovementFormat.time(first))・終電 \(MovementFormat.time(last))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func countdown(_ next: StationDeparture) -> some View {
        Text(NextTrainRow.countdown(to: next.effective, now: now))
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// 「(押上・京成高砂方面)」のように、この先の電車の行先を最大2つ
    static func destinationsText(_ board: StationDirectionBoard) -> String {
        var names: [String] = []
        for departure in board.departures where !departure.destination.isEmpty && !names.contains(departure.destination) {
            names.append(departure.destination)
            if names.count == 2 { break }
        }
        return names.isEmpty ? "" : "(" + names.joined(separator: "・") + "方面)"
    }
}

struct StationDepartureRow: View {
    let departure: StationDeparture
    let now: Date
    let distance: Double?
    let walk: WalkSettings

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(MovementFormat.time(departure.scheduled))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                if let expected = departure.expected {
                    Text("→" + MovementFormat.time(expected))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                }
            }
            .frame(minWidth: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(departure.label)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                let notes = [departure.platform.map { "\($0)番線" }, departure.isOrigin ? "当駅始発" : nil].compactMap { $0 }
                if !notes.isEmpty {
                    Text(notes.joined(separator: "・"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let distance {
                CatchBadge(status: CatchEstimator.status(departure: departure.effective, now: now, distance: distance, settings: walk))
            }
        }
    }
}

// MARK: - 行きたい駅までの経路

struct JourneySearchSections: View {
    @Environment(AppEnvironment.self) private var env
    let stationID: String
    @State private var showsSearch = false

    var body: some View {
        let journeys = env.movement.journeys
        Section {
            Button {
                showsSearch = true
            } label: {
                HStack {
                    Label("行きたい駅", systemImage: "flag.checkered")
                    Spacer(minLength: 4)
                    Text(journeys.destination?.name ?? "選ぶ")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Picker("出発", selection: Binding(get: { journeys.originMode }, set: { journeys.originMode = $0 })) {
                ForEach(JourneyStore.OriginMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if journeys.destination != nil {
                Button(journeys.isSearching ? "探しています…" : "経路を探す") { search() }
                    .disabled(journeys.isSearching)
            }
            if let message = journeys.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !journeys.missingRailways.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("経路の検索に足りない路線: " + journeys.missingRailways.map(\.name).joined(separator: "、"),
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("列車ごとの時刻表を保存すると、その路線も使えます(1路線あたり約70〜220KBの通信。Wi-Fiのときは自動で取得します)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(journeys.isDownloading ? "取得中…" : "時刻表を取得") {
                        let movement = env.movement
                        Task {
                            await movement.journeys.downloadMissing(stationID: stationID, now: movement.currentTime(), userPoint: movement.currentPoint)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(journeys.isDownloading)
                }
            }
        } header: {
            Text("行きたい駅までの経路")
        } footer: {
            Text("保存した時刻表だけを使い、通信せずに探します。使えるのは、時刻表を保存している事業者(今は都営)の路線だけです。乗り換えは\(Int(env.settings.transferMinutes))分で計算します(離れた駅どうしは、歩く時間を足します)。")
        }
        .sheet(isPresented: $showsSearch) {
            StationSearchSheet { group in
                journeys.setDestination(group)
                search()
            }
        }

        if !journeys.options.isEmpty {
            Section {
                ForEach(journeys.options) { option in
                    JourneyOptionView(option: option, walkDistance: journeys.walkDistance)
                }
            } header: {
                Text("\(journeys.searchedOrigin?.name ?? "")→\(journeys.destination?.name ?? "")(早く着く順)")
            } footer: {
                Text("「間に合う」は、最初に乗る電車に、今から歩いて間に合うかの目安です(出発の駅が3km以内のとき)。")
            }
        }
    }

    private func search() {
        let movement = env.movement
        Task { await movement.journeys.search(from: stationID, now: movement.currentTime(), userPoint: movement.currentPoint) }
    }
}

struct JourneyOptionView: View {
    @Environment(AppEnvironment.self) private var env
    let option: JourneyOption
    let walkDistance: Double?

    var body: some View {
        let journey = option.journey
        let isSelected = env.movement.journeys.selected?.id == journey.id
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(option.kind.label)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.15), in: Capsule())
                Spacer(minLength: 4)
                if isSelected {
                    Label("選択中", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.indigo)
                }
            }
            Text("\(MovementFormat.time(journey.departure))発 → \(MovementFormat.time(journey.arrival))着")
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(Int((journey.duration / 60).rounded()))分・乗り換え\(journey.transfers)回")
                .font(.subheadline)
            if let walkDistance {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = env.movement.currentTime(real: context.date)
                    HStack(spacing: 6) {
                        CatchBadge(status: CatchEstimator.status(departure: journey.departure, now: now, distance: walkDistance,
                                                                 settings: env.settings.walkSettings), isLong: true)
                        Text("最初の電車まで " + NextTrainRow.countdown(to: journey.departure, now: now))
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }
            ForEach(Array(journey.legs.enumerated()), id: \.offset) { index, leg in
                JourneyLegView(leg: leg)
                if index < journey.waits.count {
                    let wait = journey.waits[index]
                    Label(Self.waitText(wait), systemImage: "arrow.triangle.swap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { buttons(journey, isSelected: isSelected) }
                VStack(alignment: .leading) { buttons(journey, isSelected: isSelected) }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func buttons(_ journey: Journey, isSelected: Bool) -> some View {
        Button(isSelected ? "選ぶのをやめる" : "この経路を選ぶ") {
            env.movement.journeys.select(isSelected ? nil : journey)
        }
        .buttonStyle(.bordered)
        if env.settings.movementDebugEnabled {
            Button("この経路で仮想の移動") {
                env.movement.journeys.select(journey)
                _ = env.movement.startJourneyRide(journey)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    static func waitText(_ wait: JourneyWait) -> String {
        let minutes = max(0, Int((wait.seconds / 60).rounded()))
        if wait.stationName == wait.nextStationName {
            return "\(wait.stationName)で乗り換え・待ち\(minutes)分"
        }
        return "\(wait.stationName)で降り、\(wait.nextStationName)へ歩いて乗り換え・待ち\(minutes)分"
    }
}

struct JourneyLegView: View {
    let leg: JourneyLeg

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(leg.railwayName)・\(leg.trainLabel)" + (leg.board.platform.map { "・\($0)番線" } ?? ""))
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(leg.board.name) \(MovementFormat.time(leg.board.departure))発 → \(leg.alight.name) \(MovementFormat.time(leg.alight.arrival))着(\(leg.stops.count - 1)駅)")
                .font(.caption)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 行きたい駅を、駅名で探して選ぶ
struct StationSearchSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSelect: (StationGroup) -> Void
    @State private var query = ""
    @State private var groups: [StationGroup] = []

    var body: some View {
        NavigationStack {
            List {
                let directory = env.trains.directory
                if !env.trains.directoryPendingOperators.isEmpty {
                    Text("\(env.trains.directoryPendingOperators.joined(separator: "、"))の駅は、まだ一覧にありません(通信できるときに開き直すと取得します)。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if directory == nil {
                    if env.trains.isLoadingDirectory {
                        ProgressView("駅の一覧を読み込んでいます")
                    } else {
                        Text(env.trains.directoryError ?? "駅の一覧がまだありません。通信できるときに開き直してください。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(directory?.search(query, in: groups) ?? []) { group in
                    Button {
                        onSelect(group)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).foregroundStyle(Color.primary)
                            Text(group.railwayIDs.map { env.trains.railwayNames[$0] ?? directory?.railwayName(of: $0) ?? ODPTID.tail($0) }
                                .joined(separator: "、"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "駅名(ひらがな・ローマ字でも)")
            .navigationTitle("行きたい駅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                await env.trains.ensureDirectory(manual: true)
                groups = env.trains.directory?.groups() ?? []
            }
        }
    }
}

// MARK: - 選んだ経路

/// 選んだ経路の進み具合(予定どおりか)と、降りる駅の知らせ
struct JourneyStatusSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let journeys = env.movement.journeys
        if let journey = journeys.selected {
            Section {
                if let notice = journeys.alightNotice {
                    HStack(alignment: .top) {
                        Label(notice, systemImage: "bell.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button {
                            journeys.dismissNotice()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("知らせを閉じる")
                    }
                    .listRowBackground(Color.orange)
                }
                Text(Self.statusText(journeys.tracking, journey: journey))
                    .font(.headline)
                    .foregroundStyle(Self.statusColor(journeys.tracking))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(MovementFormat.time(journey.departure))発 → \(MovementFormat.time(journey.arrival))着・乗り換え\(journey.transfers)回")
                    .font(.subheadline)
                    .monospacedDigit()
                ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                    JourneyLegView(leg: leg)
                }
                Button("経路を消す", role: .destructive) { journeys.select(nil) }
            } header: {
                Text("選んだ経路")
            } footer: {
                Text("乗車中の判定で経路の列車に乗っていると分かれば「予定どおり」と出し、降りる駅の1駅前でバイブと画面で知らせます(移動タブを表示している間だけ)。")
            }
        }
    }

    static func statusText(_ status: JourneyTracking.Status, journey: Journey) -> String {
        switch status {
        case .onPlan(let leg):
            guard journey.legs.indices.contains(leg) else { return "予定どおり" }
            return "予定どおり(\(journey.legs[leg].trainLabel)に乗車中)"
        case .onLine(let leg):
            guard journey.legs.indices.contains(leg) else { return "経路の路線に乗車中" }
            return "\(journey.legs[leg].railwayName)に乗車中(予定の列車とは違うか、列車を特定できていません)"
        case .offRoute:
            return "経路にない路線に乗っています"
        case .notRiding:
            guard let first = journey.legs.first else { return "乗車前" }
            return "乗車前(\(first.board.name) \(MovementFormat.time(first.board.departure))発の\(first.trainLabel))"
        }
    }

    static func statusColor(_ status: JourneyTracking.Status) -> Color {
        switch status {
        case .onPlan: return .green
        case .onLine: return .orange
        case .offRoute: return .red
        case .notRiding: return .primary
        }
    }
}

// MARK: - 設定

/// 徒歩と乗り換えの時間の設定
struct MovementWalkSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Stepper(value: $settings.walkRouteFactor, in: 1.0...2.0, step: 0.1) {
                    LabeledContent("道のりの係数", value: String(format: "%.1f", settings.walkRouteFactor))
                }
                Stepper(value: $settings.walkSpeedKmh, in: 2.0...8.0, step: 0.2) {
                    LabeledContent("歩く速さ", value: String(format: "時速%.1fkm", settings.walkSpeedKmh))
                }
                Stepper(value: $settings.stationAccessMinutes, in: 0...10, step: 0.5) {
                    LabeledContent("駅の中の移動", value: "\(MovementFormat.scale(settings.stationAccessMinutes))分")
                }
            } header: {
                Text("駅まで歩く時間")
            } footer: {
                Text("直線距離に係数をかけた道のりを、歩く速さで割り、改札からホームまでの時間を足します。「急げば間に合う」は、速さを1.5倍にした場合です。")
            }
            Section {
                Stepper(value: $settings.transferMinutes, in: 1...15, step: 1) {
                    LabeledContent("乗り換えの時間", value: "\(Int(settings.transferMinutes))分")
                }
            } header: {
                Text("経路の検索")
            } footer: {
                Text("列車を降りてから、次の列車に乗るまでの時間です。150mより離れた駅どうし(蔵前、三田など)は、その分の歩く時間を足します。")
            }
            Section {
                Button("初期値に戻す") {
                    settings.walkRouteFactor = 1.3
                    settings.walkSpeedKmh = 4.8
                    settings.stationAccessMinutes = 2
                    settings.transferMinutes = 5
                }
            }
        }
        .navigationTitle("徒歩と乗り換え")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 経路の検索のために時刻表を保存した路線
struct RouteRailwaysView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pendingDelete: RouteRailway?

    var body: some View {
        List {
            Section {
                if env.trains.routeRailways.isEmpty {
                    Text("ありません").foregroundStyle(.secondary)
                }
                ForEach(env.trains.routeRailways) { railway in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(railway.name)
                            Text(env.live.schedules[railway.railwayID] == nil ? "時刻表は未保存" : "時刻表を保存済み")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = railway
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } footer: {
                Text("経路の検索で足りなかった路線です。運行情報や駅の登録とは別に、地図の線と列車ごとの時刻表だけを保存します(遅れは取得しません)。")
            }
        }
        .navigationTitle("経路の検索用の路線")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("この路線の時刻表を消しますか", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { railway in
            Button("消す", role: .destructive) {
                env.trains.removeRouteRailways(ids: [railway.railwayID])
                Task { await env.live.ensureSchedules(manual: false) }
            }
        }
    }
}

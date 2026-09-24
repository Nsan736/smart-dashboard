import CoreLocation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 移動タブ(以前の電車タブ)。上から、切り替え・中央の地図(または路線図、記録)・関連する情報と設定の3段。
struct TrainView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: TrainLiveSelection?
    @State private var directionNames: [String: String] = [:]
    /// 記録で表示する日。空文字は今日。
    @State private var recordDay = ""

    var body: some View {
        let store = env.trains
        let display = env.trainDisplay
        let railways = TrainRailwayChoices.make(store)
        NavigationStack {
            VStack(spacing: 0) {
                if env.movement.isVirtual {
                    MovementDebugBanner()
                }
                MovementControlBar(railways: railways)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                MovementCenterView(selection: $selection, directionNames: directionNames, recordDay: recordDay)
                    .containerRelativeFrame(.vertical) { length, _ in min(max(length * 0.4, 200), 420) }
                    .padding(.horizontal, 8)
                List {
                    switch display.mode {
                    case .map, .diagram:
                        MovementLiveSections(selection: $selection, directionNames: directionNames)
                    case .record:
                        MovementRecordSections(recordDay: $recordDay)
                    }
                    if env.settings.movementDebugEnabled {
                        MovementDebugSections()
                    }
                    Section {
                    } footer: {
                        ODPTAttributionView()
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("移動")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: store.isLoadingInfo || store.isLoadingShapes || env.live.isFetchingDelays) {
                        await store.refreshInfoManually()
                        await store.ensureShapes(manual: true)
                        await env.live.fetchDelaysManually()
                    }
                }
            }
            .task {
                await store.refreshInfoIfStale()
                await store.ensureShapes(manual: false)
                // 列車ごとの時刻表は、Wi-Fi接続中だけ自動で保存する
                await env.live.ensureSchedules(manual: false)
                // 最寄り駅は、タブを開いたときに1回だけ現在地を取って判定する(500m以上動いたときだけ判定し直す)
                await env.live.updateNearestStation()
            }
            .task {
                let endpoints = Set(store.neededRailways.compactMap { OperatorCatalog.find($0.operatorID)?.endpoint })
                for endpoint in endpoints {
                    let names = await store.directionNames(endpoint: endpoint)
                    directionNames.merge(names) { current, _ in current }
                }
            }
            // 路線や駅を登録・削除したら、路線の形と時刻表を取り直す
            .onChange(of: store.neededRailways.map(\.railwayID)) { _, _ in
                Task {
                    await store.ensureShapes(manual: false)
                    await env.live.ensureSchedules(manual: false)
                }
            }
            // 路線を追加・削除したあと、選んでいた路線がなくなっていたら「すべての路線」に戻す
            .onChange(of: railways.map(\.id), initial: true) { _, ids in
                display.validate(available: ids)
            }
            // 遅れの取得と位置の記録は、この画面を表示している間だけ
            .onAppear {
                env.live.setVisible("trainTab", true)
                env.movement.setVisible(true)
            }
            .onDisappear {
                env.live.setVisible("trainTab", false)
                env.movement.setVisible(false)
            }
        }
    }
}

// MARK: - 最上部: 切り替え

struct MovementControlBar: View {
    @Environment(AppEnvironment.self) private var env
    let railways: [RailwayChoice]

    var body: some View {
        @Bindable var display = env.trainDisplay
        VStack(spacing: 6) {
            Picker("表示", selection: $display.mode) {
                ForEach(TrainViewMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if display.mode != .record {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        filterPicker
                        railwayMenu
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        filterPicker
                        railwayMenu
                    }
                }
            }
        }
    }

    private var filterPicker: some View {
        @Bindable var display = env.trainDisplay
        return Picker("電車", selection: $display.filter) {
            ForEach(TrainFilter.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var railwayMenu: some View {
        @Bindable var display = env.trainDisplay
        if railways.count > 1 {
            Menu {
                Picker("路線", selection: $display.selectedRailwayID) {
                    Text("すべての路線").tag(TrainRailwaySelection.all)
                    ForEach(railways) { Text($0.name).tag($0.id) }
                }
            } label: {
                Label(railways.first { $0.id == display.selectedRailwayID }?.name ?? "すべての路線",
                      systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - 中央: 地図・路線図・記録

struct MovementCenterView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: TrainLiveSelection?
    let directionNames: [String: String]
    let recordDay: String

    var body: some View {
        let display = env.trainDisplay
        GeometryReader { proxy in
            switch display.mode {
            case .record:
                MovementRecordMap(dayKey: recordDay.isEmpty ? env.movement.today.day : recordDay)
            case .map, .diagram:
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // 仮想の移動の間は、列車の位置も仮想の時刻で計算する
                    let now = env.movement.currentTime(real: context.date)
                    let board = TrainLiveBoard(env: env, now: now, filter: display.filter, directionNames: directionNames)
                    if display.mode == .map {
                        TrainLiveMapView(board: board, selectedRailwayID: display.selectedRailwayID, selection: $selection,
                                         overlay: RideMapOverlay.make(env: env))
                            .overlay(alignment: .topTrailing) { RideMapBadge() }
                    } else {
                        TrainDiagramView(board: board, selectedRailwayID: display.selectedRailwayID, selection: $selection,
                                         height: proxy.size.height)
                    }
                }
            }
        }
    }
}

/// 地図に重ねる、乗車中の判定と位置のデバッグの表示
struct RideMapOverlay {
    var showsUserLocation = true
    var lines: [MapLine] = []
    var markers: [MapMarker] = []
    var circles: [MapCircle] = []
    var movingMarks: [MapMovingMark] = []
    var onTapCoordinate: ((CLLocationCoordinate2D) -> Void)?
    /// true を返したら、その印のタップは処理済み
    var onSelectMarker: ((String) -> Bool)?

    @MainActor
    static func make(env: AppEnvironment) -> RideMapOverlay {
        let movement = env.movement
        let debug = movement.debug
        var overlay = RideMapOverlay()
        // 仮想の移動の間は、実際の現在地を出さない(取り違えないように)
        overlay.showsUserLocation = !movement.isVirtual
        let judgement = movement.judgement
        // 乗車中: 線路の上の自分の位置(推定中は、列車の時刻表から推定した位置)
        if judgement.isRiding, let railwayID = judgement.railwayID, let along = judgement.along,
           let line = movement.rideLines().first(where: { $0.railwayID == railwayID }), let point = line.path.point(atAlong: along) {
            overlay.movingMarks.append(MapMovingMark(id: "ride", coordinate: point.coordinate,
                                                     color: judgement.state == .estimating ? .systemGray : .systemOrange,
                                                     diameter: 22, isHollow: true))
        }
        guard env.settings.movementDebugEnabled else {
            if movement.isVirtual, let last = movement.recent.last {
                overlay.movingMarks.append(MapMovingMark(id: "raw", coordinate: last.point.coordinate, color: .systemPurple, diameter: 14))
            }
            return overlay
        }
        // 生の位置(精度の円つき)と、線路に投影した位置
        if let last = movement.recent.last {
            overlay.movingMarks.append(MapMovingMark(id: "raw", coordinate: last.point.coordinate, color: .systemPurple, diameter: 14))
            if last.accuracy > 0 {
                overlay.circles.append(MapCircle(id: "accuracy", center: last.point.coordinate, radius: last.accuracy, color: .systemPurple))
            }
        }
        if judgement.state != .estimating, let projected = judgement.debug.projected {
            overlay.movingMarks.append(MapMovingMark(id: "projected", coordinate: projected.coordinate, color: .systemBlue, diameter: 12, isHollow: true))
        }
        // GPSなしの区間では、仮想の本当の位置をグレーで出す
        if debug.isInGap, let position = debug.position {
            overlay.movingMarks.append(MapMovingMark(id: "virtual", coordinate: position.coordinate, color: .systemGray, diameter: 12))
        }
        // 仮想の移動の経路と、GPSなしの区間
        let plan = debug.plan
        if plan.points.count >= 2 {
            overlay.lines.append(MapLine(id: "debug.route", coordinates: plan.points.map(\.coordinate), color: .systemPurple,
                                         casingColor: nil, isEmphasized: false))
            let path = plan.path
            for (index, gap) in plan.gaps.enumerated() {
                guard path.cumulative.indices.contains(gap.fromIndex), path.cumulative.indices.contains(gap.toIndex) else { continue }
                let points = path.subpath(from: path.cumulative[gap.fromIndex], to: path.cumulative[gap.toIndex])
                overlay.lines.append(MapLine(id: "debug.gap\(index)", coordinates: points.map(\.coordinate), color: .systemGray,
                                             casingColor: .black, isEmphasized: false))
            }
        }
        // 点の編集(動かしている間は出さない)
        if !debug.isActive {
            overlay.markers = plan.points.enumerated().map { index, point in
                MapMarker(id: "debug.\(index)", title: "\(index + 1)", coordinate: point.coordinate,
                          style: debug.selectedPoint == index ? .debugSelected : .debugPoint)
            }
            if debug.placesPoints {
                overlay.onTapCoordinate = { coordinate in debug.tapMap(GeoPoint(coordinate)) }
            }
            overlay.onSelectMarker = { id in
                guard id.hasPrefix("debug."), let index = Int(id.dropFirst(6)) else { return false }
                debug.selectedPoint = debug.selectedPoint == index ? nil : index
                return true
            }
        }
        return overlay
    }
}

/// 地図の右上: 乗車中の判定と、デバッグの途中の値
struct RideMapBadge: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let judgement = env.movement.judgement
        VStack(alignment: .trailing, spacing: 4) {
            if judgement.isRiding {
                Text(judgement.state == .estimating ? "推定中(GPSなし)"
                     : "乗車中の可能性あり" + (judgement.confidence.map { "・" + $0.label } ?? ""))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(judgement.state == .estimating ? Color.gray : Color.orange, in: Capsule())
            }
            if env.settings.movementDebugEnabled {
                RideDebugValuesView(judgement: judgement)
            }
        }
        .padding(6)
    }
}

/// 判定の途中の値(線までの距離、線に沿った速さ、継続時間、候補の列車と照合の距離)
struct RideDebugValuesView: View {
    let judgement: RideJudgement

    var body: some View {
        let debug = judgement.debug
        VStack(alignment: .leading, spacing: 1) {
            Text("線まで " + (debug.lateral.map { "\(Int($0))m" } ?? "-"))
            Text("線に沿った速さ " + (debug.alongSpeed.map { "\(Int(($0 * 3.6).rounded()))km/h" } ?? "-"))
            Text("継続 \(Int(debug.continued))秒・駅で停止\(debug.stationStops)・駅以外\(debug.offStationStops)")
            if let accuracy = debug.rawAccuracy { Text("精度 ±\(Int(accuracy))m") }
            ForEach(Array(debug.candidates.prefix(3).enumerated()), id: \.offset) { _, candidate in
                Text("\(candidate.trainID == judgement.trainID ? "* " : "")\(candidate.label) \(Int(candidate.distance))m")
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .padding(5)
        .frame(maxWidth: 190, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// デバッグ中は、画面の上部に目立つ表示を出す
struct MovementDebugBanner: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let debug = env.movement.debug
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                Text("デバッグ中(仮想の位置)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text("\(MovementFormat.clock(debug.clock.now)) ×\(MovementFormat.scale(debug.plan.timeScale))")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.red)
        }
    }
}

enum MovementFormat {
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = JapaneseHolidays.calendar
        f.timeZone = JapaneseHolidays.calendar.timeZone
        f.dateFormat = "M/d H:mm:ss"
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        TrainSelectionCard.timeText(date)
    }

    static func distance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1fkm", meters / 1000) : "\(Int(meters.rounded()))m"
    }

    static func scale(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - 下部: 地図・路線図のとき

struct MovementLiveSections: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: TrainLiveSelection?
    let directionNames: [String: String]
    @State private var legendExpanded = false

    var body: some View {
        let store = env.trains
        let display = env.trainDisplay
        let items = store.info?.value ?? []
        let sortedLines = TrainSummary.sorted(store.lines, items: items)

        if selection != nil || display.filter != .all {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = env.movement.currentTime(real: context.date)
                    let board = TrainLiveBoard(env: env, now: now, filter: display.filter, directionNames: directionNames)
                    VStack(alignment: .leading, spacing: 8) {
                        if let selection {
                            TrainSelectionCard(board: board, selection: selection) { self.selection = nil }
                        }
                        if display.filter != .all {
                            ApproachGroupsView(board: board, selection: $selection)
                        }
                    }
                }
            } header: {
                Text(display.filter == .all ? "選んだもの" : display.filter.title)
            }
        }

        RideStatusSection()

        Section {
            Label(TrainSummary.text(lines: store.lines, items: items), systemImage: "tram")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(sortedLines) { line in
                TrainInfoRow(line: line, item: items.first { $0.railwayID == line.railwayID })
            }
            .onDelete { offsets in
                store.removeLines(ids: offsets.map { sortedLines[$0].railwayID })
            }
            if !store.lines.isEmpty {
                DataStatusView(fetchedAt: store.info?.fetchedAt, note: store.autoRefreshNote, error: store.infoError)
            }
        } header: {
            Text("運行情報(状況が悪い順)")
        }

        Section("登録した駅の次の電車") {
            if store.stations.isEmpty {
                Text("駅が登録されていません").foregroundStyle(.secondary)
            } else {
                TodayTimetablePicker()
            }
            ForEach(store.stations) { station in
                NextTrainRow(station: station)
            }
            .onDelete { store.removeStations(at: $0) }
            if let error = store.timetableError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }

        Section("列車の位置と遅れ") {
            TrainLiveStatusView()
            if let error = store.shapeError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if !store.stationsWithoutCoordinates.isEmpty {
                Text("位置が提供されていない駅: \(store.stationsWithoutCoordinates.map(ODPTID.tail).joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("凡例", isExpanded: $legendExpanded) {
                TrainLegendView()
            }
            .font(.subheadline)
        }

        MovementSettingsSection()
    }
}

/// 乗車中の情報
struct RideStatusSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let movement = env.movement
                let now = movement.currentTime(real: context.date)
                let judgement = movement.judgement
                let rideContext = movement.context(now: now)
                let info = RideInfo.make(judgement: judgement, lines: rideContext.lines, trains: rideContext.trains,
                                         registeredStationIDs: Set(env.trains.stations.map(\.stationID)))
                RideInfoView(info: info, judgement: judgement, now: now, choices: judgement.isRiding ? movement.choices(now: now) : [])
            }
            if env.movement.gpsAvailability == .denied, !env.movement.isVirtual {
                Label("位置情報を使えないため、判定できません(設定アプリで許可できます)", systemImage: "location.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if env.movement.isReducedAccuracy, !env.movement.isVirtual {
                Label("位置の精度が「おおよそ」のため、判定できません。設定アプリで「正確な位置情報」をオンにしてください。", systemImage: "location.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("乗車中の電車")
        } footer: {
            Text("線路の近くを線に沿って時速15km以上で30秒以上動くと、時刻表から計算した列車の位置と照合します。判定は目安です。")
        }
    }
}

struct RideInfoView: View {
    @Environment(AppEnvironment.self) private var env
    let info: RideInfo
    let judgement: RideJudgement
    let now: Date
    let choices: [RideTrainCandidate]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.stateText)
                    .font(.headline)
                    .foregroundStyle(judgement.isRiding ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let confidence = judgement.confidence, judgement.isRiding {
                    Text("確からしさ \(confidence.label)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Self.color(confidence).opacity(0.2), in: Capsule())
                }
            }
            if let railwayName = info.railwayName {
                Text([railwayName, info.directionText].compactMap { $0 }.joined(separator: "・"))
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let train = info.train {
                Text("\(train.trainType.isEmpty ? "種別不明" : train.trainType)・列車番号 \(train.number)\(judgement.isManual ? "(手動で選択)" : "")")
                    .font(.subheadline)
                Label(train.delay.label, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(TrainColors.color(train.delay.tone))
                    .fixedSize(horizontal: false, vertical: true)
            } else if judgement.isRiding {
                Text("列車を特定できていません(時刻表が未保存か、近くに列車がありません)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let next = info.nextStops.first {
                VStack(alignment: .leading, spacing: 0) {
                    Text("次は \(next.name)")
                        .font(.title2.weight(.bold))
                    Text("\(MovementFormat.time(next.arrival))着予定・\(NextTrainRow.countdown(to: next.arrival, now: now))"
                         + (info.nextStopDistance.map { "・" + MovementFormat.distance($0) } ?? ""))
                        .font(.subheadline)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                if info.nextStops.count > 1 {
                    Text("その先: " + info.nextStops.dropFirst().map { "\($0.name) \(MovementFormat.time($0.arrival))" }.joined(separator: " → "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let next = info.aheadStations.first {
                Text("次は \(next)" + (info.nextStopDistance.map { "(" + MovementFormat.distance($0) + ")" } ?? ""))
                    .font(.title3.weight(.bold))
                if info.aheadStations.count > 1 {
                    Text("その先: " + info.aheadStations.dropFirst().joined(separator: " → "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(info.targets.prefix(2).enumerated()), id: \.offset) { _, target in
                Label("\(target.name)まで あと\(target.stopsAway)駅" + (target.arrival.map { "・\(MovementFormat.time($0))着(\(NextTrainRow.countdown(to: $0, now: now)))" } ?? ""),
                      systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let speed = info.speedKmh {
                Text("今の速度 \(Int(speed.rounded()))km/h")
                    .font(.subheadline)
                    .monospacedDigit()
            }
            if judgement.state == .estimating, let lastFix = judgement.lastFix {
                Text("最後に位置が取れたのは \(Int(now.timeIntervalSince(lastFix)))秒前。列車の時刻表で位置を推定しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let check = judgement.answerCheck {
                Text("GPSが戻ったときの、推定との差: \(MovementFormat.distance(check))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = judgement.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if judgement.isRiding {
                Menu {
                    Button("自動で判定する") { env.movement.selectTrain(nil) }
                    ForEach(choices.prefix(8), id: \.id) { train in
                        Button("\(train.label)(\(MovementFormat.distance(abs(train.along - (judgement.along ?? 0)))))") {
                            env.movement.selectTrain(train.id)
                        }
                    }
                } label: {
                    Label("列車を選び直す", systemImage: "hand.tap")
                        .font(.subheadline)
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func color(_ confidence: RideConfidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .gray
        }
    }
}

/// 関連する設定(登録の管理、判定のオン・オフ、記録の保存期間)
struct MovementSettingsSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Section {
            Toggle("乗車中の判定", isOn: Binding(
                get: { env.settings.rideDetectionEnabled },
                set: { env.movement.setDetectionEnabled($0) }))
            MovementRetentionPicker()
            NavigationLink {
                OperatorPickerView()
            } label: {
                Label("路線・駅を登録", systemImage: "plus.circle")
            }
            NavigationLink {
                TrainRegistrationListView()
            } label: {
                Label("登録した路線・駅の管理", systemImage: "list.bullet")
            }
        } header: {
            Text("設定")
        } footer: {
            Text("位置は、この画面を表示している間だけ高精度のGPSで取得し、直近10分をメモリに持ちます。記録は端末の中だけに保存し、外部には送りません。")
        }
    }
}

struct MovementRetentionPicker: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Picker("記録の保存期間", selection: Binding(
            get: { env.settings.movementRetention },
            set: { value in
                env.settings.movementRetention = value
                env.movement.applyRetention()
            })) {
            ForEach(MovementRetention.allCases) { Text($0.label).tag($0) }
        }
    }
}

// MARK: - 記録

struct MovementRecordMap: View {
    @Environment(AppEnvironment.self) private var env
    let dayKey: String

    var body: some View {
        let day = env.movement.day(dayKey) ?? MovementDay(day: dayKey)
        let lines = MovementLogPolicy.segments(day).enumerated().map { index, segment in
            MapLine(id: "log\(index)", coordinates: segment.points.map(\.coordinate),
                    color: segment.isRide ? .systemOrange : .systemBlue,
                    casingColor: segment.isRide ? .white : nil, isEmphasized: false)
        }
        ZStack {
            MapContainerView(isInteractive: true, showsUserLocation: !env.movement.isVirtual, lines: lines, fitKey: dayKey)
            if day.samples.count < 2 {
                Text("この日の記録はありません")
                    .font(.footnote)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MovementRecordSections: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var recordDay: String
    @State private var exportURL: URL?
    @State private var confirmsClear = false

    var body: some View {
        let movement = env.movement
        let key = recordDay.isEmpty ? movement.today.day : recordDay
        let day = movement.day(key) ?? MovementDay(day: key)
        let days = movement.savedDays()
        Section {
            if days.count > 1 {
                Picker("日付", selection: $recordDay) {
                    ForEach(days, id: \.self) { value in
                        Text(value == movement.today.day ? "今日(\(value))" : value).tag(value == movement.today.day ? "" : value)
                    }
                }
            }
            LabeledContent("移動した距離", value: MovementFormat.distance(MovementLogPolicy.distance(day.samples)))
            LabeledContent("記録した点", value: "\(day.samples.count)")
            if day.rides.isEmpty {
                Text("乗車と判定した区間はありません").foregroundStyle(.secondary)
            }
            ForEach(day.rides) { ride in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(MovementFormat.time(ride.start))〜\(MovementFormat.time(ride.end)) \(ride.railwayName)")
                        .font(.subheadline.weight(.semibold))
                    Text((ride.trainLabel ?? "列車は特定できず") + "・確からしさ " + (RideConfidence(rawValue: ride.confidence)?.label ?? "-"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("記録(\(key))")
        } footer: {
            Text("青い線は移動、オレンジの線は乗車と判定した区間です。点は5秒か25mごとに残します。デバッグの仮想の移動は記録しません。")
        }

        Section {
            Button("GPXファイルを作る") { exportURL = movement.exportGPX(day: key) }
                .disabled(day.samples.isEmpty)
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("GPXを共有", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("書き出し")
        }

        Section {
            MovementRetentionPicker()
            Button("今日の記録を消す", role: .destructive) { confirmsClear = true }
        } header: {
            Text("保存")
        } footer: {
            Text("記録は端末の中だけに保存し、外部には送りません。「保存しない」では、今日の分をメモリにだけ持ちます。")
        }
        .confirmationDialog("今日の移動の記録を消しますか", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                movement.clearToday()
                exportURL = nil
            }
        }
    }
}

// MARK: - 位置のデバッグ

struct MovementDebugSections: View {
    @Environment(AppEnvironment.self) private var env
    @State private var railwayID = ""
    @State private var fromStation = 0
    @State private var toStation = 1
    @State private var stationDwell: Double = 30
    @State private var gapFrom = 1
    @State private var gapTo = 2
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        let movement = env.movement
        @Bindable var debug = movement.debug
        let plan = debug.plan

        Section {
            Text(runText(debug))
                .font(.subheadline.weight(.semibold))
            switch debug.runState {
            case .idle:
                Button("開始(線に沿って動かす)") {
                    message = movement.startVirtualRoute() ? nil : "点を2つ以上置いてください"
                }
            case .running:
                Button("一時停止") { debug.pause() }
                Button("停止", role: .destructive) { movement.stopVirtual() }
            case .paused:
                Button("再開") { debug.resume() }
                Button("停止", role: .destructive) { movement.stopVirtual() }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("位置のデバッグ: 操作")
        } footer: {
            Text("開始すると、位置の提供元が実際のGPSから仮想の移動に切り替わります。列車の位置も、仮想の時刻で計算します。")
        }

        Section {
            VStack(alignment: .leading) {
                Text("速さ \(Int(plan.speedKmh))km/h")
                Slider(value: $debug.plan.speedKmh, in: 5...130, step: 5)
            }
            Picker("時間の倍率", selection: $debug.plan.timeScale) {
                ForEach(VirtualPlan.timeScales, id: \.self) { Text("1秒 = \(MovementFormat.scale($0))秒").tag($0) }
            }
            Stepper("位置のばらつき ±\(Int(plan.noiseMeters))m", value: $debug.plan.noiseMeters, in: 0...100, step: 5)
            Toggle("仮想の時刻の開始を指定", isOn: Binding(
                get: { debug.plan.startClock != nil },
                set: { debug.plan.startClock = $0 ? nextWeekdayMorning() : nil }))
            if plan.startClock != nil {
                DatePicker("開始の時刻", selection: Binding(
                    get: { debug.plan.startClock ?? Date() },
                    set: { debug.plan.startClock = $0 }))
                    .environment(\.timeZone, JapaneseHolidays.calendar.timeZone)
                Button("平日の8時にする") { debug.plan.startClock = nextWeekdayMorning() }
            }
        } header: {
            Text("位置のデバッグ: 設定")
        } footer: {
            Text("速さと倍率は、動かしながら変えられます。仮想の時刻の開始は、次に開始したときから使います。")
        }

        if !debug.isActive {
            Section {
                Toggle("地図のタップで点を置く", isOn: $debug.placesPoints)
                Text("点の数: \(plan.points.count)")
                if let selected = debug.selectedPoint, plan.points.indices.contains(selected) {
                    Text("点\(selected + 1)を選んでいます。次に地図をタップすると、その場所へ移します。")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("この点で停車", isOn: Binding(
                        get: { debug.dwell(at: selected) != nil },
                        set: { debug.setDwell($0 ? 30 : nil, at: selected) }))
                    if let dwell = debug.dwell(at: selected) {
                        Stepper("停車時間 \(Int(dwell))秒", value: Binding(
                            get: { debug.dwell(at: selected) ?? 30 },
                            set: { debug.setDwell($0, at: selected) }), in: 5...300, step: 5)
                    }
                    Button("この点を消す", role: .destructive) { debug.removeSelectedPoint() }
                    Button("選択を解除") { debug.selectedPoint = nil }
                }
                Button("点を全部消す", role: .destructive) { debug.clearPoints() }
                    .disabled(plan.points.isEmpty)
            } header: {
                Text("位置のデバッグ: 線を引く")
            } footer: {
                Text("地図の番号の印をタップすると、その点を選べます。紫の線が仮想の移動の経路です。")
            }

            alongRailwaySection(debug)

            Section {
                ForEach(Array(plan.gaps.enumerated()), id: \.offset) { index, gap in
                    HStack {
                        Text("点\(gap.fromIndex + 1)〜点\(gap.toIndex + 1)")
                        Spacer()
                        Button(role: .destructive) {
                            debug.plan.gaps.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if plan.points.count >= 2 {
                    Stepper("始まり: 点\(gapFrom)", value: $gapFrom, in: 1...max(1, plan.points.count))
                    Stepper("終わり: 点\(gapTo)", value: $gapTo, in: 1...max(1, plan.points.count))
                    Button("GPSなしの区間を追加") {
                        debug.plan.gaps.append(VirtualPlan.Gap(fromIndex: gapFrom - 1, toIndex: gapTo - 1))
                        debug.plan.normalize()
                    }
                    .disabled(gapFrom == gapTo)
                }
            } header: {
                Text("位置のデバッグ: GPSなしの区間")
            } footer: {
                Text("地下の区間の再現に使います。この区間では位置を出さないので、判定は列車の時刻表での推定に切り替わります(地図ではグレーの線)。")
            }
        }

        Section {
            Button("GPXを読み込む") { importing = true }
            Button("今日の記録を読み込む") {
                let samples = movement.today.samples
                if samples.count >= 2 {
                    debug.gpxTrack = GPXCodec.Track(name: "今日の記録", samples: samples)
                    debug.gpxMessage = "今日の記録(\(samples.count)点)を読み込みました"
                } else {
                    debug.gpxMessage = "今日の記録がありません"
                }
            }
            if let text = debug.gpxMessage {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
            Button("GPXを再生") {
                message = movement.startReplay() ? nil : "先にGPXを読み込んでください"
            }
            .disabled(debug.gpxTrack == nil || debug.isActive)
        } header: {
            Text("位置のデバッグ: GPXの再生")
        } footer: {
            Text("記録した時刻の間隔のまま、時間の倍率で早送りします。仮想の時刻の開始を指定しないときは、GPXの時刻をそのまま使います。")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { outcome in
            guard case .success(let url) = outcome else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), data.count <= 20_000_000 {
                debug.loadGPX(data)
            } else {
                debug.gpxMessage = "読み込めませんでした(20MBまで)"
            }
        }
    }

    @ViewBuilder
    private func alongRailwaySection(_ debug: MovementDebugSession) -> some View {
        let lines = env.movement.rideLines()
        let line = lines.first { $0.railwayID == railwayID } ?? lines.first
        Section {
            if let line {
                if lines.count > 1 {
                    Picker("路線", selection: Binding(get: { line.railwayID }, set: { railwayID = $0; fromStation = 0; toStation = 1 })) {
                        ForEach(lines, id: \.railwayID) { Text($0.name).tag($0.railwayID) }
                    }
                }
                Picker("出発", selection: $fromStation) {
                    ForEach(Array(line.stations.enumerated()), id: \.offset) { index, station in Text(station.name).tag(index) }
                }
                Picker("到着", selection: $toStation) {
                    ForEach(Array(line.stations.enumerated()), id: \.offset) { index, station in Text(station.name).tag(index) }
                }
                Stepper("途中の駅の停車 \(Int(stationDwell))秒", value: $stationDwell, in: 0...180, step: 10)
                Button("路線に沿わせる") {
                    if let plan = VirtualPlan.stationPlan(line: line, fromStation: fromStation, toStation: toStation,
                                                          dwell: stationDwell, base: debug.plan) {
                        debug.plan = plan
                        debug.selectedPoint = nil
                    }
                }
                .disabled(fromStation == toStation || !line.stations.indices.contains(fromStation) || !line.stations.indices.contains(toStation))
            } else {
                Text("路線の形がまだありません。路線を登録して、形を取得してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("位置のデバッグ: 路線に沿わせる")
        } footer: {
            Text("2駅の間を、線路の線(駅を結んだ線)に沿った経路にします。途中の駅には停車します。今の点は置き換えます。")
        }
    }

    private func runText(_ debug: MovementDebugSession) -> String {
        switch debug.runState {
        case .idle: return "停止中(実際のGPSを使っています)"
        case .running: return debug.isFinished ? "終点に着きました" : (debug.isInGap ? "動作中(GPSなしの区間)" : "動作中")
        case .paused: return "一時停止中"
        }
    }

    /// 次の平日の8時(今日が平日なら今日)
    private func nextWeekdayMorning() -> Date {
        let calendar = JapaneseHolidays.calendar
        let resolver = env.settings.dayTypeResolver
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<10 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if resolver.dayType(of: day.addingTimeInterval(12 * 3600)) == .weekday {
                return VirtualClock.start(on: day, hour: 8, minute: 0)
            }
        }
        return VirtualClock.start(on: today, hour: 8, minute: 0)
    }
}

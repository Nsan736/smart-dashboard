import CoreLocation
import SwiftUI
import UIKit

enum TrainViewMode: String, CaseIterable, Identifiable {
    case map
    case diagram

    var id: String { rawValue }
    var label: String { self == .map ? "地図" : "路線図" }
}

enum TrainLiveSelection: Equatable {
    case line(String)
    case station(String)
    case train(String)
}

/// 電車タブの上部。地図と路線図の切り替え、表示する電車の絞り込み、凡例、タップした対象の詳細。
struct TrainLivePanel: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: TrainLiveSelection?
    @State private var directionNames: [String: String] = [:]
    @State private var legendExpanded = false

    var body: some View {
        // 表示の状態(地図/路線図、絞り込み、選んだ路線)は、地図と路線図で1つを共有する。
        // 切り替えの部品は、1秒ごとに描き直す TimelineView の外に置き、どちらの表示でも同じ位置で常に操作できるようにする。
        @Bindable var display = env.trainDisplay
        let railways = TrainLivePanel.railwayChoices(env.trains)
        Picker("表示", selection: $display.mode) {
            ForEach(TrainViewMode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Picker("電車", selection: $display.filter) {
            ForEach(TrainFilter.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        if railways.count > 1 {
            Picker("路線", selection: $display.selectedRailwayID) {
                Text("すべての路線").tag(TrainRailwaySelection.all)
                ForEach(railways) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
        }

        TimelineView(.periodic(from: .now, by: 1)) { context in
            let board = TrainLiveBoard(env: env, now: context.date, filter: display.filter, directionNames: directionNames)
            VStack(alignment: .leading, spacing: 8) {
                switch display.mode {
                case .map:
                    TrainLiveMapView(board: board, selectedRailwayID: display.selectedRailwayID, selection: $selection)
                        .frame(height: 300)
                case .diagram:
                    TrainDiagramView(board: board, selectedRailwayID: display.selectedRailwayID, selection: $selection)
                }
                if let selection {
                    TrainSelectionCard(board: board, selection: selection) { self.selection = nil }
                }
                if display.filter != .all {
                    ApproachGroupsView(board: board, selection: $selection)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

        DisclosureGroup("凡例", isExpanded: $legendExpanded) {
            TrainLegendView()
        }
        .font(.subheadline)
        TrainLiveStatusView()
            // 路線を追加・削除したあと、選んでいた路線がなくなっていたら「すべての路線」に戻す
            .onChange(of: railways.map(\.id), initial: true) { _, ids in
                display.validate(available: ids)
            }
            .task {
                let endpoints = Set(env.trains.neededRailways.compactMap { OperatorCatalog.find($0.operatorID)?.endpoint })
                for endpoint in endpoints {
                    let names = await env.trains.directionNames(endpoint: endpoint)
                    directionNames.merge(names) { current, _ in current }
                }
            }
    }
}

/// 路線の切り替えに出す選択肢
struct RailwayChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

extension TrainLivePanel {
    /// 選べる路線(運行情報の路線と、時刻表の駅がある路線)
    static func railwayChoices(_ trains: TrainStore) -> [RailwayChoice] {
        let names = Dictionary(trains.lines.map { ($0.railwayID, $0.railwayName) } + trains.stations.map { ($0.railwayID, $0.railwayName) },
                               uniquingKeysWith: { first, _ in first })
        return trains.neededRailways.map { RailwayChoice(id: $0.railwayID, name: names[$0.railwayID] ?? ODPTID.tail($0.railwayID)) }
    }
}

/// ある時刻の、表示に必要なものをまとめて計算したもの
@MainActor
struct TrainLiveBoard {
    let now: Date
    let filter: TrainFilter
    let lines: [BoardLine]
    let groups: [ApproachGroup]
    let nearest: NearestStation?
    let registeredStationIDs: Set<String>
    /// 絞り込みのあとで表示する電車のID。nilならすべて表示する。
    let visibleTrainIDs: Set<String>?

    init(env: AppEnvironment, now: Date, filter: TrainFilter, directionNames: [String: String]) {
        self.now = now
        self.filter = filter
        let trains = env.trains
        let live = env.live
        let names = Dictionary(trains.lines.map { ($0.railwayID, $0.railwayName) } + trains.stations.map { ($0.railwayID, $0.railwayName) },
                               uniquingKeysWith: { first, _ in first })
        let built: [BoardLine] = trains.neededRailways.compactMap { railway in
            guard let schedule = live.schedules[railway.railwayID] else { return nil }
            return BoardLine(railwayID: railway.railwayID, name: names[railway.railwayID] ?? ODPTID.tail(railway.railwayID),
                             schedule: schedule, shape: trains.shapes[railway.railwayID],
                             positions: live.positions(for: railway.railwayID, now: now, includesWaiting: filter != .all))
        }
        lines = built
        nearest = live.nearest
        registeredStationIDs = Set(trains.stations.map(\.stationID))

        var result: [ApproachGroup] = []
        switch filter {
        case .all:
            break
        case .registered:
            var seen = Set<String>()
            for station in trains.stations where seen.insert(station.stationID).inserted {
                guard let line = built.first(where: { $0.railwayID == station.railwayID }) else { continue }
                result += TrainBoard.groups(for: station.stationID, stationName: station.stationName, in: line,
                                            directionNames: directionNames, now: now)
            }
        case .nearMe:
            if let nearest = live.nearest, let line = built.first(where: { $0.railwayID == nearest.railwayID }) {
                result += TrainBoard.groups(for: nearest.stationID, stationName: nearest.name, in: line,
                                            directionNames: directionNames, now: now)
            }
        }
        groups = result
        visibleTrainIDs = filter == .all ? nil : Set(result.flatMap { $0.approaches.map(\.id) })
    }

    func visiblePositions(in line: BoardLine) -> [TrainPosition] {
        guard let visibleTrainIDs else { return line.positions.filter { !$0.isWaitingToDepart } }
        return line.positions.filter { visibleTrainIDs.contains($0.id) }
    }

    func find(trainID: String) -> (line: BoardLine, position: TrainPosition)? {
        for line in lines {
            if let position = line.positions.first(where: { $0.id == trainID }) { return (line, position) }
        }
        return nil
    }
}

enum TrainColors {
    /// 電車の色: 時刻どおり=緑、遅れあり=オレンジ、不明=グレー
    static func uiColor(_ tone: DelaySource.Tone) -> UIColor {
        switch tone {
        case .onTime: return .systemGreen
        case .delayed: return .systemOrange
        case .unknown: return .systemGray
        }
    }

    static func color(_ tone: DelaySource.Tone) -> Color {
        Color(uiColor: uiColor(tone))
    }
}

// MARK: - 地図

struct TrainLiveMapView: View {
    @Environment(AppEnvironment.self) private var env
    let board: TrainLiveBoard
    /// 選んだ路線。空文字は「すべての路線」。
    let selectedRailwayID: String
    @Binding var selection: TrainLiveSelection?
    @State private var recenterKey = 0

    var body: some View {
        let store = env.trains
        let items = store.info?.value ?? []
        let shapes = store.neededRailways.compactMap { store.shapes[$0.railwayID] }.filter(\.isDrawable)
        let lines = shapes.map { shape -> MapLine in
            let isInfoLine = store.lines.contains { $0.railwayID == shape.railwayID }
            let status = isInfoLine ? items.first(where: { $0.railwayID == shape.railwayID })?.status : nil
            let isSelected = TrainDisplayState.isEmphasized(shape.railwayID, selected: selectedRailwayID)
            return MapLine(
                id: shape.railwayID,
                coordinates: shape.stops.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                color: TrainMapBuilder.uiColor(status),
                casingColor: UIColor(hex: shape.colorHex),
                isEmphasized: isSelected && (status == .delay || status == .suspended),
                isDimmed: !isSelected
            )
        }
        // 選んだ路線だけに表示範囲を合わせる(「すべての路線」なら全体)
        let fitShapes = shapes.filter { TrainDisplayState.isEmphasized($0.railwayID, selected: selectedRailwayID) }
        let dots = TrainMapBuilder.stationDots(shapes: shapes, registered: board.registeredStationIDs, nearestStationID: board.nearest?.stationID)
        let trains = board.lines.flatMap { line -> [MapTrain] in
            board.visiblePositions(in: line).compactMap { position -> MapTrain? in
                guard let place = TrainBoard.coordinate(of: position, in: line) else { return nil }
                let badge = TrainBoard.typeBadge(position.trainType)
                return MapTrain(id: position.id, coordinate: place.coordinate, heading: place.heading,
                                color: TrainColors.uiColor(position.delay.tone), label: badge.label, isExpress: badge.isExpress,
                                isDimmed: !TrainDisplayState.isEmphasized(line.railwayID, selected: selectedRailwayID))
            }
        }
        ZStack(alignment: .bottomTrailing) {
            MapContainerView(
                isInteractive: true,
                showsUserLocation: true,
                lines: lines,
                fitKey: (fitShapes.isEmpty ? shapes : fitShapes).map(\.railwayID).joined(separator: ","),
                fitLineIDs: Set((fitShapes.isEmpty ? shapes : fitShapes).map(\.railwayID)),
                onSelectLine: { selection = .line($0) },
                onSelectMarker: { selection = .station($0) },
                trains: trains,
                stationDots: dots,
                onSelectTrain: { selection = .train($0) },
                recenterKey: recenterKey
            )
            Button {
                recenterKey += 1
            } label: {
                Image(systemName: "location.fill")
                    .font(.body)
                    .frame(width: 40, height: 40)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .padding(.bottom, 30)
            .accessibilityLabel("現在地へ移動")
            if shapes.isEmpty {
                Text(store.isLoadingShapes ? "路線の形を取得中" : "路線の形は未取得です。右上の更新ボタンで取得します。")
                    .font(.footnote)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 路線図

/// 1本の線で表した路線図。駅を縦に並べ、駅の順に進む電車を右、逆向きの電車を左に描く。
struct TrainDiagramView: View {
    @Environment(AppEnvironment.self) private var env
    let board: TrainLiveBoard
    /// 選んだ路線。空文字は「すべての路線」で、その場合は全路線を順に並べる。
    let selectedRailwayID: String
    @Binding var selection: TrainLiveSelection?

    private let rowHeight: CGFloat = 40
    private let laneWidth: CGFloat = 46
    private let trackWidth: CGFloat = 22

    var body: some View {
        let lines = board.lines.filter { TrainDisplayState.isEmphasized($0.railwayID, selected: selectedRailwayID) }
        VStack(alignment: .leading, spacing: 10) {
            if lines.isEmpty {
                Text("列車ごとの時刻表がまだありません。下の「時刻表を取得」から保存してください。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.railwayID) { line in
                if lines.count > 1 {
                    Text(line.name).font(.subheadline.weight(.bold))
                }
                diagram(line, height: lines.count > 1 ? 260 : 340)
                    // 路線を切り替えたら、登録した駅の付近へのスクロールをやり直す
                    .id(line.railwayID)
            }
        }
    }

    private func diagram(_ line: BoardLine, height: CGFloat) -> some View {
        let order = TrainMapBuilder.diagramOrder(for: line)
        let focusID = order.first { board.registeredStationIDs.contains($0) } ?? board.nearest?.stationID
        let statusColor = TrainInfoRow.color(env.trains.info?.value.first { $0.railwayID == line.railwayID }?.status)
        return ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(Array(order.enumerated()), id: \.offset) { index, stationID in
                            stationRow(index: index, stationID: stationID, line: line, isLast: index == order.count - 1, color: statusColor)
                                .id(index)
                        }
                    }
                    ForEach(board.visiblePositions(in: line)) { position in
                        if let place = TrainBoard.diagramPosition(of: position, in: line, order: order) {
                            trainMark(position, isAscending: place.isAscending)
                                .offset(x: place.isAscending ? laneWidth + trackWidth + 4 : 4,
                                        y: CGFloat(place.value) * rowHeight + rowHeight / 2 - 13)
                                .animation(.linear(duration: 1), value: place.value)
                        }
                    }
                }
            }
            .frame(height: height)
            .onAppear {
                // 路線が長い場合は、登録した駅(なければ最寄り駅)の付近を中心に表示する
                if let focusID, let index = order.firstIndex(of: focusID) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func stationRow(index: Int, stationID: String, line: BoardLine, isLast: Bool, color: Color) -> some View {
        let isRegistered = board.registeredStationIDs.contains(stationID)
        let isNearest = board.nearest?.stationID == stationID
        let name = line.shape?.stops.first { $0.stationID == stationID }?.name ?? ODPTID.tail(stationID)
        return HStack(spacing: 0) {
            Color.clear.frame(width: laneWidth)
            ZStack {
                Rectangle()
                    .fill(color)
                    .frame(width: 5)
                    .padding(.top, index == 0 ? rowHeight / 2 : 0)
                    .padding(.bottom, isLast ? rowHeight / 2 : 0)
                Circle()
                    .fill(isRegistered ? Color.indigo : Color(.systemBackground))
                    .overlay(Circle().stroke(isRegistered ? Color.white : Color.primary, lineWidth: 2))
                    .frame(width: isRegistered ? 16 : 11, height: isRegistered ? 16 : 11)
            }
            .frame(width: trackWidth)
            Color.clear.frame(width: laneWidth)
            HStack(spacing: 4) {
                Text(name)
                    .font(isRegistered || isNearest ? .subheadline.weight(.bold) : .subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if isRegistered {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.indigo)
                }
                if isNearest {
                    Label("最寄り", systemImage: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if isRegistered { selection = .station(stationID) }
        }
    }

    /// 駅の順に進む電車は下向き、逆は上向きの矢印
    private func trainMark(_ position: TrainPosition, isAscending: Bool) -> some View {
        let badge = TrainBoard.typeBadge(position.trainType)
        return Button {
            selection = .train(position.id)
        } label: {
            HStack(spacing: 2) {
                Image(systemName: isAscending ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                    .font(.system(size: 13))
                if !badge.label.isEmpty {
                    Text(badge.label).font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(height: 26)
            .background(TrainColors.color(position.delay.tone),
                        in: RoundedRectangle(cornerRadius: badge.isExpress ? 5 : 13))
            .frame(width: laneWidth - 8, alignment: isAscending ? .leading : .trailing)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 詳細・一覧・凡例・状態

/// タップした電車・路線・駅の詳細
struct TrainSelectionCard: View {
    @Environment(AppEnvironment.self) private var env
    let board: TrainLiveBoard
    let selection: TrainLiveSelection
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                content
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .train(let id):
            if let found = board.find(trainID: id) {
                trainDetail(found.position, line: found.line)
            } else {
                Text("この電車は運行を終えました").font(.footnote).foregroundStyle(.secondary)
            }
        case .line(let railwayID):
            TrainSelectionDetail(selection: .line(railwayID))
        case .station(let stationID):
            TrainSelectionDetail(selection: .station(stationID))
        }
    }

    private func trainDetail(_ position: TrainPosition, line: BoardLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(position.destination.isEmpty ? "行先不明" : position.destination + "行") \(position.trainType)")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(line.name)・列車番号 \(position.number)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label(position.delay.label, systemImage: "clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TrainColors.color(position.delay.tone))
                .fixedSize(horizontal: false, vertical: true)
            if position.isWaitingToDepart {
                Text("\(line.stationName(position.fromStation))駅で発車待ち").font(.subheadline)
            } else if position.isStopped {
                Text("\(line.stationName(position.fromStation))駅に停車中").font(.subheadline)
            }
            if let next = position.upcoming.first {
                Text("次の停車駅: \(line.stationName(next.station)) \(Self.timeText(next.arrival)) 着予定")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("終点に到着").font(.subheadline)
            }
        }
    }

    static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = JapaneseHolidays.calendar
        f.timeZone = JapaneseHolidays.calendar.timeZone
        f.dateFormat = "H:mm"
        return f.string(from: date)
    }
}

/// 「登録した駅に近い電車」「自分の近くの電車」の一覧
struct ApproachGroupsView: View {
    @Environment(AppEnvironment.self) private var env
    let board: TrainLiveBoard
    @Binding var selection: TrainLiveSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if board.filter == .nearMe {
                if let nearest = board.nearest {
                    Label("最寄り駅: \(nearest.name)(約\(Int(nearest.distance))m)", systemImage: "location.fill")
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text(env.live.nearestError ?? "現在地から最寄り駅を判定しています。路線の形が未取得だと判定できません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if board.groups.isEmpty {
                Text(board.lines.isEmpty ? "列車ごとの時刻表がまだありません" : "向かっている電車はありません")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(board.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.stationName)・\(group.directionName)")
                        .font(.subheadline.weight(.bold))
                    ForEach(group.approaches) { approach in
                        Button {
                            selection = .train(approach.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Circle().fill(TrainColors.color(approach.position.delay.tone)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(TrainBoard.approachText(approach, now: board.now))
                                        .font(.subheadline)
                                        .monospacedDigit()
                                    Text("\(approach.position.destination)行 \(approach.position.trainType)・\(approach.position.delay.label)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct TrainLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("線の色(運行状況)").font(.caption.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { lineEntries }
                VStack(alignment: .leading, spacing: 2) { lineEntries }
            }
            Text("線の縁取りは路線本来の色です。遅延・見合わせの路線は太く点滅します。")
            Text("電車の色(遅れ)").font(.caption.weight(.semibold)).padding(.top, 2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { trainEntries }
                VStack(alignment: .leading, spacing: 2) { trainEntries }
            }
            Text("丸は各停、四角は各停以外(文字は種別)。矢印は進行方向です。位置は時刻表から計算した目安で、リアルタイムの在線位置ではありません。")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var lineEntries: some View {
        entry("平常", .green, isLine: true)
        entry("遅延", .yellow, isLine: true)
        entry("見合わせ・運休", .red, isLine: true)
        entry("不明", .gray, isLine: true)
    }

    @ViewBuilder
    private var trainEntries: some View {
        entry("時刻どおり", TrainColors.color(.onTime), isLine: false)
        entry("遅れあり", TrainColors.color(.delayed), isLine: false)
        entry("不明", TrainColors.color(.unknown), isLine: false)
    }

    private func entry(_ label: String, _ color: Color, isLine: Bool) -> some View {
        HStack(spacing: 4) {
            if isLine {
                Capsule().fill(color).frame(width: 16, height: 5)
            } else {
                Circle().fill(color).frame(width: 10, height: 10)
            }
            Text(label)
        }
    }
}

/// 時刻表の保存と、遅れの取得の状態
struct TrainLiveStatusView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let live = env.live
        let needed = env.trains.neededRailways
        let missing = needed.filter { live.schedules[$0.railwayID] == nil }
        VStack(alignment: .leading, spacing: 4) {
            if !live.downloadingSchedules.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("列車ごとの時刻表を保存中(\(live.downloadingSchedules.count)路線)")
                }
            } else if !missing.isEmpty {
                Text("列車ごとの時刻表が未保存の路線が\(missing.count)つあります。Wi-Fi接続中は自動で保存します(1路線あたり約100〜220KBの通信)。")
                    .fixedSize(horizontal: false, vertical: true)
                Button("時刻表を取得") {
                    Task { await live.ensureSchedules(manual: true) }
                }
                .buttonStyle(.bordered)
            }
            if let error = live.scheduleError ?? live.delayError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            Text(delayText(live: live, needed: needed.map(\.railwayID)))
                .fixedSize(horizontal: false, vertical: true)
            if let note = live.autoFetchNote {
                Label(note, systemImage: "wifi.exclamationmark")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func delayText(live: TrainLiveStore, needed: [String]) -> String {
        guard let last = live.lastDelayFetch else { return "列車の遅れ: 未取得" }
        let unsupported = needed.filter { live.delaySupport[$0] == false }
        var text = "列車の遅れ: \(Formatters.age(of: last))に取得"
        if !unsupported.isEmpty {
            let names = unsupported.map { id in env.trains.lines.first { $0.railwayID == id }?.railwayName ?? ODPTID.tail(id) }
            text += "。\(names.joined(separator: "、"))は列車ごとの遅れが提供されていないため、運行情報で路線全体の状況を表示します"
        }
        return text
    }
}

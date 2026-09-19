import CoreLocation
import SwiftUI
import UIKit

struct TrainView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var selection: TrainMapSelection?

    var body: some View {
        let store = env.trains
        let items = store.info?.value ?? []
        let sortedLines = TrainSummary.sorted(store.lines, items: items)
        NavigationStack {
            List {
                Section {
                    Label(TrainSummary.text(lines: store.lines, items: items), systemImage: "tram")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !store.neededRailways.isEmpty {
                        TrainMapView(selection: $selection)
                            .frame(height: 260)
                            .listRowInsets(EdgeInsets())
                        TrainMapLegend()
                        if let selection {
                            TrainSelectionDetail(selection: selection)
                        } else {
                            Text("路線や駅のピンをタップすると、詳しい情報を表示します。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                    }
                }

                Section("次の電車") {
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

                Section("運行情報(状況が悪い順)") {
                    if store.lines.isEmpty {
                        Text("路線が登録されていません").foregroundStyle(.secondary)
                    }
                    ForEach(sortedLines) { line in
                        TrainInfoRow(line: line, item: items.first { $0.railwayID == line.railwayID })
                    }
                    .onDelete { offsets in
                        store.removeLines(ids: offsets.map { sortedLines[$0].railwayID })
                    }
                    if !store.lines.isEmpty {
                        DataStatusView(fetchedAt: store.info?.fetchedAt, note: store.autoRefreshNote, error: store.infoError)
                    }
                }

                Section {
                    NavigationLink {
                        OperatorPickerView()
                    } label: {
                        Label("路線・駅を登録", systemImage: "plus.circle")
                    }
                } footer: {
                    ODPTAttributionView()
                }
            }
            .navigationTitle("電車")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    RefreshToolbarButton(isLoading: store.isLoadingInfo || store.isLoadingShapes) {
                        await store.refreshInfoManually()
                        await store.ensureShapes(manual: true)
                    }
                }
            }
            .task {
                await store.refreshInfoIfStale()
                await store.ensureShapes(manual: false)
            }
        }
    }
}

enum TrainMapSelection: Equatable {
    case line(String)
    case station(String)
}

/// 登録した路線を線で、登録した駅をピンで描く。線の色は運行状況、縁取りは路線本来の色。
struct TrainMapView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: TrainMapSelection?

    var body: some View {
        let store = env.trains
        let items = store.info?.value ?? []
        let shapes = store.neededRailways.compactMap { store.shapes[$0.railwayID] }.filter(\.isDrawable)
        let lines = shapes.map { shape -> MapLine in
            let isInfoLine = store.lines.contains { $0.railwayID == shape.railwayID }
            let status = isInfoLine ? items.first(where: { $0.railwayID == shape.railwayID })?.status : nil
            return MapLine(
                id: shape.railwayID,
                coordinates: shape.stops.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                color: TrainMapBuilder.uiColor(status),
                casingColor: UIColor(hex: shape.colorHex),
                isEmphasized: status == .delay || status == .suspended
            )
        }
        let markers = TrainMapBuilder.markers(stations: store.stations, shapes: store.shapes)
        ZStack {
            MapContainerView(
                isInteractive: true,
                showsUserLocation: true,
                lines: lines,
                markers: markers,
                fitKey: (shapes.map(\.railwayID) + markers.map(\.id)).joined(separator: ","),
                onSelectLine: { selection = .line($0) },
                onSelectMarker: { selection = .station($0) }
            )
            if shapes.isEmpty {
                Text(store.isLoadingShapes ? "路線の形を取得中" : "路線の形は未取得です。右上の更新ボタンで取得します。")
                    .font(.footnote)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
    }

}

enum TrainMapBuilder {
    /// 平常=緑、遅延=黄、見合わせ・運休=赤、不明=グレー
    static func uiColor(_ status: TrainStatus?) -> UIColor {
        switch status {
        case .normal?: return .systemGreen
        case .delay?: return .systemYellow
        case .suspended?: return .systemRed
        case .other?: return .systemBlue
        case nil: return .systemGray
        }
    }

    /// 同じ駅を複数の方面で登録していても、ピンは1つにする
    static func markers(stations: [RegisteredStation], shapes: [String: RailwayShape]) -> [MapMarker] {
        var seen = Set<String>()
        return stations.compactMap { station -> MapMarker? in
            guard seen.insert(station.stationID).inserted,
                  let stop = shapes[station.railwayID]?.stops.first(where: { $0.stationID == station.stationID }) else { return nil }
            return MapMarker(id: station.stationID, title: station.stationName,
                             coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude))
        }
    }
}

struct TrainMapLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { entries }
            VStack(alignment: .leading, spacing: 2) { entries }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var entries: some View {
        entry("平常", .green)
        entry("遅延", .yellow)
        entry("見合わせ・運休", .red)
        entry("不明", .gray)
        Text("縁取り=路線の色")
    }

    private func entry(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 16, height: 5)
            Text(label)
        }
    }
}

/// 地図でタップした路線・駅の詳しい情報
struct TrainSelectionDetail: View {
    @Environment(AppEnvironment.self) private var env
    let selection: TrainMapSelection

    var body: some View {
        let store = env.trains
        let items = store.info?.value ?? []
        VStack(alignment: .leading, spacing: 8) {
            switch selection {
            case .line(let railwayID):
                if let line = store.lines.first(where: { $0.railwayID == railwayID }) {
                    TrainInfoRow(line: line, item: items.first { $0.railwayID == railwayID })
                    if items.first(where: { $0.railwayID == railwayID })?.text == nil {
                        Text("運行情報の本文はありません").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("この路線は運行情報を登録していません。").font(.footnote).foregroundStyle(.secondary)
                }
            case .station(let stationID):
                let registered = store.stations.filter { $0.stationID == stationID }
                ForEach(registered) { station in
                    NextTrainRow(station: station)
                }
                if let railwayID = registered.first?.railwayID,
                   let line = store.lines.first(where: { $0.railwayID == railwayID }) {
                    Divider()
                    TrainInfoRow(line: line, item: items.first { $0.railwayID == railwayID })
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ODPTAttributionView: View {
    var body: some View {
        Text("""
        本アプリケーション等が利用する公共交通データは、公共交通オープンデータセンターにおいて提供されるものです。\
        公共交通事業者により提供されたデータを元にしていますが、必ずしも正確・完全なものとは限りません。\
        本アプリケーションの表示内容について、公共交通事業者への直接の問合せは行わないでください。
        都営のデータ: 東京都交通局・公共交通オープンデータ協議会 (CC BY 4.0)
        """)
    }
}

struct TrainInfoRow: View {
    let line: RegisteredLine
    let item: TrainInfoItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrainStatusLine(name: line.railwayName, item: item, nameFont: .title3.weight(.bold))
            if let text = item?.text {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    static func color(_ status: TrainStatus?) -> Color {
        guard let status else { return .gray }
        return color(status)
    }

    static func color(_ status: TrainStatus) -> Color {
        switch status {
        case .normal: return .green
        case .delay: return .orange
        case .suspended: return .red
        case .other: return .blue
        }
    }
}

/// 路線名と運行状況。1行に入りきらない幅や文字サイズでは2段にする(省略しない)。
struct TrainStatusLine: View {
    let name: String
    let item: TrainInfoItem?
    var nameFont: Font = .headline

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                nameText
                Spacer(minLength: 8)
                statusView
            }
            VStack(alignment: .leading, spacing: 2) {
                nameText
                statusView
            }
        }
    }

    private var nameText: some View {
        Text(name)
            .font(nameFont)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var statusView: some View {
        if let item {
            Label(item.statusText ?? item.status.label, systemImage: item.status.symbol)
                .font(.headline)
                .foregroundStyle(TrainInfoRow.color(item.status))
        } else {
            Text("未取得").foregroundStyle(.secondary)
        }
    }
}

/// 「今日のダイヤ」の手動切り替え。その日だけ有効で、翌日には自動に戻る。
struct TodayTimetablePicker: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        let resolver = settings.dayTypeResolver
        let isManual = resolver.isOverridden(on: Date())
        var automatic = resolver
        automatic.overrideType = nil
        let automaticLabel = NextTrainRow.dayTypeLabel(automatic.dayType(of: Date()))
        return VStack(alignment: .leading, spacing: 4) {
            Picker("今日のダイヤ", selection: Binding<String>(
                get: { isManual ? (resolver.overrideType == .weekday ? "weekday" : "holiday") : "auto" },
                set: { value in
                    switch value {
                    case "weekday": settings.setTimetableOverride(.weekday)
                    case "holiday": settings.setTimetableOverride(.holiday)
                    default: settings.setTimetableOverride(nil)
                    }
                }
            )) {
                Text("自動").tag("auto")
                Text("平日").tag("weekday")
                Text("土休日").tag("holiday")
            }
            .pickerStyle(.segmented)
            Text(isManual ? "今日だけ手動で切り替えています。明日には自動に戻ります。" : "今日のダイヤ(自動): \(automaticLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 保存した時刻表から「あと◯分◯秒」を表示する。通信はしない。
struct NextTrainRow: View {
    @Environment(AppEnvironment.self) private var env
    let station: RegisteredStation

    var body: some View {
        let store = env.trains
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(station.stationName).font(.title3.weight(.bold))
                    Text("\(station.railwayName)・\(station.directionName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.downloadingTimetables.contains(station.id) {
                    ProgressView()
                } else {
                    Button {
                        Task { await store.downloadTimetable(for: station) }
                    } label: {
                        Image(systemName: store.timetables[station.id] == nil ? "arrow.down.circle" : "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let timetable = store.timetables[station.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let upcoming = TimetableCalculator.upcoming(in: timetable, now: context.date, count: 2,
                                                                resolver: env.settings.dayTypeResolver)
                    if let next = upcoming.first {
                        BigValue(value: Self.countdown(to: next.date, now: context.date), size: 44)
                        Text(Self.describe(next))
                            .font(.subheadline.weight(.semibold))
                        if upcoming.count > 1 {
                            Text("その次: \(Self.describe(upcoming[1]))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("該当する列車がありません").foregroundStyle(.secondary)
                    }
                }
                Text("時刻表: \(Formatters.dateTime.string(from: timetable.downloadedAt)) に保存\(timetable.issued.map { "(\($0) 改正)" } ?? "")・\(Self.dayTypeLabel(env.settings.dayTypeResolver.dayType(of: Date())))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("時刻表は未ダウンロードです。右のボタンで一度だけ取得します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        if seconds >= 3600 { return "あと\(seconds / 3600)時間\((seconds % 3600) / 60)分" }
        return "あと\(seconds / 60)分\(String(format: "%02d", seconds % 60))秒"
    }

    static func describe(_ upcoming: UpcomingDeparture) -> String {
        let f = DateFormatter()
        f.calendar = JapaneseHolidays.calendar
        f.timeZone = JapaneseHolidays.calendar.timeZone
        f.dateFormat = "H:mm"
        var parts = [f.string(from: upcoming.date) + "発"]
        if let type = upcoming.departure.trainType { parts.append(type) }
        if let destination = upcoming.departure.destination { parts.append("\(destination)行") }
        if upcoming.departure.isLast { parts.append("最終") }
        return parts.joined(separator: " ")
    }

    static func dayTypeLabel(_ type: DayType) -> String {
        switch type {
        case .weekday: return "平日ダイヤ"
        case .saturday: return "土曜ダイヤ"
        case .holiday: return "休日ダイヤ"
        }
    }
}

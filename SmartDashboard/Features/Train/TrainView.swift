import SwiftUI

struct TrainView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.trains
        NavigationStack {
            List {
                Section("次の電車") {
                    if store.stations.isEmpty {
                        Text("駅が登録されていません").foregroundStyle(.secondary)
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

                Section("運行情報") {
                    if store.lines.isEmpty {
                        Text("路線が登録されていません").foregroundStyle(.secondary)
                    }
                    ForEach(store.lines) { line in
                        TrainInfoRow(line: line, item: store.info?.value.first { $0.railwayID == line.railwayID })
                    }
                    .onDelete { store.removeLines(at: $0) }
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
                    RefreshToolbarButton(isLoading: store.isLoadingInfo) { await store.refreshInfoManually() }
                }
            }
            .task { await store.refreshInfoIfStale() }
        }
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
                    let upcoming = TimetableCalculator.upcoming(in: timetable, now: context.date, count: 2)
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
                Text("時刻表: \(Formatters.dateTime.string(from: timetable.downloadedAt)) に保存\(timetable.issued.map { "(\($0) 改正)" } ?? "")・\(Self.dayTypeLabel(JapaneseHolidays.dayType(of: Date())))")
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

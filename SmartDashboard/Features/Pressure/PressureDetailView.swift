import Charts
import SwiftUI

/// 詳細画面の表示の幅
enum PressureSpan: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "1日"
        case .week: return "1週間"
        case .month: return "1か月"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }

    /// 間引きの間隔。1日表示は、表示中の付近だけ5分ごと(それ以外は1時間ごと)にする。
    var step: TimeInterval {
        switch self {
        case .day: return 5 * 60
        case .week: return 30 * 60
        case .month: return 3600
        }
    }
}

/// 表示用のデータの組み立て(View の外に置いてテストできるようにする)
enum PressureDetailData {
    static let past: TimeInterval = 100 * 24 * 3600
    static let future: TimeInterval = 7 * 24 * 3600

    /// 表示する点。1日表示では、center の前後 1.5 日だけを細かくし、それ以外は1時間ごとにする。
    static func displayed(full: [PressurePoint], hourly: [PressurePoint], span: PressureSpan, center: Date) -> [PressurePoint] {
        switch span {
        case .month:
            return hourly
        case .week:
            return PressureThinning.thin(full, step: span.step)
        case .day:
            let from = center.addingTimeInterval(-1.5 * span.seconds)
            let to = center.addingTimeInterval(1.5 * span.seconds)
            let fine = full.filter { $0.time >= from && $0.time <= to }
            guard let first = fine.first, let last = fine.last else { return hourly }
            return hourly.filter { $0.time < first.time } + fine + hourly.filter { $0.time > last.time }
        }
    }

    /// 開いたときのスクロール位置(表示の左端)。「今」が画面の右寄り(左から75%)に来るようにする。
    static func initialScroll(now: Date, span: PressureSpan) -> Date {
        now.addingTimeInterval(-0.75 * span.seconds)
    }

    /// 表示の幅を切り替えたときに、画面の中央の時刻を保つ
    static func scroll(keepingCenterOf current: Date, from old: PressureSpan, to new: PressureSpan) -> Date {
        current.addingTimeInterval(old.seconds / 2 - new.seconds / 2)
    }

    /// 日付の区切り(日本時間の0時)
    static func dayStarts(from: Date, to: Date) -> [Date] {
        let calendar = JapaneseHolidays.calendar
        var result: [Date] = []
        var day = calendar.startOfDay(for: from)
        while day <= to {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// 日付のラベルを付ける日。1か月表示では月曜と1日だけ。
    static func labeledDays(_ days: [Date], span: PressureSpan) -> [Date] {
        guard span == .month else { return days }
        let calendar = JapaneseHolidays.calendar
        return days.filter { calendar.component(.weekday, from: $0) == 2 || calendar.component(.day, from: $0) == 1 }
    }

    static func fiveSteps(in domain: ClosedRange<Double>) -> [Double] {
        Array(stride(from: (domain.lowerBound / 5).rounded(.up) * 5, through: domain.upperBound, by: 5))
    }

    static func yDomain(_ points: [PressurePoint]) -> ClosedRange<Double> {
        guard let low = points.map(\.hPa).min(), let high = points.map(\.hPa).max() else { return 1000...1025 }
        return ((low / 5).rounded(.down) * 5)...((high / 5).rounded(.up) * 5 + 0.001)
    }
}

struct PressureDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var span: PressureSpan = .week
    @State private var scrollX = Date()
    @State private var selectedDate: Date?
    @State private var now = Date()
    @State private var full: [PressurePoint] = []
    @State private var hourly: [PressurePoint] = []
    @State private var displayed: [PressurePoint] = []
    @State private var drops: [DateInterval] = []
    @State private var correction = 0.0
    @State private var fineCenter = Date.distantPast
    @State private var didSetInitialScroll = false
    /// 保存容量(スクロールのたびに数え直さないよう、データが変わったときだけ求める)
    @State private var storage: (history: Int64, measured: Int64) = (0, 0)

    var body: some View {
        List {
            Section {
                Picker("表示の幅", selection: $span) {
                    ForEach(PressureSpan.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if displayed.count > 1 {
                    chart
                        .frame(height: 280)
                    selectionText
                } else {
                    Text("気圧のデータがまだありません").foregroundStyle(.secondary)
                }
            } footer: {
                Text("実線は過去、点線は予報です。薄いオレンジは、3時間で\(String(format: "%.1f", env.settings.pressureAlertDrop))hPa以上下がっている時間帯、緑の線は標準気圧(1013hPa)です。長押ししてなぞると、その時刻の値を表示します。")
            }
            backfillSection
            statsSection
            Section {
                LabeledContent("予報モデルの履歴", value: Formatters.bytes(storage.history))
                LabeledContent("実測の記録", value: Formatters.bytes(storage.measured))
            } header: {
                Text("保存容量")
            } footer: {
                Text("実測がある時間帯は実測、それ以外は予報モデルの値(Open-Meteo)です。どちらも100日分を保存し、古いものは削除します。気象データ: Open-Meteo.com (CC BY 4.0)")
            }
        }
        .navigationTitle("気圧の変化")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            rebuild()
            guard let snapshot = env.weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
            await env.pressureHistory.backfillIfNeeded(latitude: latitude, longitude: longitude)
            await env.pressureHistory.refreshOutlookIfStale(latitude: latitude, longitude: longitude)
        }
        .onChange(of: env.pressureHistory.history) { _, _ in rebuild() }
        .onChange(of: env.pressure.samples.count) { _, _ in rebuild() }
        .onChange(of: env.settings.pressureAlertDrop) { _, _ in rebuild() }
        .onChange(of: span) { old, new in
            scrollX = PressureDetailData.scroll(keepingCenterOf: scrollX, from: old, to: new)
            updateDisplayed(force: true)
        }
        .onChange(of: scrollX) { _, _ in updateDisplayed(force: false) }
    }

    /// 100日分の系列を作り直す(データが変わったときだけ)
    private func rebuild() {
        now = Date()
        let series = PressureSeries.make(measured: env.pressure.samples, forecast: env.pressureHistory.forecastPoints, now: now,
                                         past: PressureDetailData.past, future: PressureDetailData.future)
        full = series.points
        correction = series.correction
        hourly = PressureThinning.thin(full, step: 3600)
        drops = PressureAnalysis.dropIntervals(in: hourly, threshold: env.settings.pressureAlertDrop)
        if !didSetInitialScroll {
            didSetInitialScroll = true
            scrollX = PressureDetailData.initialScroll(now: now, span: span)
        }
        storage = (env.pressureHistory.storageBytes, env.pressure.storageBytes())
        updateDisplayed(force: true)
    }

    /// 1日表示では、表示位置が半日以上動いたときだけ、細かい区間を作り直す
    private func updateDisplayed(force: Bool) {
        let center = scrollX.addingTimeInterval(span.seconds / 2)
        if !force {
            guard span == .day, abs(center.timeIntervalSince(fineCenter)) > span.seconds / 2 else { return }
        }
        fineCenter = center
        displayed = PressureDetailData.displayed(full: full, hourly: hourly, span: span, center: center)
    }

    private var xDomain: ClosedRange<Date> {
        let start = displayed.first?.time ?? now.addingTimeInterval(-span.seconds)
        let end = max(displayed.last?.time ?? now, now.addingTimeInterval(span.seconds * 0.25))
        return start...end
    }

    private var chart: some View {
        let yDomain = PressureDetailData.yDomain(hourly)
        let days = PressureDetailData.dayStarts(from: xDomain.lowerBound, to: xDomain.upperBound)
        let labeled = PressureDetailData.labeledDays(days, span: span)
        let threeHours: [Date] = span == .day
            ? days.flatMap { day in (1..<8).map { day.addingTimeInterval(Double($0) * 3 * 3600) } }
            : []
        let pastPoints = displayed.filter { $0.time <= now }
        let junction: [PressurePoint] = pastPoints.last.map { [$0] } ?? []
        let futurePoints: [PressurePoint] = junction + displayed.filter { $0.time > now }
        return Chart {
            ForEach(drops, id: \.start) { interval in
                RectangleMark(xStart: .value("開始", interval.start), xEnd: .value("終了", interval.end))
                    .foregroundStyle(Color.orange.opacity(0.18))
            }
            if yDomain.contains(1013) {
                RuleMark(y: .value("標準気圧", 1013))
                    .foregroundStyle(Color.green.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(pastPoints) { point in
                LineMark(x: .value("時刻", point.time), y: .value("気圧", point.hPa), series: .value("区分", "過去"))
                    .foregroundStyle(Color.accentColor)
            }
            ForEach(futurePoints) { point in
                LineMark(x: .value("時刻", point.time), y: .value("気圧", point.hPa), series: .value("区分", "予報"))
                    .foregroundStyle(Color.accentColor.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
            RuleMark(x: .value("現在", now))
                .foregroundStyle(Color.red.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .center) {
                    Text("今").font(.caption2.weight(.bold)).foregroundStyle(.red)
                }
            if let selectedDate, let value = PressureAnalysis.value(in: displayed, at: selectedDate) {
                RuleMark(x: .value("選択", selectedDate)).foregroundStyle(Color.orange)
                PointMark(x: .value("選択", selectedDate), y: .value("気圧", value)).foregroundStyle(Color.orange)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: span.seconds)
        .chartScrollPosition(x: $scrollX)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: threeHours) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.3))
                AxisValueLabel(format: .dateTime.hour())
            }
            AxisMarks(values: days) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Self.dayColor(value.as(Date.self)).opacity(0.7))
            }
            AxisMarks(values: labeled) { value in
                AxisValueLabel(anchor: .topLeading) {
                    Text(Self.dayLabel(value.as(Date.self)))
                        .font(.caption2)
                        .foregroundStyle(Self.dayColor(value.as(Date.self)))
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: PressureDetailData.fiveSteps(in: yDomain)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.4))
                AxisValueLabel()
            }
        }
    }

    /// 土曜は青、日曜と祝日は赤、平日はグレー
    private static func dayColor(_ date: Date?) -> Color {
        guard let date else { return .secondary }
        switch JapaneseHolidays.dayType(of: date) {
        case .holiday: return .red
        case .saturday: return .blue
        default: return .secondary
        }
    }

    private static func dayLabel(_ date: Date?) -> String {
        date.map(dayFormatter.string(from:)) ?? ""
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    private static let momentFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E) HH:mm"
        return formatter
    }()

    @ViewBuilder
    private var selectionText: some View {
        if let selectedDate, let value = PressureAnalysis.value(in: displayed, at: selectedDate),
           let nearest = PressureAnalysis.nearest(in: displayed, to: selectedDate) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.momentFormatter.string(from: selectedDate))　\(String(format: "%.1f", value)) hPa・\(nearest.source == .measured ? "実測" : (selectedDate > now ? "予報" : "予報モデルの値"))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let change = PressureAnalysis.change(in: hourly, at: selectedDate) {
                    Text("前3時間の変化：\(String(format: "%+.1f", change).replacingOccurrences(of: "-", with: "−"))hPa")
                        .font(.footnote)
                        .foregroundStyle(change <= -env.settings.pressureAlertDrop ? Color.orange : Color.secondary)
                }
                if nearest.source == .forecast, abs(correction) >= 0.05 {
                    Text("予報モデルの値は、実測とつながるように \(String(format: "%+.1f", correction)) hPa 補正しています")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("グラフを長押ししてなぞると、その時刻の気圧、実測か予報か、前3時間の変化を表示します")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var backfillSection: some View {
        let store = env.pressureHistory
        if store.needsBackfill(now: now) || store.isLoading || store.errorMessage != nil {
            Section {
                if store.isLoading {
                    HStack {
                        ProgressView()
                        Text("取得中…").foregroundStyle(.secondary)
                    }
                } else if store.needsBackfill(now: now) {
                    Text("過去の気圧(約100日分)は未取得です。Wi-Fi接続中は自動で取得します。モバイル通信では、下のボタンで取得できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("過去の気圧を取得する(約10KB)") {
                        guard let snapshot = env.weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
                        Task { await store.backfillIfNeeded(latitude: latitude, longitude: longitude, manual: true) }
                    }
                    .disabled(env.weather.cached?.value.latitude == nil)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var statsSection: some View {
        let from = scrollX
        let to = scrollX.addingTimeInterval(span.seconds)
        if let stats = PressureStats.make(hourly, from: from, to: to, calendar: JapaneseHolidays.calendar) {
            Section("表示中の期間") {
                ViewThatFits {
                    HStack { statValues(stats) }
                    VStack(alignment: .leading, spacing: 6) { statValues(stats) }
                }
            }
            Section("1日ごとの最高・最低") {
                ForEach(stats.days) { day in
                    HStack {
                        Text(Self.dayLabel(day.date)).foregroundStyle(Self.dayColor(day.date) == .secondary ? Color.primary : Self.dayColor(day.date))
                        Spacer(minLength: 8)
                        Text("\(String(format: "%.1f", day.high)) / \(String(format: "%.1f", day.low)) hPa")
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statValues(_ stats: PressureStats) -> some View {
        statValue("最高", stats.high)
        statValue("最低", stats.low)
        statValue("平均", stats.mean)
    }

    private func statValue(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.1f", value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

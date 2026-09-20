import SwiftUI

/// 詳細画面の表示の幅
enum PressureSpan: String, CaseIterable, Identifiable {
    case day
    case week
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "1日"
        case .week: return "1週間"
        case .all: return "全体"
        }
    }

    /// 画面に収める時間の長さ。「全体」は表示する範囲のすべて。
    var seconds: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .all: return Double(PressureDetailData.rangeDays) * 24 * 3600
        }
    }
}

/// グラフの1区画。1日・1週間表示では1日ごと、全体表示では全体で1つ。
/// 区画ごとに1枚の Canvas で描き、スクロール中は描き直さない。
struct PressureTile: Equatable, Identifiable {
    var id: Int
    var start: Date
    var end: Date
    /// 区画に含まれる日付の区切り(日本時間の0時)
    var days: [Date]
    /// 線を描く点。区画の外の点を前後に1つずつ含める(隣の区画と線をつなげるため)
    var points: [PressurePoint]
    /// 急な低下の時間帯(区画の範囲に切り取ったもの)
    var drops: [DateInterval]
}

/// 表示用のデータの組み立て(View の外に置いてテストできるようにする)
enum PressureDetailData {
    /// 過去は直近4日分、予報は16日先(Open-Meteo の上限)まで
    static let past: TimeInterval = 4 * 24 * 3600
    static let future: TimeInterval = 16 * 24 * 3600
    /// 表示する範囲の日数(4日前の0時〜16日後の24時)
    static let rangeDays = 21
    /// 開いたときに「今」を置く位置(左から25%)。右にスクロールすると先の予報が見られる。
    static let nowPosition = 0.25

    /// 表示する範囲。日付の区切りにそろえる。
    static func range(now: Date) -> DateInterval {
        let start = JapaneseHolidays.calendar.startOfDay(for: now.addingTimeInterval(-past))
        return DateInterval(start: start, duration: Double(rangeDays) * 24 * 3600)
    }

    /// 日付の区切り(日本時間の0時)。to は含めない。
    static func dayStarts(from: Date, to: Date) -> [Date] {
        let calendar = JapaneseHolidays.calendar
        var result: [Date] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// 区画を作る。点は1時間ごとを基本にし、1日表示のときだけ、その日の区画に細かい点(実測は5分ごと)を入れる。
    /// 区画は画面に入るものだけが作られる(LazyHStack)ので、細かい点を描くのは表示中の付近だけになる。
    static func tiles(full: [PressurePoint], hourly: [PressurePoint], drops: [DateInterval], span: PressureSpan, now: Date) -> [PressureTile] {
        let range = range(now: now)
        let days = dayStarts(from: range.start, to: range.end)
        if span == .all {
            return [PressureTile(id: 0, start: range.start, end: range.end, days: days,
                                 points: slice(hourly, from: range.start, to: range.end), drops: clip(drops, from: range.start, to: range.end))]
        }
        let source = span == .day ? full : hourly
        return days.enumerated().map { index, day in
            let end = index + 1 < days.count ? days[index + 1] : range.end
            return PressureTile(id: index, start: day, end: end, days: [day],
                                points: slice(source, from: day, to: end), drops: clip(drops, from: day, to: end))
        }
    }

    /// [from, to] の点と、その前後の1点ずつ。points は時刻の昇順。範囲に点がなければ空。
    static func slice(_ points: [PressurePoint], from: Date, to: Date) -> [PressurePoint] {
        guard let first = points.firstIndex(where: { $0.time >= from }),
              let last = points.lastIndex(where: { $0.time <= to }), first <= last else { return [] }
        return Array(points[max(first - 1, 0)...min(last + 1, points.count - 1)])
    }

    static func clip(_ intervals: [DateInterval], from: Date, to: Date) -> [DateInterval] {
        intervals.compactMap { interval in
            let start = max(interval.start, from)
            let end = min(interval.end, to)
            return start < end ? DateInterval(start: start, end: end) : nil
        }
    }

    /// 日付のラベルを付けるか。全体表示では込み合うので、月曜と木曜だけ。
    static func showsLabel(_ day: Date, span: PressureSpan) -> Bool {
        guard span == .all else { return true }
        return [2, 5].contains(JapaneseHolidays.calendar.component(.weekday, from: day))
    }

    /// 日付のラベル。1日ぶんの幅に収まる長さにする(区画の外にはみ出すと切れるため)。
    /// 1日表示は「9/20(土)」、1週間表示は「20(土)」(月の初日だけ「10/1(木)」)、全体表示は「9/21」。
    static func dayLabel(_ day: Date, span: PressureSpan) -> String {
        let calendar = JapaneseHolidays.calendar
        let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
        let month = parts.month ?? 0
        let dayOfMonth = parts.day ?? 0
        let weekday = ["日", "月", "火", "水", "木", "金", "土"][max(min((parts.weekday ?? 1) - 1, 6), 0)]
        switch span {
        case .day: return "\(month)/\(dayOfMonth)(\(weekday))"
        case .week: return dayOfMonth == 1 ? "\(month)/\(dayOfMonth)(\(weekday))" : "\(dayOfMonth)(\(weekday))"
        case .all: return "\(month)/\(dayOfMonth)"
        }
    }

    static func fiveSteps(in domain: ClosedRange<Double>) -> [Double] {
        Array(stride(from: (domain.lowerBound / 5).rounded(.up) * 5, through: domain.upperBound, by: 5))
    }

    static func yDomain(_ points: [PressurePoint]) -> ClosedRange<Double> {
        guard let low = points.map(\.hPa).min(), let high = points.map(\.hPa).max() else { return 1000...1025 }
        return ((low / 5).rounded(.down) * 5)...((high / 5).rounded(.up) * 5 + 0.001)
    }

    /// 画面の幅と表示の幅から、グラフ全体の幅を求める
    static func contentWidth(viewWidth: CGFloat, span: PressureSpan) -> CGFloat {
        viewWidth * CGFloat(Double(rangeDays) * 24 * 3600 / span.seconds)
    }

    /// グラフ全体の中での横の位置
    static func x(of time: Date, in range: DateInterval, contentWidth: CGFloat) -> CGFloat {
        CGFloat(time.timeIntervalSince(range.start) / range.duration) * contentWidth
    }

    static func time(atX x: CGFloat, in range: DateInterval, contentWidth: CGFloat) -> Date {
        range.start.addingTimeInterval(Double(x / max(contentWidth, 1)) * range.duration)
    }
}

/// グラフの描画に使う寸法と色
enum PressureChartStyle {
    static let height: CGFloat = 280
    static let plotTop: CGFloat = 20
    static let plotBottom: CGFloat = height - 18
    static let axisWidth: CGFloat = 36

    static func y(_ hPa: Double, in domain: ClosedRange<Double>) -> CGFloat {
        let ratio = (hPa - domain.lowerBound) / max(domain.upperBound - domain.lowerBound, 0.001)
        return plotBottom - CGFloat(ratio) * (plotBottom - plotTop)
    }

    /// 土曜は青、日曜と祝日は赤、平日はグレー
    static func dayColor(_ date: Date) -> Color {
        switch JapaneseHolidays.dayType(of: date) {
        case .holiday: return .red
        case .saturday: return .blue
        default: return .secondary
        }
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()
}

/// 1区画を1枚の Canvas で描く。背景(急な低下の塗り、横線、日付と3時間ごとの縦線、ラベル)と、線(過去は実線、未来は点線)。
/// 入力が同じなら描き直さない(Equatable)。スクロール中は、描いた結果が動くだけになる。
struct PressureTileView: View, Equatable {
    let tile: PressureTile
    let span: PressureSpan
    let yDomain: ClosedRange<Double>
    let now: Date
    let width: CGFloat

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(&context, size: size)
        }
        .frame(width: width, height: PressureChartStyle.height)
    }

    private func x(_ time: Date, _ size: CGSize) -> CGFloat {
        CGFloat(time.timeIntervalSince(tile.start) / max(tile.end.timeIntervalSince(tile.start), 1)) * size.width
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let top = PressureChartStyle.plotTop
        let bottom = PressureChartStyle.plotBottom
        // 急な低下の時間帯
        for drop in tile.drops {
            let rect = CGRect(x: x(drop.start, size), y: top, width: x(drop.end, size) - x(drop.start, size), height: bottom - top)
            context.fill(Path(rect), with: .color(Color.orange.opacity(0.18)))
        }
        // 5hPaごとの横線と、標準気圧
        var horizontal = Path()
        for value in PressureDetailData.fiveSteps(in: yDomain) {
            let y = PressureChartStyle.y(value, in: yDomain)
            horizontal.move(to: CGPoint(x: 0, y: y))
            horizontal.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(horizontal, with: .color(Color.secondary.opacity(0.35)), lineWidth: 0.5)
        if yDomain.contains(1013) {
            let y = PressureChartStyle.y(1013, in: yDomain)
            var standard = Path()
            standard.move(to: CGPoint(x: 0, y: y))
            standard.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(standard, with: .color(Color.green.opacity(0.8)), lineWidth: 1.5)
        }
        // 日付の区切りとラベル。1日表示では3時間ごとの細い線と時刻も描く
        for day in tile.days {
            let dayX = x(day, size)
            let color = PressureChartStyle.dayColor(day)
            var line = Path()
            line.move(to: CGPoint(x: dayX, y: 0))
            line.addLine(to: CGPoint(x: dayX, y: bottom))
            context.stroke(line, with: .color(color.opacity(0.7)), lineWidth: 1)
            if PressureDetailData.showsLabel(day, span: span) {
                let label = Text(PressureDetailData.dayLabel(day, span: span)).font(.system(size: 10)).foregroundColor(color)
                context.draw(label, at: CGPoint(x: dayX + 3, y: 2), anchor: .topLeading)
            }
            if span == .day {
                var hours = Path()
                for hour in stride(from: 3, to: 24, by: 3) {
                    let hourX = x(day.addingTimeInterval(Double(hour) * 3600), size)
                    hours.move(to: CGPoint(x: hourX, y: top))
                    hours.addLine(to: CGPoint(x: hourX, y: bottom))
                    let label = Text("\(hour)時").font(.system(size: 10)).foregroundColor(.secondary)
                    context.draw(label, at: CGPoint(x: hourX, y: bottom + 2), anchor: .top)
                }
                context.stroke(hours, with: .color(Color.secondary.opacity(0.3)), lineWidth: 0.5)
            }
        }
        // 線は2本だけ。過去は実線、未来(予報)は少し薄い点線
        var pastLine = Path()
        var futureLine = Path()
        var previous: CGPoint?
        for point in tile.points {
            let position = CGPoint(x: x(point.time, size), y: PressureChartStyle.y(point.hPa, in: yDomain))
            if point.time <= now {
                if pastLine.isEmpty { pastLine.move(to: position) } else { pastLine.addLine(to: position) }
            } else {
                // 未来の線は、過去の最後の点からつなげる
                if futureLine.isEmpty { futureLine.move(to: previous ?? position) }
                futureLine.addLine(to: position)
            }
            previous = position
        }
        context.stroke(pastLine, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        context.stroke(futureLine, with: .color(Color.accentColor.opacity(0.65)), style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [5, 4]))
        // 「今」の縦線
        if now >= tile.start && now < tile.end {
            let nowX = x(now, size)
            var line = Path()
            line.move(to: CGPoint(x: nowX, y: top - 6))
            line.addLine(to: CGPoint(x: nowX, y: bottom))
            context.stroke(line, with: .color(Color.red.opacity(0.75)), lineWidth: 1.5)
            context.draw(Text("今").font(.system(size: 10, weight: .bold)).foregroundColor(.red), at: CGPoint(x: nowX + 3, y: top - 7), anchor: .topLeading)
        }
    }
}

/// 縦軸の目盛り(hPa)。スクロールしても左端に固定する。
struct PressureYAxisView: View, Equatable {
    let yDomain: ClosedRange<Double>

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let top = PressureChartStyle.plotTop - 8
            let rect = CGRect(x: 0, y: top, width: size.width, height: PressureChartStyle.plotBottom - top + 8)
            context.fill(Path(rect), with: .color(Color(.secondarySystemGroupedBackground).opacity(0.85)))
            for value in PressureDetailData.fiveSteps(in: yDomain) {
                let label = Text(String(format: "%.0f", value)).font(.system(size: 10)).foregroundColor(.secondary)
                context.draw(label, at: CGPoint(x: size.width - 3, y: PressureChartStyle.y(value, in: yDomain)), anchor: .trailing)
            }
        }
        .frame(width: PressureChartStyle.axisWidth, height: PressureChartStyle.height)
        .allowsHitTesting(false)
    }
}

/// スクロール位置の記録。スクロール中は View の状態を変えず(body を再評価させない)、止まってから一度だけ知らせる。
@MainActor
final class PressureScrollTracker {
    private var task: Task<Void, Never>?
    var onSettle: ((CGFloat) -> Void)?

    func update(_ offset: CGFloat) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.onSettle?(offset)
        }
    }
}

private struct PressureScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PressureDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var span: PressureSpan = .week
    @State private var selectedDate: Date?
    @State private var now = Date()
    @State private var full: [PressurePoint] = []
    @State private var hourly: [PressurePoint] = []
    @State private var drops: [DateInterval] = []
    @State private var tiles: [PressureTile] = []
    @State private var yDomain: ClosedRange<Double> = 1000...1025
    @State private var correction = 0.0
    /// 集計に使う「表示中の期間」の左端。スクロールが止まってから更新する。
    @State private var visibleStart = Date()
    @State private var viewWidth: CGFloat = 0
    @State private var tracker = PressureScrollTracker()
    /// 保存容量(データが変わったときだけ求める)
    @State private var storage: (history: Int64, measured: Int64) = (0, 0)

    private static let scrollSpace = "pressureScroll"
    private static let nowAnchor = "pressureNow"

    var body: some View {
        List {
            Section {
                Picker("表示の幅", selection: $span) {
                    ForEach(PressureSpan.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if hourly.count > 1 {
                    graph
                        .frame(height: PressureChartStyle.height)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    // グラフの外(この行や下の一覧)をタップしたら、表示中の値を消す
                    selectionText
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedDate = nil }
                } else {
                    Text("気圧のデータがまだありません").foregroundStyle(.secondary)
                }
            } footer: {
                Text("実線は過去、点線は予報です。薄いオレンジは、3時間で\(String(format: "%.1f", env.settings.pressureAlertDrop))hPa以上下がっている時間帯、緑の線は標準気圧(1013hPa)です。グラフをタップすると、その時刻の値を表示します。")
            }
            statusSection
            statsSection
            Section {
                LabeledContent("予報モデルの値", value: Formatters.bytes(storage.history))
                LabeledContent("実測の記録", value: Formatters.bytes(storage.measured))
            } header: {
                Text("保存容量")
            } footer: {
                Text("実測がある時間帯は実測、それ以外は予報モデルの値(Open-Meteo)です。過去は直近4日分を表示し、どちらも7日分を保存して、古いものは削除します。予報は16日先までで、この画面を開いたときだけ取得します(最短3時間ごと)。気象データ: Open-Meteo.com (CC BY 4.0)")
            }
        }
        .navigationTitle("気圧の変化")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            tracker.onSettle = { offset in settle(offset) }
            rebuild()
            guard let snapshot = env.weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
            await env.pressureHistory.refreshOutlookIfStale(latitude: latitude, longitude: longitude)
        }
        .onChange(of: env.pressureHistory.history) { _, _ in rebuild() }
        .onChange(of: env.pressure.samples.count) { _, _ in rebuild() }
        .onChange(of: env.settings.pressureAlertDrop) { _, _ in rebuild() }
    }

    /// 描画に使うデータを作る。データか表示の幅が変わったときだけ呼ぶ(スクロール中には呼ばない)。
    private func rebuild() {
        now = Date()
        let series = PressureSeries.make(measured: env.pressure.samples, forecast: env.pressureHistory.forecastPoints, now: now,
                                         past: PressureDetailData.past + 24 * 3600, future: PressureDetailData.future + 24 * 3600)
        let range = PressureDetailData.range(now: now)
        full = series.points.filter { $0.time >= range.start && $0.time <= range.end }
        correction = series.correction
        hourly = PressureThinning.thin(full, step: 3600)
        yDomain = PressureDetailData.yDomain(hourly)
        drops = PressureAnalysis.dropIntervals(in: hourly, threshold: env.settings.pressureAlertDrop)
        storage = (env.pressureHistory.storageBytes, env.pressure.storageBytes())
        rebuildTiles()
    }

    private func rebuildTiles() {
        tiles = PressureDetailData.tiles(full: full, hourly: hourly, drops: drops, span: span, now: now)
        visibleStart = now.addingTimeInterval(-PressureDetailData.nowPosition * span.seconds)
    }

    /// スクロールが止まったときに、集計の対象の期間を更新する
    private func settle(_ offset: CGFloat) {
        guard viewWidth > 0 else { return }
        let range = PressureDetailData.range(now: now)
        let start = PressureDetailData.time(atX: max(offset, 0), in: range,
                                            contentWidth: PressureDetailData.contentWidth(viewWidth: viewWidth, span: span))
        if abs(start.timeIntervalSince(visibleStart)) > 600 { visibleStart = start }
    }

    // MARK: - グラフ

    private var graph: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let contentWidth = PressureDetailData.contentWidth(viewWidth: width, span: span)
            let range = PressureDetailData.range(now: now)
            let tracker = self.tracker
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(tiles) { tile in
                            PressureTileView(tile: tile, span: span, yDomain: yDomain, now: now,
                                             width: contentWidth * CGFloat(tile.end.timeIntervalSince(tile.start) / range.duration))
                                .equatable()
                        }
                    }
                    .frame(width: contentWidth, height: PressureChartStyle.height, alignment: .leading)
                    .overlay(alignment: .topLeading) { selectionMarker(range: range, contentWidth: contentWidth) }
                    .overlay(alignment: .topLeading) {
                        // 開いたときに「今」を左から25%の位置に置くための目印
                        HStack(spacing: 0) {
                            Color.clear.frame(width: max(PressureDetailData.x(of: now, in: range, contentWidth: contentWidth), 0), height: 1)
                            Color.clear.frame(width: 1, height: 1).id(Self.nowAnchor)
                            Spacer(minLength: 0)
                        }
                        .allowsHitTesting(false)
                    }
                    .background {
                        GeometryReader { inner in
                            Color.clear.preference(key: PressureScrollOffsetKey.self,
                                                   value: -inner.frame(in: .named(Self.scrollSpace)).minX)
                        }
                    }
                    .contentShape(Rectangle())
                    // 値の表示はタップだけ。指を動かしたときは ScrollView の横スクロールになり、タップは成立しない
                    .gesture(SpatialTapGesture().onEnded { value in
                        selectedDate = PressureDetailData.time(atX: value.location.x, in: range, contentWidth: contentWidth)
                    })
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(PressureScrollOffsetKey.self) { offset in
                    // View の状態は変えない(スクロール中に body を再評価させない)。止まってから集計だけを更新する
                    MainActor.assumeIsolated { tracker.update(offset) }
                }
                .onAppear {
                    viewWidth = width
                    scrollToNow(proxy)
                }
                .onChange(of: span) { _, _ in
                    selectedDate = nil
                    rebuildTiles()
                    scrollToNow(proxy)
                }
                .onChange(of: width) { _, new in viewWidth = new }
            }
            .overlay(alignment: .leading) { PressureYAxisView(yDomain: yDomain).equatable() }
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        // レイアウトが決まってから動かす
        DispatchQueue.main.async {
            proxy.scrollTo(Self.nowAnchor, anchor: UnitPoint(x: PressureDetailData.nowPosition, y: 0))
        }
    }

    @ViewBuilder
    private func selectionMarker(range: DateInterval, contentWidth: CGFloat) -> some View {
        if let selectedDate, let value = PressureAnalysis.value(in: lookupPoints, at: selectedDate) {
            let x = PressureDetailData.x(of: selectedDate, in: range, contentWidth: contentWidth)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 1.5, height: PressureChartStyle.plotBottom - PressureChartStyle.plotTop)
                    .offset(x: x - 0.75, y: PressureChartStyle.plotTop)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 9, height: 9)
                    .offset(x: x - 4.5, y: PressureChartStyle.y(value, in: yDomain) - 4.5)
            }
            .allowsHitTesting(false)
        }
    }

    /// 値を読む点。1日表示では細かい点、それ以外は1時間ごと。
    private var lookupPoints: [PressurePoint] { span == .day ? full : hourly }

    private static let momentFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d(E) HH:mm"
        return formatter
    }()

    @ViewBuilder
    private var selectionText: some View {
        if let selectedDate, let value = PressureAnalysis.value(in: lookupPoints, at: selectedDate),
           let nearest = PressureAnalysis.nearest(in: lookupPoints, to: selectedDate) {
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
            Text("グラフをタップすると、その時刻の気圧、実測か予報か、前3時間の変化を表示します")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 取得の状態

    /// 取得中・失敗の表示と、手動での更新
    @ViewBuilder
    private var statusSection: some View {
        let store = env.pressureHistory
        Section {
            if store.isLoading {
                HStack {
                    ProgressView()
                    Text("取得中…").foregroundStyle(.secondary)
                }
            } else {
                Button("予報を更新する(約2KB)") {
                    guard let snapshot = env.weather.cached?.value, let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
                    Task { await store.refreshOutlook(latitude: latitude, longitude: longitude) }
                }
                .disabled(env.weather.cached?.value.latitude == nil)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("16日先までの予報: " + Formatters.ageLabel(store.outlookFetchedAt, now: context.date))
            }
        }
    }

    // MARK: - 集計

    @ViewBuilder
    private var statsSection: some View {
        let from = visibleStart
        let to = visibleStart.addingTimeInterval(span.seconds)
        if let stats = PressureStats.make(hourly, from: from, to: to, calendar: JapaneseHolidays.calendar) {
            Section("表示中の期間") {
                ViewThatFits {
                    HStack { statValues(stats) }
                    VStack(alignment: .leading, spacing: 6) { statValues(stats) }
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedDate = nil }
            }
            Section("1日ごとの最高・最低") {
                ForEach(stats.days) { day in
                    let color = PressureChartStyle.dayColor(day.date)
                    HStack {
                        Text(PressureChartStyle.dayFormatter.string(from: day.date))
                            .foregroundStyle(color == .secondary ? Color.primary : color)
                        Spacer(minLength: 8)
                        Text("\(String(format: "%.1f", day.high)) / \(String(format: "%.1f", day.low)) hPa")
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedDate = nil }
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

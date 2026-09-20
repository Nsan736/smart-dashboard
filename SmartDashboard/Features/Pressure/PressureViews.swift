import Charts
import SwiftUI

/// 過去24時間〜今後24時間の気圧を1本の線で描く。タップした時刻の値と、実測か予報かを表示する。
struct PressureChart: View {
    let series: PressureSeries
    let now: Date
    var height: CGFloat = 180
    /// ホーム用の小さな表示(軸とタップを省く)
    var isCompact = false
    @State private var selected: PressurePoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chart
                .frame(height: height)
            if !isCompact {
                selectionText
            }
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = series.points.map(\.hPa)
        guard let low = values.min(), let high = values.max() else { return 1000...1020 }
        return (low - 1)...(high + 1)
    }

    private var chart: some View {
        Chart {
            ForEach(series.points) { point in
                LineMark(x: .value("時刻", point.time), y: .value("気圧", point.hPa))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.accentColor)
            }
            RuleMark(x: .value("現在", now))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if let selected, !isCompact {
                RuleMark(x: .value("選択", selected.time)).foregroundStyle(Color.orange.opacity(0.7))
                PointMark(x: .value("時刻", selected.time), y: .value("気圧", selected.hPa)).foregroundStyle(Color.orange)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis(isCompact ? .hidden : .automatic)
        .chartYAxis(isCompact ? .hidden : .automatic)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard !isCompact, let frame = proxy.plotFrame else { return }
                        let x = location.x - geometry[frame].origin.x
                        if let time = proxy.value(atX: x, as: Date.self) { selected = series.nearest(to: time) }
                    }
            }
        }
    }

    @ViewBuilder
    private var selectionText: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Self.timeFormatter.string(from: selected.time))　\(String(format: "%.1f", selected.hPa)) hPa・\(selected.source == .measured ? "実測" : "予報")")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if selected.source == .forecast, series.hasMeasured {
                    Text("予報の値は、実測とつながるように \(String(format: "%+.1f", series.correction)) hPa 補正しています")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("グラフをタップすると、その時刻の気圧と、実測か予報かを表示します")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}

/// バックグラウンドでの記録の状態を小さく表示する
struct BackgroundRecordingStatus: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if env.settings.backgroundPressureEnabled {
            VStack(alignment: .leading, spacing: 2) {
                Text(env.keeper.statusText)
                if env.keeper.lastCheck == .notRecorded {
                    Text("この環境ではバックグラウンドで記録できないようです")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct PressureHomeCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let forecast = env.pressureForecast
            let series = PressureSeries.make(measured: env.pressure.samples, forecast: forecast, now: now)
            let change = PressureChange.make(measured: env.pressure.samples, forecast: forecast, now: now)
            let isAlert = change?.isAlert(threshold: env.settings.pressureAlertDrop) == true
            HomeCard(title: "気圧", symbol: "barometer") {
                HStack(alignment: .firstTextBaseline) {
                    if let hPa = env.pressure.latestHPa {
                        BigValue(value: String(format: "%.1f", hPa), unit: "hPa", size: 32)
                    } else {
                        Text(env.pressure.availability.unavailableText ?? "実測なし")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                }
                if series.points.count > 1 {
                    PressureChart(series: series, now: now, height: 70, isCompact: true)
                }
                if let change {
                    Label(change.text + (change.baseIsMeasured ? "" : "(予報)"), systemImage: isAlert ? "arrow.down.right.circle.fill" : "arrow.right.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isAlert ? Color.orange : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("予報が未取得のため、変化量は出せません").font(.caption).foregroundStyle(.secondary)
                }
                BackgroundRecordingStatus()
            }
            .overlay {
                if isAlert { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.orange, lineWidth: 3) }
            }
        }
    }
}

/// 天気タブに出す、気圧の変化のグラフ
struct PressureSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let now = context.date
                let forecast = env.pressureForecast
                let series = PressureSeries.make(measured: env.pressure.samples, forecast: forecast, now: now)
                VStack(alignment: .leading, spacing: 8) {
                    if let change = PressureChange.make(measured: env.pressure.samples, forecast: forecast, now: now) {
                        let isAlert = change.isAlert(threshold: env.settings.pressureAlertDrop)
                        Text(change.text + (change.baseIsMeasured ? "" : "(予報)"))
                            .font(.headline)
                            .foregroundStyle(isAlert ? Color.orange : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if series.points.count > 1 {
                        PressureChart(series: series, now: now)
                    } else {
                        Text("気圧のデータがまだありません").foregroundStyle(.secondary)
                    }
                    BackgroundRecordingStatus()
                }
            }
        } header: {
            Text("気圧の変化(過去24時間〜今後24時間)")
        } footer: {
            Text("気圧計で実測した時間帯は実測、それ以外(アプリを閉じていた間と未来)は予報(Open-Meteo)です。実測は、アプリを開いている間に5分に1回記録し、48時間分を保存します。")
        }
    }
}

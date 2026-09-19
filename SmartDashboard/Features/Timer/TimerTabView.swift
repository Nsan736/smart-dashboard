import SwiftUI

struct TimerTabView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var mode = 0

    var body: some View {
        @Bindable var store = env.timers
        NavigationStack {
            VStack(spacing: 0) {
                Picker("種類", selection: $mode) {
                    Text("タイマー").tag(0)
                    Text("ストップウォッチ").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                if mode == 0 {
                    CountdownListView()
                } else {
                    StopwatchView()
                }
            }
            .navigationTitle("タイマー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $store.keepAwake) {
                        Label("画面を消さない", systemImage: store.keepAwake ? "sun.max.fill" : "sun.max")
                    }
                    .toggleStyle(.button)
                }
            }
        }
    }
}

private struct CountdownListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var hours = 0
    @State private var minutes = 5
    @State private var seconds = 0
    @State private var label = ""
    @State private var pendingDelete: CountdownTimer?

    private var duration: TimeInterval { TimeInterval(hours * 3600 + minutes * 60 + seconds) }

    var body: some View {
        let store = env.timers
        List {
            if !store.timers.isEmpty {
                Section("タイマー") {
                    ForEach(store.timers) { timer in
                        TimerRow(timer: timer) { pendingDelete = timer }
                    }
                }
            }
            Section("新しいタイマー") {
                HStack(spacing: 0) {
                    wheel("時間", $hours, 0..<24)
                    wheel("分", $minutes, 0..<60)
                    wheel("秒", $seconds, 0..<60)
                }
                .frame(height: 120)
                TextField("ラベル(省略可)", text: $label)
                Button("開始") {
                    store.addTimer(label: label, duration: duration, startNow: true)
                    label = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(duration < 1)
            }
            if store.notificationsAvailable == false {
                Section {
                    Label("通知は利用不可です。アプリを開いている間は音とバイブで知らせます。", systemImage: "bell.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(
            "このタイマーを削除しますか？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { timer in
            Button("削除", role: .destructive) {
                store.remove(timer.id)
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: { timer in
            Text(timer.label)
        }
    }

    private func wheel(_ unit: String, _ value: Binding<Int>, _ range: Range<Int>) -> some View {
        Picker(unit, selection: value) {
            ForEach(range, id: \.self) { Text("\($0)\(unit)").tag($0) }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// 行全体は再描画せず、残り時間の文字だけをTimelineViewで更新する。
/// 状態(動作中→終了)の切り替わりは TimerStore が timers を更新することで反映される。
private struct TimerRow: View {
    @Environment(AppEnvironment.self) private var env
    let timer: CountdownTimer
    let onDelete: () -> Void

    var body: some View {
        let store = env.timers
        let state = timer.state(now: Date())
        VStack(alignment: .leading, spacing: 4) {
            // 上段: ラベルと削除。削除は操作ボタンから離して右上に置く。
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(timer.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let end = timer.endDate, state == .running {
                        Text("\(end.formatted(date: .omitted, time: .shortened)) に終了")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.body)
                        .frame(width: 44, height: 36)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel("タイマーを削除")
            }
            // 下段: 残り時間と操作
            HStack {
                RemainingTimeText(timer: timer)
                Spacer()
                switch state {
                case .running:
                    iconButton("pause.fill", "一時停止") { store.pause(timer.id) }
                case .idle, .paused:
                    iconButton("play.fill", "開始") { store.start(timer.id) }
                case .finished:
                    EmptyView()
                }
                iconButton("arrow.counterclockwise", "リセット") { store.reset(timer.id) }
            }
        }
        .padding(.vertical, 2)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

private struct RemainingTimeText: View {
    let timer: CountdownTimer

    var body: some View {
        if timer.endDate == nil {
            text(timer.remaining(now: Date()), finished: false)
        } else {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                text(timer.remaining(now: context.date), finished: timer.state(now: context.date) == .finished)
            }
        }
    }

    private func text(_ remaining: TimeInterval, finished: Bool) -> some View {
        Text(finished ? "終了" : TimeText.countdown(remaining))
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(finished ? Color.red : Color.primary)
    }
}

private struct StopwatchView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.timers
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: store.stopwatch.isRunning ? 0.03 : 1)) { context in
                Text(TimeText.stopwatch(store.stopwatch.elapsed(now: context.date)))
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal)
            }
            HStack(spacing: 24) {
                if store.stopwatch.isRunning {
                    Button("ラップ") { store.stopwatchLap() }
                        .buttonStyle(.bordered)
                    Button("停止") { store.stopwatchStop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("リセット") { store.stopwatchReset() }
                        .buttonStyle(.bordered)
                    Button("開始") { store.stopwatchStart() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .font(.title3.weight(.semibold))
            List {
                ForEach(store.stopwatch.laps.reversed(), id: \.index) { lap in
                    HStack {
                        Text("ラップ \(lap.index)")
                        Spacer()
                        Text(TimeText.stopwatch(lap.lap)).monospacedDigit()
                        Text(TimeText.stopwatch(lap.total))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .trailing)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

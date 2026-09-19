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

    private var duration: TimeInterval { TimeInterval(hours * 3600 + minutes * 60 + seconds) }

    var body: some View {
        let store = env.timers
        List {
            if !store.timers.isEmpty {
                Section("タイマー") {
                    ForEach(store.timers) { timer in
                        TimerRow(timer: timer)
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ store.timers[$0].id }) { store.remove(id) }
                    }
                }
            }
            Section("プリセット") {
                ForEach(store.presets) { preset in
                    Button {
                        store.addTimer(label: preset.label, duration: preset.duration, startNow: true)
                    } label: {
                        HStack {
                            Label(preset.label, systemImage: "play.circle")
                            Spacer()
                            Text(TimeText.countdown(preset.duration))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { store.removePresets(at: $0) }
            }
            Section("新しいタイマー") {
                HStack(spacing: 0) {
                    wheel("時間", $hours, 0..<24)
                    wheel("分", $minutes, 0..<60)
                    wheel("秒", $seconds, 0..<60)
                }
                .frame(height: 120)
                TextField("ラベル(省略可)", text: $label)
                HStack {
                    Button("開始") {
                        store.addTimer(label: label, duration: duration, startNow: true)
                        label = ""
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("プリセットに保存") {
                        store.addPreset(label: label, duration: duration)
                        label = ""
                    }
                    .buttonStyle(.bordered)
                }
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

private struct TimerRow: View {
    @Environment(AppEnvironment.self) private var env
    let timer: CountdownTimer

    var body: some View {
        let store = env.timers
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let state = timer.state(now: context.date)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timer.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(state == .finished ? "終了" : TimeText.countdown(timer.remaining(now: context.date)))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(state == .finished ? Color.red : Color.primary)
                    if let end = timer.endDate, state == .running {
                        Text("\(end.formatted(date: .omitted, time: .shortened)) に終了")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                switch state {
                case .running:
                    iconButton("pause.fill") { store.pause(timer.id) }
                case .idle, .paused:
                    iconButton("play.fill") { store.start(timer.id) }
                case .finished:
                    EmptyView()
                }
                iconButton("arrow.counterclockwise") { store.reset(timer.id) }
            }
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
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

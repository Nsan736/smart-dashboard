import AVFoundation
import Observation
import SwiftUI

private struct BigResultRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
        }
    }
}

private func minutesOfDay(_ date: Date) -> Int {
    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
}

// MARK: - 時間計算

struct TimeCalcToolView: View {
    @State private var linesText = "1:30\n45分"
    @State private var start = Date()
    @State private var durationText = "1:30"
    @State private var subtracts = false
    @State private var from = Date()
    @State private var to = Date()

    var body: some View {
        Form {
            Section {
                TextEditor(text: $linesText)
                    .frame(minHeight: 96)
                    .font(.body.monospacedDigit())
                let sum = TimeCalc.sum(lines: linesText)
                BigResultRow(title: "合計", value: TimeCalc.format(sum.total))
                BigResultRow(title: "", value: TimeCalc.japanese(sum.total))
                if !sum.invalidLines.isEmpty {
                    Text("読めない行: " + sum.invalidLines.map(String.init).joined(separator: ", ") + "行目")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("時間の合計(1行に1つ)")
            } footer: {
                Text("書き方: 1:30(時:分)、1:30:15(時:分:秒)、1時間30分、90分、45秒、数字だけなら分。先頭に - を付けた行は引きます。")
            }
            Section("時刻に時間を足す・引く") {
                DatePicker("時刻", selection: $start, displayedComponents: .hourAndMinute)
                HStack {
                    Picker("", selection: $subtracts) {
                        Text("足す").tag(false)
                        Text("引く").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 120)
                    TextField("1:30", text: $durationText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                }
                if let seconds = TimeCalc.parse(durationText) {
                    let result = TimeCalc.clock(adding: subtracts ? -seconds : seconds, toMinutes: minutesOfDay(start))
                    BigResultRow(title: "結果", value: TimeCalc.clockText(result.minutes) + (result.dayOffset == 0 ? "" : "(" + WorldClock.dayText(result.dayOffset) + ")"))
                } else {
                    Text("時間を読めません").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                DatePicker("開始", selection: $from, displayedComponents: .hourAndMinute)
                DatePicker("終了", selection: $to, displayedComponents: .hourAndMinute)
                let minutes = TimeCalc.minutesBetween(startMinutes: minutesOfDay(from), endMinutes: minutesOfDay(to))
                BigResultRow(title: "間の時間", value: TimeCalc.japanese(minutes * 60))
            } header: {
                Text("2つの時刻の間")
            } footer: {
                Text("終了が開始より早いときは、翌日の時刻として数えます。")
            }
        }
        .keyboardDismissable()
    }
}

// MARK: - 世界時計

struct WorldClockToolView: View {
    @AppStorage("tools.worldclock.cities") private var citiesText = WorldClock.encode(WorldClock.defaultIDs.compactMap { id in WorldClock.cities.first { $0.id == id } })
    @State private var usesNow = true
    @State private var custom = Date()
    @State private var pendingDelete: WorldClock.City?

    var body: some View {
        let selected = WorldClock.decode(citiesText)
        Form {
            Section {
                Toggle("今の時刻", isOn: $usesNow)
                if !usesNow {
                    DatePicker("日本の日時", selection: $custom)
                        .environment(\.timeZone, WorldClock.japan)
                }
            }
            Section {
                if usesNow {
                    TimelineView(.everyMinute) { timeline in
                        rows(selected, at: timeline.date)
                    }
                } else {
                    rows(selected, at: custom)
                }
            } footer: {
                Text("時差は日本時間との差です。夏時間は、その日時のものを反映します。")
            }
            Section {
                Menu("都市を追加") {
                    ForEach(WorldClock.cities.filter { city in city.id != "tokyo" && !selected.contains(city) }) { city in
                        Button(city.name) { citiesText = WorldClock.encode(selected + [city]) }
                    }
                }
            }
        }
        .confirmationDialog("この都市を一覧から外しますか", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { city in
            Button("外す", role: .destructive) { citiesText = WorldClock.encode(selected.filter { $0 != city }) }
        }
    }

    @ViewBuilder
    private func rows(_ selected: [WorldClock.City], at date: Date) -> some View {
        row(WorldClock.cities[0], at: date, deletable: false)
        ForEach(selected) { city in row(city, at: date, deletable: true) }
    }

    private func row(_ city: WorldClock.City, at date: Date, deletable: Bool) -> some View {
        let zone = TimeZone(identifier: city.zone) ?? WorldClock.japan
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(city.name).fixedSize(horizontal: false, vertical: true)
                if deletable {
                    Text(WorldClock.offsetText(WorldClock.offsetFromJapan(zone, at: date)) + "・" + WorldClock.dayText(WorldClock.dayDifference(zone, at: date)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(WorldClock.timeText(zone, at: date))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            if deletable {
                Button(role: .destructive) {
                    pendingDelete = city
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - スコアボード

struct ScoreboardToolView: View {
    @AppStorage("tools.scoreboard") private var data = Data()
    @State private var board = Scoreboard()
    @State private var loaded = false
    @State private var confirmsReset = false
    @State private var message: String?

    private static let colors: [Color] = [.red, .blue, .green, .orange]

    var body: some View {
        Form {
            ForEach($board.teams) { $team in
                let index = board.teams.firstIndex { $0.id == team.id } ?? 0
                Section {
                    HStack {
                        TextField("名前", text: $team.name)
                        Text("セット \(team.sets)").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack(spacing: 12) {
                        Button {
                            team.score = max(0, team.score - 1)
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 32))
                        }
                        .buttonStyle(.borderless)
                        Spacer(minLength: 0)
                        Text("\(team.score)")
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .foregroundStyle(Self.colors[index % Self.colors.count])
                        Spacer(minLength: 0)
                        Button {
                            team.score += 1
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 48))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section {
                Button("セットを終える(点の高いほうに1セット)") {
                    message = board.finishSet() ? nil : "同点なので、セットを決められません"
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                if board.teams.count < Scoreboard.maxTeams {
                    Button("チームを追加") { board.teams.append(Scoreboard.Team(name: "チーム" + ["A", "B", "C", "D"][board.teams.count])) }
                }
                if board.teams.count > 2 {
                    Button("最後のチームを外す", role: .destructive) { board.teams.removeLast() }
                }
                Button("すべて0に戻す", role: .destructive) { confirmsReset = true }
            } footer: {
                Text("この画面を表示している間は、画面を消しません。")
            }
        }
        .keyboardDismissable()
        .onAppear {
            if !loaded {
                board = (try? JSONDecoder().decode(Scoreboard.self, from: data)) ?? Scoreboard()
                loaded = true
            }
            ScreenAwake.set("scoreboard", true)
        }
        .onDisappear { ScreenAwake.set("scoreboard", false) }
        .onChange(of: board) { _, new in data = (try? JSONEncoder().encode(new)) ?? Data() }
        .confirmationDialog("点とセットを、すべて0に戻しますか", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("0に戻す", role: .destructive) { board.resetAll() }
        }
    }
}

// MARK: - メトロノーム

/// 1小節ぶんの波形を作り、ループで鳴らす(拍の間隔はサンプル単位で正確)。
/// オーディオの共有: 気圧の記録の無音再生(.playback + .mixWithOthers)と同じカテゴリーを使い、すでにそのカテゴリーか、
/// 騒音計の .playAndRecord のときは、カテゴリーを変えない。止めるときは自分のエンジンだけを止め、
/// セッションは非アクティブにしない(無音再生を巻き込んで止めないため)。
@MainActor
@Observable
final class MetronomePlayer {
    private(set) var isPlaying = false
    private(set) var startedAt: Date?
    private(set) var message: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start(bpm: Int, beatsPerBar: Int, accent: Bool) {
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord, session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            let sampleRate = 44100.0
            let samples = MetronomeLogic.barSamples(bpm: bpm, beatsPerBar: beatsPerBar, accent: accent, sampleRate: sampleRate)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else {
                message = "音を用意できませんでした"
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress { channel.update(from: base, count: samples.count) }
            }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
            startedAt = Date()
            isPlaying = true
            message = nil
            installObservers()
        } catch {
            stop()
            message = "音を鳴らせませんでした"
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        isPlaying = false
        startedAt = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// 電話などの中断や、出力先の変更で音が止まったら、表示も「停止」にそろえる(自動では再開しない)
    private func installObservers() {
        let center = NotificationCenter.default
        let halt: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.stop()
                self.message = "音が中断されたので止めました"
            }
        }
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main, using: halt),
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main, using: halt),
        ]
    }
}

struct MetronomeToolView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tools.metronome.bpm") private var bpm = 100
    @AppStorage("tools.metronome.beats") private var beats = 4
    @AppStorage("tools.metronome.accent") private var accent = true
    @State private var player = MetronomePlayer()
    @State private var taps: [TimeInterval] = []

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(bpm)").font(.system(size: 64, weight: .heavy, design: .rounded)).monospacedDigit()
                        Text("BPM").foregroundStyle(.secondary)
                    }
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { timeline in
                        let current = player.startedAt.map { MetronomeLogic.beatIndex(elapsed: timeline.date.timeIntervalSince($0), bpm: bpm, beatsPerBar: beats) }
                        HStack(spacing: 8) {
                            ForEach(0..<beats, id: \.self) { beat in
                                Circle()
                                    .fill(current == beat ? (beat == 0 && accent ? Color.orange : Color.accentColor) : Color.gray.opacity(0.3))
                                    .frame(width: 18, height: 18)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                HStack {
                    Button("−5") { setBPM(bpm - 5) }.buttonStyle(.bordered)
                    Button("−1") { setBPM(bpm - 1) }.buttonStyle(.bordered)
                    Spacer(minLength: 4)
                    Button("+1") { setBPM(bpm + 1) }.buttonStyle(.bordered)
                    Button("+5") { setBPM(bpm + 5) }.buttonStyle(.bordered)
                }
                Button(player.isPlaying ? "止める" : "鳴らす") {
                    if player.isPlaying { player.stop() } else { player.start(bpm: bpm, beatsPerBar: beats, accent: accent) }
                }
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity)
                if let message = player.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Stepper("拍子: \(beats)拍", value: $beats, in: 1...8)
                Toggle("1拍目を高い音にする", isOn: $accent)
                Button("タップでテンポを決める") {
                    taps.append(Date().timeIntervalSinceReferenceDate)
                    taps = Array(taps.suffix(8))
                    if let tempo = MetronomeLogic.tapTempo(taps) { setBPM(tempo) }
                }
            } footer: {
                Text("消音スイッチがオンでも鳴ります。ほかのアプリの音楽は止めません。この画面を離れると止まります。")
            }
        }
        .onChange(of: beats) { _, _ in restartIfPlaying() }
        .onChange(of: accent) { _, _ in restartIfPlaying() }
        .onChange(of: player.isPlaying) { _, playing in ScreenAwake.set("metronome", playing) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.stop() } }
        .onDisappear {
            player.stop()
            ScreenAwake.set("metronome", false)
        }
    }

    private func setBPM(_ value: Int) {
        bpm = MetronomeLogic.clamped(value)
        restartIfPlaying()
    }

    private func restartIfPlaying() {
        if player.isPlaying { player.start(bpm: bpm, beatsPerBar: beats, accent: accent) }
    }
}

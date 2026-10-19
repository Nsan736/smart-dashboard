import AVFoundation
import Observation
import SwiftUI

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

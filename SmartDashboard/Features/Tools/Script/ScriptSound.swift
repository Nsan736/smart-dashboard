import AVFoundation
import Foundation
import UIKit

/// 短い音の波形(純粋なロジック)。効果音のプリセットと、高さと長さを指定した単音。
enum ScriptSynth {
    static let sampleRate = 44_100.0
    static let presets = ["click", "pop", "beep", "coin", "success", "failure", "jump", "hit"]
    static let maxDuration = 2.0

    /// 1つの音(周波数、長さ、音量)。始まりと終わりを短く絞って、プツッという音を防ぐ。
    static func tone(frequency: Double, duration: Double, volume: Double, wave: Int = 0) -> [Float] {
        let f = min(max(frequency.isFinite ? frequency : 440, 20), 8000)
        let d = min(max(duration.isFinite ? duration : 0.2, 0.01), maxDuration)
        let v = min(max(volume.isFinite ? volume : 0.5, 0), 1) * 0.5
        let count = Int(d * sampleRate)
        let fade = min(Int(0.005 * sampleRate), count / 2)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let phase = Double(i) * f / sampleRate
            var s: Double
            switch wave {
            case 1: s = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1 // 矩形波
            case 2: s = 4 * abs(phase.truncatingRemainder(dividingBy: 1) - 0.5) - 1 // 三角波
            default: s = sin(2 * .pi * phase)
            }
            var envelope = 1.0
            if i < fade { envelope = Double(i) / Double(max(fade, 1)) }
            if i > count - fade { envelope = Double(count - i) / Double(max(fade, 1)) }
            samples[i] = Float(s * v * envelope)
        }
        return samples
    }

    /// 効果音のプリセット。知らない名前は nil。
    static func preset(_ name: String) -> [Float]? {
        switch name {
        case "click": return tone(frequency: 1800, duration: 0.02, volume: 0.6)
        case "pop": return tone(frequency: 660, duration: 0.06, volume: 0.7, wave: 2)
        case "beep": return tone(frequency: 880, duration: 0.15, volume: 0.5)
        case "coin": return tone(frequency: 988, duration: 0.07, volume: 0.5, wave: 1) + tone(frequency: 1319, duration: 0.18, volume: 0.5, wave: 1)
        case "success": return tone(frequency: 523, duration: 0.1, volume: 0.5) + tone(frequency: 659, duration: 0.1, volume: 0.5) + tone(frequency: 784, duration: 0.2, volume: 0.5)
        case "failure": return tone(frequency: 392, duration: 0.15, volume: 0.5, wave: 2) + tone(frequency: 262, duration: 0.3, volume: 0.5, wave: 2)
        case "jump": return (0..<8).flatMap { tone(frequency: 300 + Double($0) * 80, duration: 0.02, volume: 0.4, wave: 1) }
        case "hit": return tone(frequency: 120, duration: 0.08, volume: 0.8, wave: 1)
        default: return nil
        }
    }

    static func samples(for request: ScriptSoundRequest) -> [Float]? {
        if request.name == "tone" {
            return tone(frequency: request.frequency, duration: request.duration, volume: request.volume)
        }
        return preset(request.name)
    }
}

/// スクリプトの音を鳴らす。メトロノームと同じく .playback + .mixWithOthers を使い、
/// セッションがすでに .playback(気圧の無音再生)か .playAndRecord(騒音計)のときはカテゴリーを変えない。
/// 止めるときは自分のエンジンだけを止め、セッションを非アクティブにしない(ほかの再生を巻き込まないため)。
@MainActor
final class ScriptSoundPlayer {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    /// 1秒あたりの数の上限(鳴らしすぎを防ぐ)
    private var recent: [Date] = []
    static let maxPerSecond = 20

    func play(_ request: ScriptSoundRequest) {
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0) < 1 }
        guard recent.count < Self.maxPerSecond, let samples = ScriptSynth.samples(for: request), !samples.isEmpty else { return }
        recent.append(now)
        guard prepare(), let format, let player,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let base = pointer.baseAddress { channel.update(from: base, count: samples.count) }
        }
        player.scheduleBuffer(buffer, at: nil, options: [])
        if !player.isPlaying { player.play() }
    }

    private func prepare() -> Bool {
        if let engine, engine.isRunning { return true }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord, session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: ScriptSynth.sampleRate, channels: 1) else { return false }
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            self.engine = engine
            self.player = player
            self.format = format
            return true
        } catch {
            stop()
            return false
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}

/// 短い振動(1秒に数回まで)
@MainActor
enum ScriptHaptics {
    private static var last = Date.distantPast

    static func play(_ kind: String) {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.08 else { return }
        last = now
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

import AVFoundation
import Foundation
import Observation

/// マイクのメータリングで周囲の騒音の目安を出す。録音データは /dev/null に捨て、保存しない。
@MainActor
@Observable
final class NoiseMeter {
    private(set) var availability: SensorAvailability = .unknown
    /// 目安のdB値(校正していない)
    private(set) var decibels: Double?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var wantsRunning = false

    func start() {
        wantsRunning = true
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard wantsRunning else { return }
            guard granted else {
                availability = .denied
                return
            }
            begin()
        }
    }

    func stop() {
        wantsRunning = false
        pollTask?.cancel()
        pollTask = nil
        recorder?.stop()
        recorder = nil
        decibels = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func begin() {
        guard recorder == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: URL(fileURLWithPath: "/dev/null"), settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                availability = .unsupported
                return
            }
            self.recorder = recorder
            availability = .available
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.decibels = Self.estimateDecibels(fromPower: Double(recorder.averagePower(forChannel: 0)))
                }
            }
        } catch {
            availability = .unsupported
        }
    }

    /// dBFS(-160〜0)を、おおよその音圧レベルに換算する。校正なしの目安。
    nonisolated static func estimateDecibels(fromPower power: Double) -> Double {
        min(max(power + 100, 0), 120)
    }

    static func levelLabel(_ db: Double) -> String {
        switch db {
        case ..<40: return "とても静か"
        case ..<55: return "静か"
        case ..<70: return "普通"
        case ..<85: return "うるさい"
        default: return "非常にうるさい"
        }
    }
}

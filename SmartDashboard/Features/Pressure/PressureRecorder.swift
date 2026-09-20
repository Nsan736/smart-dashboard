import AVFoundation
import CoreMotion
import Foundation
import Observation
import UIKit

/// 気圧の実測を5分に1回記録し、100日分だけ保存する。1日ごとのファイルに分け、記録のたびに書くのは当日の分だけにする。アプリを開いている間(と、バックグラウンドで記録する設定のとき)に動く。
@MainActor
@Observable
final class PressureRecorder {
    private(set) var samples: [PressureSample] = []
    private(set) var latestHPa: Double?
    private(set) var availability: SensorAvailability = .unknown
    /// アプリがバックグラウンドにいるか(記録に印を付ける)
    @ObservationIgnored var isInBackground = false

    @ObservationIgnored private let altimeter = CMAltimeter()
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var isRunning = false

    /// legacyFileURL は、1つのファイルに48時間分を保存していた頃の記録(あれば引き継いで消す)
    init(directory: URL, legacyFileURL: URL? = nil) {
        self.directory = directory
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let oldestDay = PressureSampleCodec.dayIndex(now.addingTimeInterval(-PressureLog.retention))
        var loaded: [PressureSample] = []
        for url in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard let day = Int(url.deletingPathExtension().lastPathComponent) else { continue }
            if day < oldestDay {
                try? manager.removeItem(at: url)
            } else if let data = try? Data(contentsOf: url) {
                loaded.append(contentsOf: PressureSampleCodec.decode(data))
            }
        }
        if let legacyFileURL, let data = try? Data(contentsOf: legacyFileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            loaded.append(contentsOf: (try? decoder.decode([PressureSample].self, from: data)) ?? [])
            try? manager.removeItem(at: legacyFileURL)
            samples = PressureLog.trimmed(loaded, now: now).sorted { $0.time < $1.time }
            for day in Set(samples.map { PressureSampleCodec.dayIndex($0.time) }) { save(day: day) }
        } else {
            samples = PressureLog.trimmed(loaded, now: now).sorted { $0.time < $1.time }
        }
    }

    private func save(day: Int) {
        let daySamples = samples.filter { PressureSampleCodec.dayIndex($0.time) == day }
        let url = directory.appendingPathComponent("\(day).json")
        try? PressureSampleCodec.encode(daySamples).write(to: url, options: .atomic)
    }

    func start() {
        guard !isRunning else { return }
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            availability = .unsupported
            return
        }
        isRunning = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data {
                    self.availability = .available
                    self.receive(hPa: data.pressure.doubleValue * 10, now: Date())
                } else if error != nil {
                    let status = CMMotionActivityManager.authorizationStatus()
                    self.availability = (status == .denied || status == .restricted) ? .denied : .unsupported
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        altimeter.stopRelativeAltitudeUpdates()
    }

    private func receive(hPa: Double, now: Date) {
        latestHPa = hPa
        guard PressureLog.shouldRecord(last: samples.last?.time, now: now) else { return }
        samples.append(PressureSample(time: now, hPa: hPa, inBackground: isInBackground))
        // 100日を超えた分は、日付が変わったときにファイルごと消す
        let today = PressureSampleCodec.dayIndex(now)
        if let first = samples.first, now.timeIntervalSince(first.time) > PressureLog.retention {
            let oldestDay = PressureSampleCodec.dayIndex(now.addingTimeInterval(-PressureLog.retention))
            samples = PressureLog.trimmed(samples, now: now)
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                if let day = Int(url.deletingPathExtension().lastPathComponent), day < oldestDay {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        save(day: today)
    }

    /// 保存に使っている容量(バイト)
    func storageBytes() -> Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// 実測の記録のファイル形式。1日(UTC)ごとに1ファイルで、中身は [[時刻(秒), hPa, バックグラウンドなら1], ...]。
enum PressureSampleCodec {
    static func dayIndex(_ time: Date) -> Int {
        Int((time.timeIntervalSince1970 / 86400).rounded(.down))
    }

    static func encode(_ samples: [PressureSample]) -> Data {
        let rows = samples.map { [($0.time.timeIntervalSince1970).rounded(), ($0.hPa * 100).rounded() / 100, $0.inBackground ? 1 : 0] }
        return (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [PressureSample] {
        let rows = (try? JSONDecoder().decode([[Double]].self, from: data)) ?? []
        return rows.compactMap { row in
            row.count >= 2 ? PressureSample(time: Date(timeIntervalSince1970: row[0]), hPa: row[1], inBackground: row.count > 2 && row[2] == 1) : nil
        }
    }
}

/// 無音のオーディオをループ再生して、アプリをバックグラウンドでも動かしておく(気圧の記録用のオプション)。
/// ほかのアプリの音は止めない(.playback + .mixWithOthers)。
@MainActor
@Observable
final class BackgroundKeeper {
    enum State: Equatable {
        case running
        case stopped(BackgroundStopReason)
    }

    private(set) var state: State = .stopped(.disabled)
    /// この環境でバックグラウンドの記録が実際に続いていたか(前回の判定)
    private(set) var lastCheck: BackgroundRecordingCheck?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundStart: Date?
    /// 動作を止めたとき(記録も止めるために知らせる)
    @ObservationIgnored var onStateChange: (@MainActor (State) -> Void)?

    private static let checkKey = "pressure.backgroundCheck"

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        lastCheck = defaults.string(forKey: Self.checkKey).flatMap(BackgroundRecordingCheck.init(rawValue:))
    }

    var isRunning: Bool { state == .running }

    var statusText: String {
        switch state {
        case .running: return "バックグラウンドで記録中"
        case .stopped(let reason): return "停止中：\(reason.text)"
        }
    }

    /// 設定、電池残量、低電力モードを見て、動かすか止めるかを決める
    func evaluate() {
        installObserversIfNeeded()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let reason = BackgroundStopReason.decide(enabled: settings.backgroundPressureEnabled,
                                                 batteryLevel: UIDevice.current.batteryLevel,
                                                 isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if let reason {
            stopAudio()
            setState(.stopped(reason))
        } else if engine?.isRunning != true {
            setState(startAudio() ? .running : .stopped(.audioFailed))
        }
    }

    func didEnterBackground(now: Date = Date()) {
        // 騒音計の停止などでオーディオが止まっていたら、バックグラウンドに入る前に動かし直す
        restartIfNeeded()
        backgroundStart = isRunning ? now : nil
    }

    /// フォアグラウンドに戻ったときに、閉じていた間の記録が続いていたかを判定する
    func didBecomeActive(samples: [PressureSample], now: Date = Date()) {
        defer { backgroundStart = nil }
        guard let start = backgroundStart else { return }
        let check = BackgroundRecordingCheck.verdict(backgroundStart: start, end: now, sampleTimes: samples.map(\.time))
        guard check != .tooShort else { return }
        lastCheck = check
        defaults.set(check.rawValue, forKey: Self.checkKey)
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    private func startAudio() -> Bool {
        stopAudio()
        do {
            let session = AVAudioSession.sharedInstance()
            // 騒音計(マイク)が動いている間は、そのカテゴリーを変えない。騒音計を壊さないようにする。
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else { return false }
            // 値はすべて0(無音)
            buffer.frameLength = buffer.frameCapacity
            if let channel = buffer.floatChannelData?[0] { memset(channel, 0, Int(buffer.frameLength) * MemoryLayout<Float>.size) }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
            return true
        } catch {
            stopAudio()
            return false
        }
    }

    private func stopAudio() {
        guard engine != nil else { return }
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 電話などの中断、出力先の変更、オーディオの再構成のあとに再開する。電池と低電力モードの変化でも判定し直す。
    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let restart: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfNeeded() }
        }
        let reevaluate: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let ended = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
                MainActor.assumeIsolated { if ended { self?.restartIfNeeded() } }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main, using: restart),
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main, using: restart),
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main, using: restart),
            center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main, using: reevaluate),
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: reevaluate),
        ]
    }

    private func restartIfNeeded() {
        guard state == .running || state == .stopped(.audioFailed) else { return }
        if engine?.isRunning == true && player?.isPlaying == true { return }
        stopAudio()
        state = .stopped(.audioFailed)
        evaluate()
    }
}

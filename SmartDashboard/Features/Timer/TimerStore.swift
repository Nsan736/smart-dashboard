import AudioToolbox
import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class TimerStore {
    private(set) var timers: [CountdownTimer] = []
    private(set) var stopwatch = Stopwatch()
    /// 通知の許可状態の表示用。nilは未確認。
    private(set) var notificationsAvailable: Bool?

    var keepAwake: Bool {
        didSet {
            defaults.set(keepAwake, forKey: Keys.keepAwake)
            updateIdleTimer()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keepAwake = defaults.bool(forKey: Keys.keepAwake)
        timers = Self.load([CountdownTimer].self, defaults, Keys.timers) ?? []
        stopwatch = Self.load(Stopwatch.self, defaults, Keys.stopwatch) ?? Stopwatch()
        // 廃止したプリセット機能の保存データを破棄する
        defaults.removeObject(forKey: "timer.presets")
    }

    var hasActivity: Bool {
        let now = Date()
        return stopwatch.isRunning || timers.contains { $0.state(now: now) == .running }
    }

    /// ホーム画面に出す動作中のタイマー
    func runningTimers(now: Date) -> [CountdownTimer] {
        timers.filter { $0.state(now: now) == .running }.sorted { ($0.endDate ?? now) < ($1.endDate ?? now) }
    }

    // MARK: - カウントダウン

    func addTimer(label: String, duration: TimeInterval, startNow: Bool) {
        guard duration >= 1 else { return }
        var timer = CountdownTimer(label: label.isEmpty ? TimeText.duration(duration) : label, duration: duration)
        if startNow { timer.start(now: Date()) }
        timers.append(timer)
        if startNow { scheduleNotification(for: timer) }
        changed()
    }

    func start(_ id: UUID) {
        mutate(id) { $0.start(now: Date()) }
        if let timer = timers.first(where: { $0.id == id }) { scheduleNotification(for: timer) }
    }

    func pause(_ id: UUID) {
        mutate(id) { $0.pause(now: Date()) }
        cancelNotification(id)
    }

    func reset(_ id: UUID) {
        mutate(id) { $0.reset() }
        cancelNotification(id)
    }

    /// 動作中でも削除でき、登録済みのローカル通知も取り消す
    func remove(_ id: UUID) {
        timers.removeAll { $0.id == id }
        cancelNotification(id)
        changed()
    }

    private func mutate(_ id: UUID, _ body: (inout CountdownTimer) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        body(&timers[index])
        changed()
    }

    // MARK: - ストップウォッチ

    func stopwatchStart() { stopwatch.start(now: Date()); stopwatchChanged() }
    func stopwatchStop() { stopwatch.stop(now: Date()); stopwatchChanged() }
    func stopwatchLap() { stopwatch.lap(now: Date()); stopwatchChanged() }
    func stopwatchReset() { stopwatch.reset(); stopwatchChanged() }

    private func stopwatchChanged() {
        save(stopwatch, Keys.stopwatch)
        updateIdleTimer()
    }

    // MARK: - 終了の検知(アプリ内の音とバイブ)

    /// フォアグラウンド復帰時に呼ぶ。終了時刻から再計算するだけで、通信はしない。
    func resume() {
        checkFinished(silentIfOlderThan: 5)
        ensureTicker()
        updateIdleTimer()
    }

    private func changed() {
        save(timers, Keys.timers)
        ensureTicker()
        updateIdleTimer()
    }

    private func ensureTicker() {
        let now = Date()
        let needsTicker = timers.contains { $0.state(now: now) == .running }
        if needsTicker, ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self else { return }
                    self.checkFinished(silentIfOlderThan: 5)
                    if !self.timers.contains(where: { $0.state(now: Date()) == .running }) {
                        self.ticker = nil
                        self.updateIdleTimer()
                        return
                    }
                }
            }
        }
    }

    /// 終了したタイマーを知らせる。閉じている間に終わっていた分(通知済みのはず)は音を鳴らさない。
    private func checkFinished(silentIfOlderThan threshold: TimeInterval) {
        let now = Date()
        var shouldAlert = false
        var didChange = false
        for index in timers.indices where timers[index].state(now: now) == .finished && !timers[index].didAlert {
            timers[index].didAlert = true
            didChange = true
            if let end = timers[index].endDate, now.timeIntervalSince(end) <= threshold { shouldAlert = true }
        }
        if didChange { save(timers, Keys.timers) }
        if shouldAlert { playAlert() }
    }

    private func playAlert() {
        AudioServicesPlayAlertSound(SystemSoundID(1005))
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && hasActivity
    }

    // MARK: - ローカル通知

    private func scheduleNotification(for timer: CountdownTimer) {
        guard let endDate = timer.endDate else { return }
        let id = timer.id.uuidString
        let label = timer.label
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            notificationsAvailable = granted
            guard granted else { return }
            let interval = endDate.timeIntervalSinceNow
            guard interval > 0.5 else { return }
            let content = UNMutableNotificationContent()
            content.title = "タイマー終了"
            content.body = label
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    private func cancelNotification(_ id: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    // MARK: - 永続化

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ defaults: UserDefaults, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private enum Keys {
        static let timers = "timer.timers"
        static let stopwatch = "timer.stopwatch"
        static let keepAwake = "timer.keepAwake"
    }
}

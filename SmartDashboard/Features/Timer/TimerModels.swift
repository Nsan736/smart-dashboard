import Foundation

/// カウントダウンタイマー。動作中は終了時刻(Date)で保持するので、アプリを閉じても再計算できる。
struct CountdownTimer: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var duration: TimeInterval
    /// 動作中のみ値を持つ
    var endDate: Date?
    /// 一時停止中のみ値を持つ
    var pausedRemaining: TimeInterval?
    /// 終了を知らせ済みか
    var didAlert = false

    enum State: Equatable { case idle, running, paused, finished }

    func state(now: Date) -> State {
        if let endDate { return endDate > now ? .running : .finished }
        if pausedRemaining != nil { return .paused }
        return .idle
    }

    func remaining(now: Date) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return pausedRemaining ?? duration
    }

    mutating func start(now: Date) {
        let remaining = pausedRemaining ?? duration
        endDate = now.addingTimeInterval(remaining)
        pausedRemaining = nil
        didAlert = false
    }

    mutating func pause(now: Date) {
        guard let endDate, endDate > now else { return }
        pausedRemaining = endDate.timeIntervalSince(now)
        self.endDate = nil
    }

    mutating func reset() {
        endDate = nil
        pausedRemaining = nil
        didAlert = false
    }
}

/// ラップ付きのストップウォッチ。開始時刻と累積時間で保持する。
struct Stopwatch: Codable, Equatable {
    var startedAt: Date?
    var accumulated: TimeInterval = 0
    /// 各ラップの終了時点の累計時間
    var lapTotals: [TimeInterval] = []

    var isRunning: Bool { startedAt != nil }

    func elapsed(now: Date) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    mutating func start(now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }

    mutating func stop(now: Date) {
        accumulated = elapsed(now: now)
        startedAt = nil
    }

    mutating func lap(now: Date) {
        guard isRunning else { return }
        lapTotals.append(elapsed(now: now))
    }

    mutating func reset() {
        self = Stopwatch()
    }

    /// (ラップ番号, ラップ単体の時間, 累計)
    var laps: [(index: Int, lap: TimeInterval, total: TimeInterval)] {
        lapTotals.enumerated().map { i, total in
            (i + 1, total - (i > 0 ? lapTotals[i - 1] : 0), total)
        }
    }
}

enum TimeText {
    /// 1:05:09 または 05:09
    static func countdown(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// 05:09.27
    static func stopwatch(_ interval: TimeInterval) -> String {
        let centis = Int((interval * 100).rounded(.down))
        let h = centis / 360000, m = (centis % 360000) / 6000, s = (centis % 6000) / 100, c = centis % 100
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, c) : String(format: "%02d:%02d.%02d", m, s, c)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h)時間") }
        if m > 0 { parts.append("\(m)分") }
        if s > 0 || parts.isEmpty { parts.append("\(s)秒") }
        return parts.joined()
    }
}

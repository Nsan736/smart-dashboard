import Foundation
import Observation

/// 受信バイト数を日別に記録する。キーは "yyyy-MM-dd"。
@MainActor
@Observable
final class DataUsageStore {
    private(set) var bytesByDay: [String: Int64] = [:]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
            bytesByDay = decoded
        }
    }

    var today: Int64 { bytesByDay[Self.dayKey(now())] ?? 0 }

    var thisMonth: Int64 {
        let prefix = String(Self.dayKey(now()).prefix(7))
        return bytesByDay.filter { $0.key.hasPrefix(prefix) }.reduce(0) { $0 + $1.value }
    }

    func add(_ bytes: Int64) {
        bytesByDay[Self.dayKey(now()), default: 0] += bytes
        prune()
        scheduleSave()
    }

    func reset() {
        bytesByDay = [:]
        scheduleSave()
    }

    /// 2か月より古い記録を捨てる
    private func prune() {
        guard bytesByDay.count > 70,
              let limit = Calendar.current.date(byAdding: .day, value: -62, to: now()) else { return }
        let limitKey = Self.dayKey(limit)
        bytesByDay = bytesByDay.filter { $0.key >= limitKey }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = bytesByDay
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

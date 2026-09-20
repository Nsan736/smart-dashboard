import Foundation
import Observation

/// ウェイポイントの保存。端末の中だけで完結し、通信はしない。
@MainActor
@Observable
final class WaypointStore {
    private(set) var waypoints: [Waypoint] = []
    /// 最後に分かった現在地(一覧とホームの距離の表示用)
    private(set) var origin: WaypointOrigin?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults

    private static let originKey = "waypoint.origin"

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        if let data = try? Data(contentsOf: fileURL) {
            waypoints = (try? JSONDecoder().decode([Waypoint].self, from: data)) ?? []
        }
        if let data = defaults.data(forKey: Self.originKey) {
            origin = try? JSONDecoder().decode(WaypointOrigin.self, from: data)
        }
    }

    func add(_ waypoint: Waypoint) {
        waypoints.append(waypoint)
        save()
    }

    func update(_ waypoint: Waypoint) {
        guard let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
        waypoints[index] = waypoint
        save()
    }

    func delete(id: UUID) {
        waypoints.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        waypoints = Self.moved(waypoints, fromOffsets: source, toOffset: destination)
        save()
    }

    /// ピン留めは1つだけ。同じ地点をもう一度選ぶと外す。
    func togglePin(id: UUID) {
        waypoints = Self.togglingPin(waypoints, id: id)
        save()
    }

    func setOrigin(latitude: Double, longitude: Double, time: Date = Date()) {
        // 細かい動きでは保存し直さない
        if let origin, time.timeIntervalSince(origin.time) < 30,
           WaypointMath.distance(fromLatitude: origin.latitude, longitude: origin.longitude, toLatitude: latitude, longitude: longitude) < 20 {
            return
        }
        let new = WaypointOrigin(latitude: latitude, longitude: longitude, time: time)
        origin = new
        if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.originKey) }
    }

    /// ホームのカードに出す地点。ピン留めがあればそれ、なければ一番近い地点。
    func featured() -> WaypointTarget? {
        guard let origin else { return nil }
        return Self.featured(waypoints, latitude: origin.latitude, longitude: origin.longitude)
    }

    nonisolated static func featured(_ waypoints: [Waypoint], latitude: Double, longitude: Double) -> WaypointTarget? {
        let targets = WaypointTarget.make(waypoints, latitude: latitude, longitude: longitude)
        return targets.first { $0.waypoint.isPinned } ?? targets.last
    }

    nonisolated static func togglingPin(_ waypoints: [Waypoint], id: UUID) -> [Waypoint] {
        waypoints.map { waypoint in
            var copy = waypoint
            copy.isPinned = waypoint.id == id ? !waypoint.isPinned : false
            return copy
        }
    }

    nonisolated static func moved(_ waypoints: [Waypoint], fromOffsets source: IndexSet, toOffset destination: Int) -> [Waypoint] {
        let moving = source.sorted().map { waypoints[$0] }
        var result = waypoints
        for index in source.sorted().reversed() { result.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: min(max(insertAt, 0), result.count))
        return result
    }

    private func save() {
        if let data = try? JSONEncoder().encode(waypoints) { try? data.write(to: fileURL, options: .atomic) }
    }
}

import Foundation
import Observation

/// スコープの「地点」の保存(ファイル名と型の名前は、以前のウェイポイントのまま。保存済みのデータを引き継ぐため)。端末の中だけで完結し、通信はしない。
@MainActor
@Observable
final class WaypointStore {
    private(set) var waypoints: [Waypoint] = []
    /// 最後に分かった現在地(一覧とホームの距離の表示用)
    private(set) var origin: WaypointOrigin?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    /// 標高が「未設定」の地点ができたとき(登録した、座標を変えた)。ElevationStore が取得する。
    @ObservationIgnored var onNeedsElevation: (@MainActor (UUID) -> Void)?

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

    /// 表示中の地点(カメラ表示・コンパス表示・地図・ホームの「一番近い地点」に使う)
    var visibleWaypoints: [Waypoint] { waypoints.filter { !$0.isHidden } }

    func add(_ waypoint: Waypoint) {
        waypoints.append(waypoint)
        save()
        if waypoint.elevationState == .unset { onNeedsElevation?(waypoint.id) }
    }

    /// 座標を変えたときは、手で入力した標高でなければ「未設定」に戻して取り直す
    func update(_ waypoint: Waypoint) {
        guard let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
        let updated = Self.updating(waypoints[index], with: waypoint)
        waypoints[index] = updated
        save()
        if updated.elevationState == .unset { onNeedsElevation?(updated.id) }
    }

    nonisolated static func updating(_ old: Waypoint, with new: Waypoint) -> Waypoint {
        var result = new
        let moved = WaypointMath.distance(fromLatitude: old.latitude, longitude: old.longitude,
                                          toLatitude: new.latitude, longitude: new.longitude) > 1
        // 場所を変えたら、標高は取り直す。ただし、同じ編集で標高も手で入れ直したときは、その値を使う。
        let typedNewElevation = new.elevationState == .manual && new.groundElevation != old.groundElevation
        if moved, !typedNewElevation {
            result.groundElevation = nil
            result.elevationState = .unset
        }
        return result
    }

    func setElevation(id: UUID, value: Double?, state: WaypointElevationState) {
        guard let index = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[index].groundElevation = value
        waypoints[index].elevationState = state
        save()
    }

    /// 表示・非表示の切り替え(削除はしない。ピン留めも外さない)
    func setHidden(id: UUID, _ hidden: Bool) {
        guard let index = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[index].isHidden = hidden
        save()
    }

    func setAllHidden(_ hidden: Bool) {
        waypoints = waypoints.map { waypoint in
            var copy = waypoint
            copy.isHidden = hidden
            return copy
        }
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

    /// height: そのときの自分の高さ(一覧の高低差の表示用)。分からなければ nil。
    func setOrigin(latitude: Double, longitude: Double, height: Double? = nil, time: Date = Date()) {
        // 細かい動きでは保存し直さない(高さが新しく分かったときは保存する)
        if let origin, time.timeIntervalSince(origin.time) < 30,
           WaypointMath.distance(fromLatitude: origin.latitude, longitude: origin.longitude, toLatitude: latitude, longitude: longitude) < 20,
           height == nil || origin.height != nil {
            return
        }
        let new = WaypointOrigin(latitude: latitude, longitude: longitude, time: time, height: height ?? origin.flatMap { old in
            // 高さが分からないときは、近くで分かった高さを引き継ぐ
            WaypointMath.distance(fromLatitude: old.latitude, longitude: old.longitude, toLatitude: latitude, longitude: longitude) < 100 ? old.height : nil
        })
        origin = new
        if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.originKey) }
    }

    /// ホームのカードに出す地点。ピン留めがあればそれ(非表示でも。カードに「非表示中」と出す)、なければ表示中で一番近い地点。
    func featured() -> WaypointTarget? {
        guard let origin else { return nil }
        return Self.featured(waypoints, latitude: origin.latitude, longitude: origin.longitude)
    }

    nonisolated static func featured(_ waypoints: [Waypoint], latitude: Double, longitude: Double) -> WaypointTarget? {
        let targets = WaypointTarget.make(waypoints, latitude: latitude, longitude: longitude)
        return targets.first { $0.waypoint.isPinned } ?? targets.last { !$0.waypoint.isHidden }
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

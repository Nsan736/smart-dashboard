import Foundation
import Observation

/// 作ったオブジェクトと、地図に置いたもの。Application Support の objects.json に、一時ファイルに書いてから置き換えて保存する
/// (キャッシュの削除では消さない)。置いたものの地面の標高は、地点と同じ国土地理院の標高APIで取る。
@MainActor
@Observable
final class ObjectStore {
    private struct File: Codable {
        var objects: [ScopeObject]
        var placements: [ObjectPlacement]
    }

    private(set) var objects: [ScopeObject] = []
    private(set) var placements: [ObjectPlacement] = []
    /// 標高を取得中のもの
    private(set) var fetching: Set<UUID> = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let elevation: ElevationStore?
    /// カメラ表示に描くもの(形の面を毎コマ作らないよう、変えたときだけ作り直す)
    @ObservationIgnored private var cachedItems: [ObjectDrawInput.Item]?

    init(fileURL: URL, elevation: ElevationStore?) {
        self.fileURL = fileURL
        self.elevation = elevation
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            objects = file.objects
            placements = file.placements
        }
    }

    static func defaultURL() -> URL {
        DiskCache.defaultDirectory("SmartDashboard").appendingPathComponent("objects.json")
    }

    /// 表示する置いたものと、その形の面
    func drawItems() -> [ObjectDrawInput.Item] {
        if let cachedItems { return cachedItems }
        let items = ObjectDrawInput.make(placements: placements, objects: objects, user: GeoPoint(0, 0), observerAltitude: nil, handHeight: 0).items
        cachedItems = items
        return items
    }

    private func save() {
        cachedItems = nil
        let file = File(objects: objects, placements: placements)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func object(id: UUID) -> ScopeObject? {
        objects.first { $0.id == id }
    }

    var visiblePlacements: [ObjectPlacement] { placements.filter { !$0.isHidden } }

    // MARK: - オブジェクト

    /// 新しく作る(同じ ID があれば置き換える)
    func save(_ object: ScopeObject) {
        var object = object
        object.updatedAt = Date()
        if let index = objects.firstIndex(where: { $0.id == object.id }) {
            let oldName = objects[index].name
            objects[index] = object
            // 置いたものの名前が、もとの名前のままなら合わせる
            for i in placements.indices where placements[i].objectID == object.id && placements[i].name == oldName {
                placements[i].name = object.name
            }
        } else {
            objects.append(object)
        }
        save()
    }

    func duplicate(_ id: UUID) {
        guard var copy = object(id: id) else { return }
        copy.id = UUID()
        copy.name += "のコピー"
        objects.append(copy)
        save()
    }

    /// オブジェクトを消す(置いたものも消す)
    func deleteObject(_ id: UUID) {
        objects.removeAll { $0.id == id }
        placements.removeAll { $0.objectID == id }
        save()
    }

    // MARK: - 置いたもの

    /// 地図に置く。地面の標高を取る
    @discardableResult
    func place(objectID: UUID, latitude: Double, longitude: Double) -> ObjectPlacement? {
        guard let object = object(id: objectID) else { return nil }
        let placement = ObjectPlacement(objectID: objectID, name: object.name, latitude: latitude, longitude: longitude)
        placements.append(placement)
        save()
        Task { await fetchElevation(for: placement.id) }
        return placement
    }

    /// 変える。位置を変えたら、地面の標高を取り直す
    func update(_ placement: ObjectPlacement) {
        guard let index = placements.firstIndex(where: { $0.id == placement.id }) else { return }
        let moved = WaypointMath.distance(fromLatitude: placements[index].latitude, longitude: placements[index].longitude,
                                          toLatitude: placement.latitude, longitude: placement.longitude) > 1
        var next = placement
        if moved, next.elevationState != .manual {
            next.groundElevation = nil
            next.elevationState = .unset
        }
        placements[index] = next
        save()
        if moved, next.elevationState == .unset { Task { await fetchElevation(for: next.id) } }
    }

    func setHidden(_ id: UUID, hidden: Bool) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        placements[index].isHidden = hidden
        save()
    }

    func deletePlacement(_ id: UUID) {
        placements.removeAll { $0.id == id }
        save()
    }

    /// 地面の標高を取る(既存の標高API)。取れなければ未設定のまま(次に一覧を開いたときにまた試す)
    func fetchElevation(for id: UUID) async {
        guard let elevation, let placement = placements.first(where: { $0.id == id }), !fetching.contains(id) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        let result = await elevation.lookup(latitude: placement.latitude, longitude: placement.longitude)
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .value(let value):
            placements[index].groundElevation = value
            placements[index].elevationState = .fetched
        case .noData:
            placements[index].groundElevation = nil
            placements[index].elevationState = .noData
        case .failed:
            return
        }
        save()
    }

    /// 標高が未設定のものを取る(一覧を開いたとき)
    func fillMissingElevations() async {
        for placement in placements where placement.elevationState == .unset {
            await fetchElevation(for: placement.id)
        }
    }
}

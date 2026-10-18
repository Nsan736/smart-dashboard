import Foundation
import Observation

/// 景色に使うタイルの種類
enum SceneryTileKind: String, CaseIterable {
    /// 標高タイル(PNG)
    case dem
    /// ベクトルタイル提供実験(水部・注記・記号)
    case vector

    var fileExtension: String { self == .dem ? "png" : "pbf" }

    func url(_ key: TileKey) -> URL {
        switch self {
        case .dem: return URL(string: "https://cyberjapandata.gsi.go.jp/xyz/dem_png/\(key.z)/\(key.x)/\(key.y).png")!
        case .vector: return URL(string: "https://cyberjapandata.gsi.go.jp/xyz/experimental_bvmap/\(key.z)/\(key.x)/\(key.y).pbf")!
        }
    }
}

struct SceneryTileRef: Hashable {
    var kind: SceneryTileKind
    var key: TileKey
}

/// 景色のタイルを Application Support/SmartDashboard/tiles/terrain/(dem|vector)/z/x/y に保存する。
/// 404(海の上など、タイルがない所)は空のファイルで覚え、取り直さない。キャッシュの削除では消さない(地図タイルと同じ)。
final class SceneryTileStore: @unchecked Sendable {
    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func defaultRoot() -> URL {
        DiskCache.defaultDirectory("SmartDashboard")
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent("terrain", isDirectory: true)
    }

    func url(for tile: SceneryTileRef) -> URL {
        root.appendingPathComponent(tile.kind.rawValue, isDirectory: true)
            .appendingPathComponent("\(tile.key.z)", isDirectory: true)
            .appendingPathComponent("\(tile.key.x)", isDirectory: true)
            .appendingPathComponent("\(tile.key.y).\(tile.kind.fileExtension)")
    }

    func exists(_ tile: SceneryTileRef) -> Bool {
        fileManager.fileExists(atPath: url(for: tile).path)
    }

    func data(for tile: SceneryTileRef) -> Data? {
        try? Data(contentsOf: url(for: tile))
    }

    func save(_ data: Data, for tile: SceneryTileRef) throws {
        let target = url(for: tile)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    func removeAll() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func usage() -> (bytes: Int64, count: Int) {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        var bytes: Int64 = 0
        var count = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            count += 1
        }
        return (bytes, count)
    }

    /// その場所の景色に必要なタイル(標高はズーム12・10・9、水部と注記はズーム8)
    static func needed(latitude: Double, longitude: Double, radius: Double, includesVector: Bool) -> [SceneryTileRef] {
        var result = TerrainGrid.neededTiles(latitude: latitude, longitude: longitude, radius: radius)
            .map { SceneryTileRef(kind: .dem, key: $0) }
        if includesVector {
            result += TileKey.around(latitude: latitude, longitude: longitude, radius: radius, zoom: WaterMap.zoom)
                .map { SceneryTileRef(kind: .vector, key: $0) }
        }
        return result
    }
}

/// 景色の計算の入力
struct SceneryInput: Equatable {
    var latitude: Double
    var longitude: Double
    /// 自分の目の高さ(海面から m)。分からなければ、標高タイルの地面 + 手の高さ
    var observerAltitude: Double?
    var handHeight: Double
    var radius: Double
    var layers: Set<SceneryLayer>
}

/// 景色の計算(標高タイル・ベクトルタイルの読み込み、稜線、水面、山)。メインスレッドの外で行い、読み込んだタイルは覚えておく。
actor SceneryEngine {
    private let store: SceneryTileStore
    private let catalog: [MountainCatalog.Entry]
    private var dem: [TileKey: [Float]] = [:]
    private var vectorKeys: Set<TileKey> = []
    private var water = WaterMap.empty
    private var names: [SceneryPlaceName] = []

    init(store: SceneryTileStore, catalog: [MountainCatalog.Entry]) {
        self.store = store
        self.catalog = catalog
    }

    /// 覚えているタイルを捨てる(新しく保存したタイルを読み直すとき)
    func invalidate() {
        dem = [:]
        vectorKeys = []
        water = .empty
        names = []
    }

    func compute(_ input: SceneryInput) -> SceneryScene {
        let grid = loadTerrain(input)
        let usesVector = input.layers.contains(.water) || input.layers.contains(.places)
        if usesVector { loadVector(input) }
        let ground = grid.sample(latitude: input.latitude, longitude: input.longitude, zoom: 12).height
            ?? grid.sample(latitude: input.latitude, longitude: input.longitude, distance: 0).height
        let eye = input.observerAltitude ?? ((ground ?? 0) + input.handHeight)
        let needsSkyline = !input.layers.isEmpty
        var skyline: Skyline?
        var hits: [WaterHit?] = []
        if needsSkyline {
            var waterSampler: WaterSampling?
            if input.layers.contains(.water) { waterSampler = water }
            let result = SkylineCalculator.compute(latitude: input.latitude, longitude: input.longitude, eye: eye, radius: input.radius,
                                                   terrain: grid, water: waterSampler)
            skyline = result.skyline
            hits = result.water
        }
        let ridges = (input.layers.contains(.skyline) && skyline != nil) ? RidgeExtractor.lines(from: skyline!) : []
        let mountains = input.layers.contains(.mountains)
            ? MountainSelection.select(catalog: catalog, latitude: input.latitude, longitude: input.longitude, eye: eye,
                                       radius: input.radius, skyline: skyline)
            : []
        let bands = input.layers.contains(.water) ? WaterBands.make(hits: hits, step: skyline?.step ?? Skyline.defaultStep, map: water) : []
        let labels = makeLabels(input, eye: eye, grid: grid, skyline: skyline)
        return SceneryScene(latitude: input.latitude, longitude: input.longitude, eye: eye, radius: input.radius, skyline: skyline,
                            ridges: ridges, mountains: mountains, water: bands, labels: labels, coverage: skyline?.coverage ?? 0,
                            computedAt: Date())
    }

    /// 川の名前(30kmまで)と地名(半径まで)。地面の高さで見えるもの(手前の地形に隠れていないもの)だけ。
    private func makeLabels(_ input: SceneryInput, eye: Double, grid: TerrainGrid, skyline: Skyline?) -> [SceneryLabel] {
        var result: [SceneryLabel] = []
        for name in names {
            let wanted = (name.kind == .river && input.layers.contains(.water)) || (name.kind == .place && input.layers.contains(.places))
            guard wanted else { continue }
            let distance = WaypointMath.distance(fromLatitude: input.latitude, longitude: input.longitude,
                                                 toLatitude: name.latitude, longitude: name.longitude)
            let limit = name.kind == .river ? min(30_000, input.radius) : input.radius
            guard distance >= 200, distance <= limit else { continue }
            let bearing = WaypointMath.bearing(fromLatitude: input.latitude, longitude: input.longitude,
                                               toLatitude: name.latitude, longitude: name.longitude)
            let height = grid.sample(latitude: name.latitude, longitude: name.longitude, distance: distance).height ?? 0
            let angle = WaypointElevation.angle(targetAltitude: height, observerAltitude: eye, distance: distance)
            if let skyline, skyline.visibility(bearing: bearing, distance: distance, angle: angle) == .hidden { continue }
            result.append(SceneryLabel(name: name.name, kind: name.kind, bearing: bearing, distance: distance, angle: angle))
        }
        // 描く数を抑える(近いものから、川は20、地名は40まで)
        let sorted = result.sorted { $0.distance < $1.distance }
        return Array(sorted.filter { $0.kind == .river }.prefix(20)) + Array(sorted.filter { $0.kind == .place }.prefix(40))
    }

    private func loadTerrain(_ input: SceneryInput) -> TerrainGrid {
        let keys = TerrainGrid.neededTiles(latitude: input.latitude, longitude: input.longitude, radius: input.radius)
        var next: [TileKey: [Float]] = [:]
        for key in keys {
            if let values = dem[key] {
                next[key] = values
                continue
            }
            guard let data = store.data(for: SceneryTileRef(kind: .dem, key: key)) else { continue }
            // 空のファイルは、タイルがない所(海の上)
            if data.isEmpty {
                next[key] = [Float](repeating: .nan, count: TerrainGrid.tileSize * TerrainGrid.tileSize)
            } else if let values = GSIElevationTile.decode(data) {
                next[key] = values
            }
        }
        // 使わなくなったタイルは捨てる(メモリを抑える)
        dem = next
        return TerrainGrid(tiles: next)
    }

    private func loadVector(_ input: SceneryInput) {
        let keys = Set(TileKey.around(latitude: input.latitude, longitude: input.longitude, radius: input.radius, zoom: WaterMap.zoom)
            .filter { store.exists(SceneryTileRef(kind: .vector, key: $0)) })
        guard keys != vectorKeys else { return }
        var tiles: [TileKey: VectorTile] = [:]
        for key in keys {
            guard let data = store.data(for: SceneryTileRef(kind: .vector, key: key)), !data.isEmpty,
                  let tile = try? VectorTile(data: data, layerNames: ["waterarea", "label", "symbol"]) else { continue }
            tiles[key] = tile
        }
        names = SceneryLabelReader.names(tiles: tiles)
        water = WaterMap.build(tiles: tiles, labels: names)
        vectorKeys = keys
    }
}

/// 景色の表示の状態(カメラ表示と景色の画面が使う)。必要なタイルは、従量制でない回線(Wi-Fiなど)で、画面を開いている間だけ保存する。
/// 計算は、200m以上動いたとき、自分の高さが20m以上変わったとき、範囲や層を変えたとき、タイルを保存し終えたときだけ行う。
@MainActor
@Observable
final class SceneryStore {
    static let recomputeDistance = 200.0
    static let recomputeHeight = 20.0
    static let maxConcurrent = 2

    private(set) var scene: SceneryScene?
    private(set) var isComputing = false
    /// 保存の進み具合
    private(set) var plannedCount = 0
    private(set) var finishedCount = 0
    private(set) var failedCount = 0
    private(set) var isDownloading = false
    /// 保存する必要があるのに、回線や上限のために保存していないタイルの数
    private(set) var waitingCount = 0
    private(set) var storedBytes: Int64 = 0
    private(set) var note: String?

    let catalog = MountainCatalog.bundled
    @ObservationIgnored let store: SceneryTileStore
    @ObservationIgnored private let engine: SceneryEngine
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let tiles: TileDownloader
    @ObservationIgnored private var lastInput: SceneryInput?
    @ObservationIgnored private var pendingInput: SceneryInput?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// 画面を開いている間だけ保存する
    @ObservationIgnored private var activeReasons: Set<String> = []

    init(store: SceneryTileStore, http: HTTPClient, settings: AppSettings, network: NetworkMonitor, tiles: TileDownloader) {
        self.store = store
        self.http = http
        self.settings = settings
        self.network = network
        self.tiles = tiles
        engine = SceneryEngine(store: store, catalog: MountainCatalog.bundled.entries)
        // 地図タイルと合わせた保存の上限に使うので、起動したときに数えておく
        Task { [weak self] in await self?.refreshUsage() }
    }

    var layers: Set<SceneryLayer> { Set(settings.sceneryLayers) }
    var radius: Double { Double(SceneryRadius.clamped(settings.sceneryRadiusKm)) * 1000 }
    var isActive: Bool { !activeReasons.isEmpty }

    /// 地図タイルと合わせた保存の上限を超えたか
    var isOverLimit: Bool { tiles.storedBytes + storedBytes >= tiles.storageLimitBytes }
    var canDownloadNow: Bool { isActive && MapMode.canDownloadTiles(network: network.status) && !isOverLimit }

    func setActive(_ active: Bool, reason: String) {
        let wasActive = isActive
        if active { activeReasons.insert(reason) } else { activeReasons.remove(reason) }
        // 開き直したとき(回線が Wi-Fi に変わっていることがある)は、前の場所で足りないタイルを確かめる
        if active, !wasActive, let input = lastInput { downloadMissing(for: input) }
        if !isActive {
            downloadTask?.cancel()
            downloadTask = nil
            isDownloading = false
        }
    }

    /// 現在地(または仮想の位置)と自分の高さを渡す。条件を満たしたときだけ、計算し直し、足りないタイルを保存する。
    func update(latitude: Double, longitude: Double, observerAltitude: Double?, force: Bool = false) {
        let input = SceneryInput(latitude: latitude, longitude: longitude, observerAltitude: observerAltitude,
                                 handHeight: settings.scopeHandHeight, radius: radius, layers: layers)
        guard force || needsRecompute(input) else { return }
        recompute(input)
        downloadMissing(for: input)
    }

    /// 範囲・層の設定を変えたとき
    func settingsChanged() {
        guard var input = lastInput else { return }
        input.radius = radius
        input.layers = layers
        recompute(input)
        downloadMissing(for: input)
    }

    private func needsRecompute(_ input: SceneryInput) -> Bool {
        guard let last = lastInput else { return true }
        if last.radius != input.radius || last.layers != input.layers { return true }
        let moved = WaypointMath.distance(fromLatitude: last.latitude, longitude: last.longitude,
                                          toLatitude: input.latitude, longitude: input.longitude)
        if moved >= Self.recomputeDistance { return true }
        switch (last.observerAltitude, input.observerAltitude) {
        case (nil, nil): return false
        case (let a?, let b?): return abs(a - b) >= Self.recomputeHeight
        default: return true
        }
    }

    private func recompute(_ input: SceneryInput) {
        lastInput = input
        guard !isComputing else {
            // 計算中に来た依頼は、終わってから最後の1つだけを計算する
            pendingInput = input
            return
        }
        isComputing = true
        let engine = engine
        Task { [weak self] in
            let scene = await engine.compute(input)
            guard let self else { return }
            self.scene = scene
            self.isComputing = false
            if let next = self.pendingInput {
                self.pendingInput = nil
                self.recompute(next)
            }
        }
    }

    // MARK: - 保存

    private func downloadMissing(for input: SceneryInput) {
        let usesVector = input.layers.contains(.water) || input.layers.contains(.places)
        let store = store
        let needed = SceneryTileStore.needed(latitude: input.latitude, longitude: input.longitude, radius: input.radius,
                                             includesVector: usesVector)
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) { needed.filter { !store.exists($0) } }.value
            guard let self else { return }
            self.waitingCount = missing.count
            guard !missing.isEmpty else {
                self.note = nil
                return
            }
            guard self.canDownloadNow else {
                self.note = self.isOverLimit ? "保存の上限に達したため、保存済みの範囲だけで計算しています"
                    : "Wi-Fi などに接続すると、足りない範囲の地形を保存します(今は保存済みの範囲だけで計算しています)"
                return
            }
            self.note = nil
            self.startDownload(missing)
        }
    }

    private func startDownload(_ missing: [SceneryTileRef]) {
        downloadTask?.cancel()
        plannedCount = missing.count
        finishedCount = 0
        failedCount = 0
        isDownloading = true
        let http = http
        let store = store
        downloadTask = Task { [weak self] in
            var queue = missing
            await withTaskGroup(of: (SceneryTileRef, Int64?).self) { group in
                func next() -> SceneryTileRef? { queue.isEmpty ? nil : queue.removeFirst() }
                for _ in 0..<Self.maxConcurrent {
                    if let tile = next() { group.addTask { await Self.fetch(tile, http: http, store: store) } }
                }
                while let (_, bytes) = await group.next() {
                    guard let self, !Task.isCancelled else { group.cancelAll(); break }
                    if let bytes {
                        self.finishedCount += 1
                        self.storedBytes += bytes
                    } else {
                        self.failedCount += 1
                    }
                    // 回線が従量制に変わった・上限に達した・画面を閉じたら止める
                    guard self.canDownloadNow else { group.cancelAll(); break }
                    if let tile = next() { group.addTask { await Self.fetch(tile, http: http, store: store) } }
                }
            }
            // 新しい保存を始めたために止めたときは、状態をそのままにする
            guard let self, !Task.isCancelled else { return }
            self.isDownloading = false
            self.waitingCount = max(0, self.plannedCount - self.finishedCount)
            // 保存したタイルは、次の計算で読み込まれる(読み込み済みのタイルはそのまま使う)
            if let input = self.lastInput { self.recompute(input) }
        }
    }

    /// 1枚を取得して保存する。404 は空のファイルで覚える。失敗したら nil。
    nonisolated static func fetch(_ tile: SceneryTileRef, http: HTTPClient, store: SceneryTileStore) async -> (SceneryTileRef, Int64?) {
        do {
            let data = try await http.get(tile.kind.url(tile.key))
            try store.save(data, for: tile)
            return (tile, Int64(data.count))
        } catch HTTPError.badStatus(404) {
            try? store.save(Data(), for: tile)
            return (tile, 0)
        } catch {
            return (tile, nil)
        }
    }

    func refreshUsage() async {
        let store = store
        storedBytes = await Task.detached(priority: .utility) { store.usage().bytes }.value
    }

    func removeAll() async {
        downloadTask?.cancel()
        let store = store
        await Task.detached(priority: .utility) { store.removeAll() }.value
        await engine.invalidate()
        storedBytes = 0
        scene = nil
        lastInput = nil
    }
}

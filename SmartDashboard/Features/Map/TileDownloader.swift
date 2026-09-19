import Foundation
import Observation

/// 地理院タイルをWi-Fi接続中だけ、少しずつ保存する。
/// アプリがフォアグラウンドにある間だけ動く(バックグラウンド処理は使わない)。
@MainActor
@Observable
final class TileDownloader {
    enum State: Equatable {
        case idle
        case running
        case completed
        case pausedNotWiFi
        case pausedStorageLimit
        case disabled
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "待機中"
            case .running: return "保存中"
            case .completed: return "すべて保存済み"
            case .pausedNotWiFi: return "Wi-Fi接続時のみ保存します(停止中)"
            case .pausedStorageLimit: return "保存容量の上限に達したため停止中"
            case .disabled: return "自動保存はオフです"
            case .failed(let message): return "失敗: \(message)"
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var plannedCount = 0
    private(set) var finishedCount = 0
    private(set) var failedCount = 0
    private(set) var storedBytes: Int64 = 0
    private(set) var storedCount = 0
    /// 保存のたびに増やす。表示中の保存済み地図を描き直す合図に使う。
    private(set) var revision = 0

    @ObservationIgnored let store: TileStore
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var queue: [TileCoord] = []
    @ObservationIgnored private var priorityQueue: [TileCoord] = []
    @ObservationIgnored private var queued: Set<TileCoord> = []
    @ObservationIgnored private var workers: [Task<Void, Never>] = []
    @ObservationIgnored private var planTask: Task<Void, Never>?
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var activeWorkers = 0

    /// サーバーに負荷をかけないよう同時接続は2本まで
    static let maxConcurrent = 2
    static let tileURLTemplate = "https://cyberjapandata.gsi.go.jp/xyz/pale/%d/%d/%d.png"

    init(store: TileStore, http: HTTPClient, settings: AppSettings, network: NetworkMonitor) {
        self.store = store
        self.http = http
        self.settings = settings
        self.network = network
    }

    var storageLimitBytes: Int64 { Int64(settings.tileStorageLimitMB) * 1_000_000 }
    var isOverLimit: Bool { storedBytes >= storageLimitBytes }
    var canDownloadNow: Bool { isForeground && MapMode.canDownloadTiles(network: network.status) }

    static func tileURL(_ tile: TileCoord) -> URL {
        URL(string: String(format: tileURLTemplate, tile.z, tile.x, tile.y))!
    }

    // MARK: - 状態の変化

    /// 起動時、復帰時、回線の変化時、設定の変更時に呼ぶ
    func evaluate(isForeground: Bool) {
        self.isForeground = isForeground
        guard canDownloadNow else {
            stopWorkers()
            if isForeground, !queue.isEmpty || !priorityQueue.isEmpty || state == .running { state = .pausedNotWiFi }
            if isForeground, state == .idle { state = .pausedNotWiFi }
            return
        }
        // 保存中に呼ばれても計画を作り直さない
        if state == .running, activeWorkers > 0 { return }
        if settings.tileAutoDownload {
            planAutoDownload(force: false)
        } else {
            if priorityQueue.isEmpty { state = .disabled }
            startWorkersIfNeeded()
        }
    }

    /// 保存の設定や登録エリアが変わったとき。計画を作り直す。
    func settingsChanged() {
        stopWorkers()
        state = .idle
        evaluate(isForeground: isForeground)
    }

    func refreshUsage() async {
        let store = store
        let usage = await Task.detached(priority: .utility) { store.usage() }.value
        storedBytes = usage.bytes
        storedCount = usage.count
    }

    // MARK: - 保存の計画

    /// 全国の広域と登録エリアのうち、未保存のタイルを並べる
    func planAutoDownload(force: Bool) {
        guard planTask == nil else { return }
        let areas = settings.tileAreas
        let maxZoom = settings.tileMaxZoom
        let store = store
        planTask = Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                let all = TileMath.nationwideTiles() + areas.flatMap { TileMath.areaTiles($0, maxZoom: maxZoom) }
                var seen = Set<TileCoord>()
                return store.missing(from: all.filter { seen.insert($0).inserted })
            }.value
            guard let self else { return }
            self.planTask = nil
            await self.refreshUsage()
            let prioritized = Set(self.priorityQueue)
            self.queue = missing.filter { !prioritized.contains($0) }
            self.queued = Set(self.queue).union(self.priorityQueue)
            self.plannedCount = self.queue.count + self.priorityQueue.count
            self.finishedCount = 0
            self.failedCount = 0
            if self.plannedCount == 0 {
                self.state = .completed
            } else {
                self.startWorkersIfNeeded()
            }
        }
    }

    /// Apple Maps で表示した範囲を優先して保存する(Wi-Fi接続中のみ)
    func enqueueViewedRegion(bounds: GeoBounds, zoom: Int) {
        guard settings.tileSavesViewedRegion, canDownloadNow else { return }
        let z = min(max(zoom, TileMath.sourceZooms.lowerBound), settings.tileMaxZoom)
        let tiles = TileMath.tiles(in: bounds, z: z)
        guard tiles.count <= 64 else { return }
        let store = store
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) { store.missing(from: tiles) }.value
            guard let self else { return }
            let fresh = missing.filter { !self.queued.contains($0) }
            guard !fresh.isEmpty else { return }
            self.priorityQueue.append(contentsOf: fresh)
            self.queued.formUnion(fresh)
            self.plannedCount += fresh.count
            self.startWorkersIfNeeded()
        }
    }

    // MARK: - 削除

    /// そのエリアだけが使っているタイルを削除する(他のエリアと重なる分は残す)
    func deleteTiles(of area: TileArea) async {
        let others = settings.tileAreas.filter { $0.id != area.id }
        let maxZoom = 16
        let store = store
        await Task.detached(priority: .utility) {
            let keep = Set(others.flatMap { TileMath.areaTiles($0, maxZoom: maxZoom) })
            store.remove(TileMath.areaTiles(area, maxZoom: maxZoom).filter { !keep.contains($0) })
        }.value
        revision += 1
        await refreshUsage()
    }

    func deleteAll() async {
        stopWorkers()
        queue = []
        priorityQueue = []
        queued = []
        plannedCount = 0
        finishedCount = 0
        let store = store
        await Task.detached(priority: .utility) { store.removeAll() }.value
        revision += 1
        await refreshUsage()
        state = .idle
    }

    /// すべて削除してから、Wi-Fi接続中なら保存し直す
    func redownloadAll() async {
        await deleteAll()
        if canDownloadNow { planAutoDownload(force: true) } else { state = .pausedNotWiFi }
    }

    // MARK: - ダウンロード

    private func startWorkersIfNeeded() {
        guard activeWorkers == 0, canDownloadNow, !(queue.isEmpty && priorityQueue.isEmpty) else { return }
        guard !isOverLimit else {
            state = .pausedStorageLimit
            return
        }
        state = .running
        generation += 1
        activeWorkers = Self.maxConcurrent
        let current = generation
        for _ in 0..<Self.maxConcurrent {
            workers.append(Task { [weak self] in await self?.workLoop(generation: current) })
        }
    }

    private func stopWorkers() {
        generation += 1
        activeWorkers = 0
        workers.forEach { $0.cancel() }
        workers = []
    }

    private func nextTile() -> TileCoord? {
        if !priorityQueue.isEmpty { return priorityQueue.removeFirst() }
        if settings.tileAutoDownload, !queue.isEmpty { return queue.removeFirst() }
        return nil
    }

    private func workLoop(generation current: Int) async {
        while !Task.isCancelled, current == generation {
            guard canDownloadNow else {
                state = .pausedNotWiFi
                break
            }
            guard !isOverLimit else {
                state = .pausedStorageLimit
                break
            }
            guard let tile = nextTile() else {
                if state == .running { state = settings.tileAutoDownload || !queue.isEmpty ? .completed : .disabled }
                break
            }
            queued.remove(tile)
            let store = store
            do {
                let data = try await http.get(Self.tileURL(tile))
                if Task.isCancelled { break }
                try await Task.detached(priority: .utility) { try store.save(data, for: tile) }.value
                storedBytes += Int64(data.count)
                storedCount += 1
                revision += 1
            } catch HTTPError.badStatus(404) {
                // 海上などタイルが存在しない範囲。空の目印を置いて、次回から取得しない。
                _ = try? await Task.detached(priority: .utility) { try store.save(Data(), for: tile) }.value
            } catch {
                if Task.isCancelled { break }
                failedCount += 1
            }
            finishedCount += 1
            // 少しずつ取得する
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // 止められたのではなく自然に終わったときだけ、動作中の数を減らす
        guard current == generation else { return }
        activeWorkers -= 1
        if activeWorkers <= 0 {
            activeWorkers = 0
            workers = []
        }
    }
}

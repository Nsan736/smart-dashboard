import Foundation
import MapKit
import UIKit

/// レーダーのタイルを取得し、basetime ごとにディスクへキャッシュする。
/// MapKitの描画スレッドから呼ばれるので、状態はロックで守る。
final class RadarTileLoader: @unchecked Sendable {
    private let http: HTTPClient
    private let root: URL
    private let lock = NSLock()
    private var receivedBytes: Int64 = 0
    private var successCount = 0
    private var failureCount = 0
    private var inFlight: [String: Task<Data, Error>] = [:]
    /// 受信量などが変わったときの通知(メインスレッドで呼ぶ)
    var onChange: (@Sendable () -> Void)?

    init(http: HTTPClient, root: URL) {
        self.http = http
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func defaultRoot() -> URL {
        DiskCache.defaultDirectory("SmartDashboard").appendingPathComponent("radar", isDirectory: true)
    }

    var stats: (receivedBytes: Int64, successCount: Int, failureCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (receivedBytes, successCount, failureCount)
    }

    func resetStats() {
        lock.lock()
        receivedBytes = 0
        successCount = 0
        failureCount = 0
        lock.unlock()
    }

    /// 時刻一覧のJSONなど、タイル以外の受信量も加える
    func addReceived(_ bytes: Int) {
        lock.lock()
        receivedBytes += Int64(bytes)
        lock.unlock()
    }

    private func fileURL(frame: RadarFrame, tile: TileCoord) -> URL {
        root.appendingPathComponent(frame.basetime, isDirectory: true)
            .appendingPathComponent(frame.validtime, isDirectory: true)
            .appendingPathComponent("\(tile.z)_\(tile.x)_\(tile.y).png")
    }

    /// 同じ basetime のタイルはキャッシュを使い回す。
    /// 拡大表示では複数のタイルが同じ取得元を使うので、取得中のものは1本にまとめる。
    func data(frame: RadarFrame, tile: TileCoord) async throws -> Data {
        let file = fileURL(frame: frame, tile: tile)
        if let cached = try? Data(contentsOf: file) { return cached }
        let key = file.path
        let task: Task<Data, Error> = lock.withLock {
            if let running = inFlight[key] { return running }
            let created = Task { [self] in try await download(frame: frame, tile: tile, to: file) }
            inFlight[key] = created
            return created
        }
        defer { lock.withLock { inFlight[key] = nil } }
        return try await task.value
    }

    private func download(frame: RadarFrame, tile: TileCoord, to file: URL) async throws -> Data {
        do {
            let data = try await http.get(RadarTiles.url(frame: frame, tile: tile))
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            lock.withLock {
                receivedBytes += Int64(data.count)
                successCount += 1
            }
            notify()
            return data
        } catch {
            lock.withLock { failureCount += 1 }
            notify()
            throw error
        }
    }

    private func notify() {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange() }
    }

    /// 使わなくなった basetime のキャッシュを削除する
    func purge(keeping basetimes: Set<String>) {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for item in items where !basetimes.contains(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }

    func removeAll() {
        purge(keeping: [])
    }
}

/// 地図に重ねるレーダーのオーバーレイ。取得できないズームでは、近い偶数ズームのタイルを拡大して描く。
final class RadarTileOverlay: MKTileOverlay {
    let frame: RadarFrame
    private let loader: RadarTileLoader

    init(frame: RadarFrame, loader: RadarTileLoader) {
        self.frame = frame
        self.loader = loader
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = 3
        maximumZ = 18
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let tile = TileCoord(z: path.z, x: path.x, y: path.y)
        guard let source = RadarTiles.source(for: tile) else {
            result(nil, nil)
            return
        }
        let frame = frame
        let loader = loader
        Task.detached(priority: .userInitiated) {
            do {
                let data = try await loader.data(frame: frame, tile: source.tile)
                if source.tile == tile {
                    result(data, nil)
                } else {
                    result(Self.crop(data, unitRect: source.unitRect) ?? data, nil)
                }
            } catch {
                result(nil, error)
            }
        }
    }

    /// 取得元のタイルの一部を切り出して256pxに拡大する
    private static func crop(_ data: Data, unitRect: CGRect) -> Data? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(x: unitRect.minX * width, y: unitRect.minY * height,
                          width: max(1, unitRect.width * width), height: max(1, unitRect.height * height))
        guard let cropped = image.cropping(to: rect) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
        return renderer.pngData { context in
            context.cgContext.interpolationQuality = .none
            UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
    }
}

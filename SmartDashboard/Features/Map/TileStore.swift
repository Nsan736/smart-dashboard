import Foundation

/// 地理院タイルを Application Support 以下に z/x/y.png で保存する。
/// 読み込みは地図の描画スレッドから同期的に呼ばれるので、ファイル操作だけのスレッド安全なクラスにしている。
final class TileStore: @unchecked Sendable {
    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func defaultRoot() -> URL {
        DiskCache.defaultDirectory("SmartDashboard")
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent("pale", isDirectory: true)
    }

    func url(for tile: TileCoord) -> URL {
        root.appendingPathComponent("\(tile.z)", isDirectory: true)
            .appendingPathComponent("\(tile.x)", isDirectory: true)
            .appendingPathComponent("\(tile.y).png")
    }

    func exists(_ tile: TileCoord) -> Bool {
        fileManager.fileExists(atPath: url(for: tile).path)
    }

    func data(for tile: TileCoord) -> Data? {
        try? Data(contentsOf: url(for: tile))
    }

    func save(_ data: Data, for tile: TileCoord) throws {
        let target = url(for: tile)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    /// 保存済みのものを除いた一覧を返す
    func missing(from tiles: [TileCoord]) -> [TileCoord] {
        tiles.filter { !exists($0) }
    }

    @discardableResult
    func remove(_ tiles: [TileCoord]) -> Int {
        var removed = 0
        for tile in tiles where exists(tile) {
            if (try? fileManager.removeItem(at: url(for: tile))) != nil { removed += 1 }
        }
        return removed
    }

    func removeAll() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 保存済みの合計(バイト)と枚数
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
}

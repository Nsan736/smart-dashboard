import Foundation

/// 取得時刻付きのキャッシュ値
struct CachedValue<T: Codable>: Codable {
    let value: T
    let fetchedAt: Date
}

extension CachedValue: Equatable where T: Equatable {}

/// Application Support以下にJSONで保存するキャッシュ
actor DiskCache {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func defaultDirectory(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(name, isDirectory: true)
    }

    func load<T: Codable>(_ type: T.Type, key: String) -> CachedValue<T>? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? decoder.decode(CachedValue<T>.self, from: data)
    }

    func save<T: Codable>(_ value: T, key: String, fetchedAt: Date) throws {
        let data = try encoder.encode(CachedValue(value: value, fetchedAt: fetchedAt))
        try data.write(to: url(for: key), options: .atomic)
    }

    func remove(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    func removeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    func totalSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func url(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }
}

import CoreGraphics
import Darwin
import Foundation
import JavaScriptCore

/// ツールごとの小さな保存領域(キーと、JSON で表した値)。スクリプトの専用のスレッドだけで使う。
/// ファイルは一時ファイルに書いてから置き換える(.atomic)ので、書き込みの途中で落ちても前の内容が残る。
final class ScriptStorage {
    static let maxBytes = 256 * 1024
    static let maxKeyLength = 100
    static let maxKeys = 1000
    /// 書き込みをまとめる間隔(秒)。毎コマ値を変えても、ファイルに書くのはこの間隔ごと。
    static let flushInterval: TimeInterval = 2

    private(set) var values: [String: String] = [:]
    /// nil なら端末に保存しない(プレビューと試しの実行)
    let fileURL: URL?
    private var dirty = false
    private var lastFlush = Date.distantPast

    init(fileURL: URL?) {
        self.fileURL = fileURL
        // 読めないファイル(ふつうは起きない)は空として扱い、書き換えるまでファイルには触らない
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            values = saved
        }
    }

    var byteCount: Int { values.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } }

    func get(_ key: String) -> String? { values[key] }

    var keys: [String] { values.keys.sorted() }

    /// value が nil なら消す。上限を超えるときは書かずに理由を返す。
    func set(_ key: String, _ value: String?) -> String? {
        guard !key.isEmpty, key.count <= Self.maxKeyLength else { return "storage: キーは1〜\(Self.maxKeyLength)文字にしてください" }
        guard let value else {
            if values.removeValue(forKey: key) != nil { dirty = true }
            return nil
        }
        if values[key] == nil, values.count >= Self.maxKeys { return "storage: キーは\(Self.maxKeys)個までです" }
        let newSize = byteCount - (values[key].map { key.utf8.count + $0.utf8.count } ?? 0) + key.utf8.count + value.utf8.count
        guard newSize <= Self.maxBytes else { return "storage: 保存領域の上限(\(Self.maxBytes / 1024)KB)を超えます" }
        values[key] = value
        dirty = true
        return nil
    }

    func clear() {
        guard !values.isEmpty else { return }
        values = [:]
        dirty = true
    }

    /// 前に書いてから flushInterval たっていれば書く
    func flushIfNeeded(now: Date = Date()) {
        guard dirty, now.timeIntervalSince(lastFlush) >= Self.flushInterval else { return }
        flush(now: now)
    }

    func flush(now: Date = Date()) {
        guard dirty, let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(values)
            try data.write(to: fileURL, options: .atomic)
            dirty = false
            lastFlush = now
        } catch {
            // 書けなかったときは、次の機会にもう一度書く
        }
    }

    /// ツールの保存領域のファイル(Application Support/script-storage/ツールのID.json)
    static func storageURL(toolID: String, directory: URL) -> URL {
        let safe = toolID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe + ".json")
    }
}

/// スクリプトが作った画像(ピクセルの配列から)。上限を超えるものは作らない。スクリプトの専用のスレッドだけで使う。
final class ScriptImageStore {
    static let maxImages = 32
    static let maxSide = 1024
    /// すべての画像のピクセルの合計(バイト)
    static let maxTotalBytes = 32 * 1024 * 1024

    private(set) var images: [Int: CGImage] = [:]
    private var nextID = 1
    /// 前に渡してから変わったか
    private(set) var changed = false

    var totalBytes: Int { images.values.reduce(0) { $0 + $1.width * $1.height * 4 } }

    /// 大きさと数の上限を確かめる。作れないときは理由。
    func check(width: Int, height: Int, replacing id: Int? = nil) -> String? {
        guard width >= 1, height >= 1, width <= Self.maxSide, height <= Self.maxSide else {
            return "image: 大きさは 1〜\(Self.maxSide)px にしてください(\(width)×\(height))"
        }
        if id == nil, images.count >= Self.maxImages { return "image: 画像は\(Self.maxImages)枚までです(image.release で減らせます)" }
        let current = id.flatMap { images[$0] }.map { $0.width * $0.height * 4 } ?? 0
        if totalBytes - current + width * height * 4 > Self.maxTotalBytes {
            return "image: 画像の合計の大きさが上限(\(Self.maxTotalBytes / 1024 / 1024)MB)を超えます"
        }
        return nil
    }

    /// RGBA(1ピクセル4バイト、乗算済みでない)のバイト列から作る
    static func makeImage(width: Int, height: Int, bytes: Data) -> CGImage? {
        guard bytes.count == width * height * 4, let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func create(width: Int, height: Int, bytes: Data) -> Result<Int, ScriptImageError> {
        if let problem = check(width: width, height: height) { return .failure(ScriptImageError(message: problem)) }
        guard let image = Self.makeImage(width: width, height: height, bytes: bytes) else {
            return .failure(ScriptImageError(message: "image: 画像を作れませんでした"))
        }
        let id = nextID
        nextID += 1
        images[id] = image
        changed = true
        return .success(id)
    }

    func update(id: Int, bytes: Data) -> String? {
        guard let old = images[id] else { return "image: その画像はありません" }
        guard let image = Self.makeImage(width: old.width, height: old.height, bytes: bytes) else { return "image: 画像を作れませんでした" }
        images[id] = image
        changed = true
        return nil
    }

    func release(id: Int) {
        if images.removeValue(forKey: id) != nil { changed = true }
    }

    /// 変わっていれば、今の画像の一覧を返す(画面に渡す)
    func takeChanges() -> [Int: CGImage]? {
        guard changed else { return nil }
        changed = false
        return images
    }
}

struct ScriptImageError: Error, Equatable {
    var message: String
}

/// 「実行中のツール」の記録。実行を始める前に書き、正常に閉じたら消す。
/// 次に起動したときに残っていれば、そのツールの実行中にアプリが止まった(固まって終了した、メモリの使いすぎで落ちた)とみなす。
struct ScriptRunRecord: Codable, Equatable, Identifiable {
    var toolID: String
    var name: String
    var startedAt: Date
    /// 保存する前のプレビュー(ツールの一覧にはない)
    var isPreview: Bool
    var id: String { toolID + String(startedAt.timeIntervalSince1970) }
}

struct ScriptRunGuard {
    let fileURL: URL

    func begin(_ record: ScriptRunRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    func end() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 残っている記録(読めないものは無いとみなす)
    func load() -> ScriptRunRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ScriptRunRecord.self, from: data)
    }
}

/// JavaScriptCore の実行時間の制限。公開のヘッダーにない関数(JSContextGroupSetExecutionTimeLimit)なので、
/// 実行時に dlsym で探し、見つかったときだけ使う(見つからなければ、監視だけで動く)。利用者の判断で使うことにした(v0.9.19)。
enum ScriptTimeLimit {
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, OpaquePointer?, UnsafeMutableRawPointer?) -> Void

    private static let setLimit: SetLimit? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    static var isAvailable: Bool { setLimit != nil }

    /// 1回の呼び出し(setup・frame など)が seconds を超えたら、スクリプトを打ち切る。使えたら true。
    @discardableResult
    static func apply(to context: JSContext, seconds: Double) -> Bool {
        guard let setLimit else { return false }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        // コールバックなし: 時間になったら、無条件に打ち切る
        setLimit(group, seconds, nil, nil)
        return true
    }
}

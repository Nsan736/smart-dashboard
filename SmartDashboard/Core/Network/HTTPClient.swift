import Foundation

/// すべての通信はこのプロトコルを経由する。テストではスタブに差し替える。
protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
    /// 状態コードが200番台でなくても、本文と状態コードを返す(エラーの内容を表示したいとき)
    func response(_ url: URL) async throws -> (data: Data, status: Int)
    /// 組み立てたリクエスト(POST など)を送る。状態コードが200番台でなくても、本文と状態コードを返す。
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
    /// 応答を1行ずつ受け取る(SSE のストリーミング)。200番台でなければ、行は渡さず、本文を errorBody で返す。
    func stream(_ request: URLRequest, onLine: @escaping @Sendable (String) -> Void) async throws -> (status: Int, errorBody: Data)
}

extension HTTPClient {
    func response(_ url: URL) async throws -> (data: Data, status: Int) {
        (try await get(url), 200)
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        throw HTTPError.notHTTP
    }

    /// 初期の実装: まとめて受け取ってから行に分ける(テスト用の差し替えなど)
    func stream(_ request: URLRequest, onLine: @escaping @Sendable (String) -> Void) async throws -> (status: Int, errorBody: Data) {
        let (data, status) = try await send(request)
        guard (200..<300).contains(status) else { return (status, data) }
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).forEach { onLine(String($0)) }
        return (status, Data())
    }
}

enum HTTPError: LocalizedError, Equatable {
    case badStatus(Int)
    case notHTTP

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "サーバーがエラーを返しました (HTTP \(code))"
        case .notHTTP: return "不正な応答です"
        }
    }
}

/// 受信バイト数を、通信1回ごとに回線と機能を判定して計測するHTTPクライアント。
/// URLCacheは使わず、キャッシュはDiskCacheに一本化する。
final class MeteredHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let onReceived: @Sendable (UsageRecord) -> Void
    private var session: URLSession!

    init(onReceived: @escaping @Sendable (UsageRecord) -> Void) {
        self.onReceived = onReceived
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate, br"]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func get(_ url: URL) async throws -> Data {
        let (data, status) = try await response(url)
        guard (200..<300).contains(status) else { throw HTTPError.badStatus(status) }
        return data
    }

    func response(_ url: URL) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return try await send(request)
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        return (data, http.statusCode)
    }

    func stream(_ request: URLRequest, onLine: @escaping @Sendable (String) -> Void) async throws -> (status: Int, errorBody: Data) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 100_000 { break }
            }
            return (http.statusCode, body)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            onLine(line)
        }
        return (http.statusCode, Data())
    }

    /// モバイル通信のほか、テザリングなど従量制の回線もモバイル通信として数える
    static func link(isCellular: Bool, isExpensive: Bool) -> UsageLink {
        isCellular || isExpensive ? .cellular : .wifi
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let category = UsageCategory.from(url: task.originalRequest?.url)
        var totals: [UsageLink: Int64] = [:]
        for t in metrics.transactionMetrics {
            var bytes = t.countOfResponseHeaderBytesReceived + t.countOfResponseBodyBytesReceived
            // Claude API は送る画像のほうが大きいので、送信量も数える
            if category.countsSentBytes { bytes += t.countOfRequestHeaderBytesSent + t.countOfRequestBodyBytesSent }
            guard bytes > 0 else { continue }
            totals[Self.link(isCellular: t.isCellular, isExpensive: t.isExpensive), default: 0] += bytes
        }
        for (link, bytes) in totals {
            onReceived(UsageRecord(bytes: bytes, link: link, category: category))
        }
    }
}

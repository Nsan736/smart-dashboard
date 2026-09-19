import Foundation

/// すべての通信はこのプロトコルを経由する。テストではスタブに差し替える。
protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
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

/// 受信バイト数を計測するHTTPクライアント。
/// URLCacheは使わず、キャッシュはDiskCacheに一本化する。
final class MeteredHTTPClient: NSObject, HTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private let onBytesReceived: @Sendable (Int64) -> Void
    private var session: URLSession!

    init(onBytesReceived: @escaping @Sendable (Int64) -> Void) {
        self.onBytesReceived = onBytesReceived
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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.badStatus(http.statusCode) }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        var total: Int64 = 0
        for t in metrics.transactionMetrics {
            total += t.countOfResponseHeaderBytesReceived + t.countOfResponseBodyBytesReceived
        }
        if total > 0 { onBytesReceived(total) }
    }
}

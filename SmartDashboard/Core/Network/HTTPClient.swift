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
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.badStatus(http.statusCode) }
        return data
    }

    /// モバイル通信のほか、テザリングなど従量制の回線もモバイル通信として数える
    static func link(isCellular: Bool, isExpensive: Bool) -> UsageLink {
        isCellular || isExpensive ? .cellular : .wifi
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let category = UsageCategory.from(url: task.originalRequest?.url)
        var totals: [UsageLink: Int64] = [:]
        for t in metrics.transactionMetrics {
            let bytes = t.countOfResponseHeaderBytesReceived + t.countOfResponseBodyBytesReceived
            guard bytes > 0 else { continue }
            totals[Self.link(isCellular: t.isCellular, isExpensive: t.isExpensive), default: 0] += bytes
        }
        for (link, bytes) in totals {
            onReceived(UsageRecord(bytes: bytes, link: link, category: category))
        }
    }
}

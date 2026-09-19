import Foundation
import Observation

/// 地図に重ねるレーダーの指定
struct RadarLayer {
    let frame: RadarFrame
    let loader: RadarTileLoader
}

/// 雨雲レーダー。画面を開いたときと手動更新のときだけ通信し、自動更新はしない。
@MainActor
@Observable
final class RadarStore {
    static let failureMessage = "レーダーを取得できませんでした（気象庁側の仕様変更の可能性）"

    private(set) var frames: [RadarFrame] = []
    var selectedIndex = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// この画面を開いてから受信した量(時刻一覧とタイルの本文の合計)
    private(set) var sessionBytes: Int64 = 0
    private(set) var tileFailures = 0
    private(set) var tileSuccesses = 0
    private(set) var isPlaying = false

    @ObservationIgnored let loader: RadarTileLoader
    @ObservationIgnored private let http: HTTPClient
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var playTask: Task<Void, Never>?

    init(http: HTTPClient, network: NetworkMonitor, loader: RadarTileLoader) {
        self.http = http
        self.network = network
        self.loader = loader
    }

    var selectedFrame: RadarFrame? { frames[safe: selectedIndex] }

    var layer: RadarLayer? {
        selectedFrame.map { RadarLayer(frame: $0, loader: loader) }
    }

    /// タイルが1枚も取れず失敗だけが続いているとき
    var tilesLookBroken: Bool { tileFailures >= 3 && tileSuccesses == 0 }

    /// 画面を開いたとき。受信量の表示を0に戻し、最新の実況1枚だけを表示する。
    func open() async {
        loader.resetStats()
        loader.onChange = { [weak self] in
            Task { @MainActor in self?.syncStats() }
        }
        syncStats()
        await reload()
    }

    func close() {
        stopPlaying()
        loader.onChange = nil
    }

    /// 手動の更新ボタン
    func reload() async {
        guard !isLoading else { return }
        stopPlaying()
        guard network.status.isOnline else {
            errorMessage = "オフラインのためレーダーを取得できません"
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let observedData = try await http.get(RadarTimeline.observedURL)
            loader.addReceived(observedData.count)
            let observed = try JSONDecoder().decode([RadarTargetTime].self, from: observedData)
            guard let latest = RadarTimeline.latestObserved(observed) else {
                errorMessage = Self.failureMessage
                return
            }
            // 予測の一覧は1KBほど。コマの時刻を並べるために取得するが、予測のタイルは表示するまで取得しない。
            var forecasts: [RadarFrame] = []
            if let forecastData = try? await http.get(RadarTimeline.forecastURL) {
                loader.addReceived(forecastData.count)
                if let list = try? JSONDecoder().decode([RadarTargetTime].self, from: forecastData) {
                    forecasts = RadarTimeline.forecasts(list, after: latest)
                }
            }
            frames = [latest] + forecasts
            selectedIndex = 0
            // basetime が変わったら古いキャッシュを削除する
            let keep = Set(frames.map(\.basetime))
            let loader = loader
            Task.detached(priority: .utility) { loader.purge(keeping: keep) }
        } catch {
            errorMessage = Self.failureMessage
        }
        syncStats()
    }

    func togglePlaying() {
        if isPlaying {
            stopPlaying()
            return
        }
        guard frames.count > 1 else { return }
        isPlaying = true
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self, !Task.isCancelled else { return }
                self.selectedIndex = (self.selectedIndex + 1) % self.frames.count
            }
        }
    }

    func stopPlaying() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }

    private func syncStats() {
        let stats = loader.stats
        sessionBytes = stats.receivedBytes
        tileSuccesses = stats.successCount
        tileFailures = stats.failureCount
    }

    static func label(for frame: RadarFrame, latest: RadarFrame?) -> String {
        guard let date = frame.date else { return frame.validtime }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "H:mm"
        let time = f.string(from: date)
        guard frame.isForecast else { return "実況 \(time)" }
        if let base = latest?.date {
            return "予測 \(time) (+\(Int(date.timeIntervalSince(base) / 60))分)"
        }
        return "予測 \(time)"
    }
}

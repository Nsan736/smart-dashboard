import Foundation
import Network
import Observation

/// 自動更新の可否を判断するためのネットワーク状態
struct NetworkStatus: Equatable {
    var isOnline: Bool
    var isExpensive: Bool
    var isConstrained: Bool
    var isWiFi: Bool

    /// 回線の状態が分かるまでの値。省データ扱いにして、判明するまで自動更新と地図の読み込みをしない。
    static let unknown = NetworkStatus(isOnline: true, isExpensive: true, isConstrained: true, isWiFi: false)
}

@MainActor
@Observable
final class NetworkMonitor {
    private(set) var status: NetworkStatus = .unknown

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let status = NetworkStatus(
                isOnline: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                isWiFi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            )
            Task { @MainActor in self?.status = status }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    var summary: String {
        if !status.isOnline { return "オフライン" }
        var parts = [status.isWiFi ? "Wi-Fi" : "モバイル回線など"]
        if status.isExpensive { parts.append("従量制") }
        if status.isConstrained { parts.append("省データモード") }
        return parts.joined(separator: "・")
    }
}

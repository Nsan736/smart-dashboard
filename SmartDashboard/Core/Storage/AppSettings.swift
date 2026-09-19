import Foundation
import Observation

/// UserDefaultsに保存する設定。機能ごとの項目は各段階で追加する。
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var wifiOnlyAutoRefresh: Bool {
        didSet { defaults.set(wifiOnlyAutoRefresh, forKey: Keys.wifiOnlyAutoRefresh) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wifiOnlyAutoRefresh = defaults.bool(forKey: Keys.wifiOnlyAutoRefresh)
    }

    var refreshPolicy: RefreshPolicy { RefreshPolicy(wifiOnly: wifiOnlyAutoRefresh) }

    private enum Keys {
        static let wifiOnlyAutoRefresh = "settings.wifiOnlyAutoRefresh"
    }
}

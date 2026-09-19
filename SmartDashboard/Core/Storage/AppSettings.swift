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

    /// 天気: trueなら現在地、falseなら selectedPlaceID の登録地点を使う
    var weatherUsesCurrentLocation: Bool {
        didSet { defaults.set(weatherUsesCurrentLocation, forKey: Keys.weatherUsesCurrentLocation) }
    }
    var places: [SavedPlace] {
        didSet { saveJSON(places, forKey: Keys.places) }
    }
    var selectedPlaceID: UUID? {
        didSet { defaults.set(selectedPlaceID?.uuidString, forKey: Keys.selectedPlaceID) }
    }

    /// 為替: 表示する通貨コード
    var exchangeCodes: [String] {
        didSet { defaults.set(exchangeCodes, forKey: Keys.exchangeCodes) }
    }

    static let defaultExchangeCodes = ["USD", "EUR", "GBP", "CNY", "KRW"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wifiOnlyAutoRefresh = defaults.bool(forKey: Keys.wifiOnlyAutoRefresh)
        weatherUsesCurrentLocation = defaults.object(forKey: Keys.weatherUsesCurrentLocation) as? Bool ?? true
        places = Self.loadJSON([SavedPlace].self, from: defaults, forKey: Keys.places) ?? []
        selectedPlaceID = defaults.string(forKey: Keys.selectedPlaceID).flatMap(UUID.init(uuidString:))
        exchangeCodes = defaults.stringArray(forKey: Keys.exchangeCodes) ?? Self.defaultExchangeCodes
    }

    var refreshPolicy: RefreshPolicy { RefreshPolicy(wifiOnly: wifiOnlyAutoRefresh) }

    var selectedPlace: SavedPlace? {
        places.first { $0.id == selectedPlaceID } ?? places.first
    }

    private func saveJSON<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private enum Keys {
        static let wifiOnlyAutoRefresh = "settings.wifiOnlyAutoRefresh"
        static let weatherUsesCurrentLocation = "weather.usesCurrentLocation"
        static let places = "weather.places"
        static let selectedPlaceID = "weather.selectedPlaceID"
        static let exchangeCodes = "exchange.codes"
    }
}

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

    /// 地図: モバイル通信時も Apple Maps を使う(初期値はオフ)
    var mapUsesAppleOnCellular: Bool {
        didSet { defaults.set(mapUsesAppleOnCellular, forKey: Keys.mapUsesAppleOnCellular) }
    }
    /// 地図: Wi-Fi接続中に未保存のタイルを自動で保存する
    var tileAutoDownload: Bool {
        didSet { defaults.set(tileAutoDownload, forKey: Keys.tileAutoDownload) }
    }
    /// 地図: Wi-Fi接続中に Apple Maps で表示した範囲も保存する
    var tileSavesViewedRegion: Bool {
        didSet { defaults.set(tileSavesViewedRegion, forKey: Keys.tileSavesViewedRegion) }
    }
    /// 地図: 登録エリアを保存する最大ズーム(14〜16)
    var tileMaxZoom: Int {
        didSet { defaults.set(tileMaxZoom, forKey: Keys.tileMaxZoom) }
    }
    /// 地図: 保存容量の上限(MB)
    var tileStorageLimitMB: Int {
        didSet { defaults.set(tileStorageLimitMB, forKey: Keys.tileStorageLimitMB) }
    }
    var tileAreas: [TileArea] {
        didSet { saveJSON(tileAreas, forKey: Keys.tileAreas) }
    }
    /// 最初の登録エリア(現在地から半径20km)を作成済みか
    var didCreateDefaultTileArea: Bool {
        didSet { defaults.set(didCreateDefaultTileArea, forKey: Keys.didCreateDefaultTileArea) }
    }

    static let defaultExchangeCodes = ["USD", "EUR", "GBP", "CNY", "KRW"]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        wifiOnlyAutoRefresh = defaults.bool(forKey: Keys.wifiOnlyAutoRefresh)
        weatherUsesCurrentLocation = defaults.object(forKey: Keys.weatherUsesCurrentLocation) as? Bool ?? true
        places = Self.loadJSON([SavedPlace].self, from: defaults, forKey: Keys.places) ?? []
        selectedPlaceID = defaults.string(forKey: Keys.selectedPlaceID).flatMap(UUID.init(uuidString:))
        exchangeCodes = defaults.stringArray(forKey: Keys.exchangeCodes) ?? Self.defaultExchangeCodes
        mapUsesAppleOnCellular = defaults.bool(forKey: Keys.mapUsesAppleOnCellular)
        tileAutoDownload = defaults.object(forKey: Keys.tileAutoDownload) as? Bool ?? true
        tileSavesViewedRegion = defaults.object(forKey: Keys.tileSavesViewedRegion) as? Bool ?? true
        tileMaxZoom = min(max(defaults.object(forKey: Keys.tileMaxZoom) as? Int ?? 14, 14), 16)
        tileStorageLimitMB = defaults.object(forKey: Keys.tileStorageLimitMB) as? Int ?? 200
        tileAreas = Self.loadJSON([TileArea].self, from: defaults, forKey: Keys.tileAreas) ?? []
        didCreateDefaultTileArea = defaults.bool(forKey: Keys.didCreateDefaultTileArea)
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
        static let mapUsesAppleOnCellular = "map.usesAppleOnCellular"
        static let tileAutoDownload = "map.tileAutoDownload"
        static let tileSavesViewedRegion = "map.tileSavesViewedRegion"
        static let tileMaxZoom = "map.tileMaxZoom"
        static let tileStorageLimitMB = "map.tileStorageLimitMB"
        static let tileAreas = "map.tileAreas"
        static let didCreateDefaultTileArea = "map.didCreateDefaultTileArea"
    }
}

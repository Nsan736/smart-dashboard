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

    /// 今月のモバイル通信量が上限を超えたら自動更新を止める(初期値はオフ)
    var cellularLimitEnabled: Bool {
        didSet { defaults.set(cellularLimitEnabled, forKey: Keys.cellularLimitEnabled) }
    }
    var cellularLimitMB: Int {
        didSet { defaults.set(cellularLimitMB, forKey: Keys.cellularLimitMB) }
    }
    /// 今月のモバイル通信の受信量。DataUsageStore の変化に合わせて AppEnvironment が更新する(保存しない)。
    var monthlyCellularBytes: Int64 = 0

    var cellularLimitReached: Bool {
        cellularLimitEnabled && monthlyCellularBytes >= Int64(cellularLimitMB) * 1_000_000
    }

    /// 電車: 12/30〜1/3 を休日ダイヤとして扱う(初期値はオン)
    var yearEndHolidayTimetable: Bool {
        didSet { defaults.set(yearEndHolidayTimetable, forKey: Keys.yearEndHolidayTimetable) }
    }
    /// 電車: 「今日のダイヤ」の手動切り替え。設定した日だけ有効。
    var timetableOverrideDayKey: String? {
        didSet { defaults.set(timetableOverrideDayKey, forKey: Keys.timetableOverrideDayKey) }
    }
    var timetableOverrideType: DayType? {
        didSet { defaults.set(timetableOverrideType?.rawValue, forKey: Keys.timetableOverrideType) }
    }

    var dayTypeResolver: DayTypeResolver {
        DayTypeResolver(yearEndAsHoliday: yearEndHolidayTimetable, overrideDayKey: timetableOverrideDayKey, overrideType: timetableOverrideType)
    }

    /// 今日のダイヤを手動で切り替える。nilで自動に戻す。
    func setTimetableOverride(_ type: DayType?, now: Date = Date()) {
        timetableOverrideType = type
        timetableOverrideDayKey = type == nil ? nil : DayTypeResolver.dayKey(now)
    }

    /// センサー画面の表示中は画面を消さない(初期値はオン)
    var sensorsKeepAwake: Bool {
        didSet { defaults.set(sensorsKeepAwake, forKey: Keys.sensorsKeepAwake) }
    }
    /// ホームのカードの並び順と表示・非表示
    var homeLayout: HomeLayout {
        didSet { defaults.set(homeLayout.encoded(), forKey: Keys.homeLayout) }
    }

    /// ホームの地震カードに出す最小の震度(P2P地震情報の値。初期値は30=震度3)
    var quakeMinimumScale: Int {
        didSet { defaults.set(quakeMinimumScale, forKey: Keys.quakeMinimumScale) }
    }
    /// 気圧: 3時間でこの値(hPa)以上に下がる予報のとき、ホームのカードを目立たせる(初期値は4)
    var pressureAlertDrop: Double {
        didSet { defaults.set(pressureAlertDrop, forKey: Keys.pressureAlertDrop) }
    }
    /// ウェイポイント: 今向いている方角(例: 北東 45°)を表示する(初期値はオフ)
    var waypointShowsHeading: Bool {
        didSet { defaults.set(waypointShowsHeading, forKey: Keys.waypointShowsHeading) }
    }
    /// 気圧: 無音のオーディオでアプリを起こしておき、バックグラウンドでも記録する(初期値はオフ)
    var backgroundPressureEnabled: Bool {
        didSet { defaults.set(backgroundPressureEnabled, forKey: Keys.backgroundPressureEnabled) }
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
        cellularLimitEnabled = defaults.bool(forKey: Keys.cellularLimitEnabled)
        sensorsKeepAwake = defaults.object(forKey: Keys.sensorsKeepAwake) as? Bool ?? true
        var layout = HomeLayout.decode(defaults.data(forKey: Keys.homeLayout))
        // 以前の設定「ホームで速度を表示する」をオフにしていた場合は、速度のカードを非表示にして引き継ぐ
        if defaults.data(forKey: Keys.homeLayout) == nil, defaults.object(forKey: Keys.homeShowsSpeed) as? Bool == false {
            layout.hidden.insert(.speed)
        }
        homeLayout = layout
        quakeMinimumScale = defaults.object(forKey: Keys.quakeMinimumScale) as? Int ?? 30
        pressureAlertDrop = defaults.object(forKey: Keys.pressureAlertDrop) as? Double ?? 4
        backgroundPressureEnabled = defaults.bool(forKey: Keys.backgroundPressureEnabled)
        waypointShowsHeading = defaults.bool(forKey: Keys.waypointShowsHeading)
        yearEndHolidayTimetable = defaults.object(forKey: Keys.yearEndHolidayTimetable) as? Bool ?? true
        timetableOverrideDayKey = defaults.string(forKey: Keys.timetableOverrideDayKey)
        timetableOverrideType = defaults.string(forKey: Keys.timetableOverrideType).flatMap(DayType.init(rawValue:))
        cellularLimitMB = defaults.object(forKey: Keys.cellularLimitMB) as? Int ?? 100
    }

    var refreshPolicy: RefreshPolicy {
        RefreshPolicy(wifiOnly: wifiOnlyAutoRefresh, cellularLimitReached: cellularLimitReached)
    }

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
        static let cellularLimitEnabled = "usage.cellularLimitEnabled"
        static let sensorsKeepAwake = "sensors.keepAwake"
        static let homeShowsSpeed = "home.showsSpeed"
        static let homeLayout = "home.layout"
        static let quakeMinimumScale = "quake.minimumScale"
        static let pressureAlertDrop = "pressure.alertDrop"
        static let backgroundPressureEnabled = "pressure.backgroundEnabled"
        static let waypointShowsHeading = "waypoint.showsHeading"
        static let yearEndHolidayTimetable = "train.yearEndHolidayTimetable"
        static let timetableOverrideDayKey = "train.timetableOverrideDayKey"
        static let timetableOverrideType = "train.timetableOverrideType"
        static let cellularLimitMB = "usage.cellularLimitMB"
    }
}

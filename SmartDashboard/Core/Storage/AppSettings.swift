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
    /// タブの並び順。先頭の4つがタブバーに並び、残りは「その他」に入る。
    var tabOrder: [AppTab] {
        didSet { defaults.set(tabOrder.map(\.rawValue), forKey: Keys.tabOrder) }
    }
    /// スコープの「周辺」: 探す範囲(m)。初期値は500、最大2000。
    var nearbyRadius: Int {
        didSet { defaults.set(nearbyRadius, forKey: Keys.nearbyRadius) }
    }
    /// スコープの「周辺」: カテゴリの並び順
    var nearbyCategories: [NearbyCategory] {
        didSet { defaults.set(nearbyCategories.map(\.rawValue), forKey: Keys.nearbyCategories) }
    }
    /// スコープ: 今向いている方角(例: 北東 45°)を表示する(初期値はオフ)
    var waypointShowsHeading: Bool {
        didSet { defaults.set(waypointShowsHeading, forKey: Keys.waypointShowsHeading) }
    }
    /// スコープ: 地点の高さを、カメラ表示の印の上下の位置(仰角)に反映する(初期値はオン)
    var scopeUsesHeight: Bool {
        didSet { defaults.set(scopeUsesHeight, forKey: Keys.scopeUsesHeight) }
    }
    /// スコープ: 自分の高さの決め方(初期値は「地面の標高+手の高さ」)
    var scopeHeightSource: ObserverHeightSource {
        didSet { defaults.set(scopeHeightSource.rawValue, forKey: Keys.scopeHeightSource) }
    }
    /// スコープ: 手の高さ(m、初期値1.5)
    var scopeHandHeight: Double {
        didSet { defaults.set(scopeHandHeight, forKey: Keys.scopeHandHeight) }
    }
    /// スコープの電車: 対象の路線(初期値は登録した路線)
    var scopeTrainTarget: ScopeTrainTarget {
        didSet { defaults.set(scopeTrainTarget.rawValue, forKey: Keys.scopeTrainTarget) }
    }
    /// スコープの電車: 「近くを通る路線」の距離(km、初期値3)
    var scopeTrainRadiusKm: Double {
        didSet { defaults.set(scopeTrainRadiusKm, forKey: Keys.scopeTrainRadiusKm) }
    }
    /// スコープの電車: 表示する列車の数の上限(近い順、初期値20)
    var scopeTrainMaxCount: Int {
        didSet { defaults.set(scopeTrainMaxCount, forKey: Keys.scopeTrainMaxCount) }
    }
    /// スコープの電車: 路線の種類ごとの両数の目安(データに両数がないときに使う)。ない種類は初期値。
    var scopeCarCounts: [String: Int] {
        didSet { defaults.set(scopeCarCounts, forKey: Keys.scopeCarCounts) }
    }

    func scopeCars(for kind: RailwayKind) -> Int {
        scopeCarCounts[kind.rawValue] ?? kind.defaultCars
    }
    /// スコープの電車: 路線ごとの両数の上書き(路線ID → 両数)。ない路線は、同梱した両数の表の値。
    var scopeCarOverrides: [String: Int] {
        didSet { defaults.set(scopeCarOverrides, forKey: Keys.scopeCarOverrides) }
    }
    /// スコープの電車: 高架の線路の、地面からの高さの目安(m、初期値8)
    var scopeElevatedHeight: Double {
        didSet { defaults.set(scopeElevatedHeight, forKey: Keys.scopeElevatedHeight) }
    }
    /// スクリプト型のツールを、すべて止める(安全のための切り替え。初期値はオフ)
    var scriptToolsStopped: Bool {
        didSet { defaults.set(scriptToolsStopped, forKey: Keys.scriptToolsStopped) }
    }
    /// 無効にしたスクリプト型のツール(ID)。前回の実行中に止まったツールを「無効にする」と、ここに入る。
    var disabledScriptTools: [String] {
        didSet { defaults.set(disabledScriptTools, forKey: Keys.disabledScriptTools) }
    }
    /// スクリプト型のツールごとの、アプリのデータを読む許可(ツールの画面の「データの許可」で変えられる)
    var scriptPermissions: ScriptPermissionGrants {
        didSet { saveJSON(scriptPermissions, forKey: Keys.scriptPermissions) }
    }

    /// Claude API の設定(モデル、料金、上限、思考、カメラの質問で送る情報)。APIキーは Keychain。
    var claude: ClaudeSettings {
        didSet { saveJSON(claude, forKey: Keys.claude) }
    }
    /// スコープの電車: 地下の線路の、地面からの深さの目安(m、初期値15)
    var scopeUndergroundDepth: Double {
        didSet { defaults.set(scopeUndergroundDepth, forKey: Keys.scopeUndergroundDepth) }
    }
    /// 気圧: 無音のオーディオでアプリを起こしておき、バックグラウンドでも記録する(初期値はオフ)
    var backgroundPressureEnabled: Bool {
        didSet { defaults.set(backgroundPressureEnabled, forKey: Keys.backgroundPressureEnabled) }
    }

    /// 移動: 乗車中の判定(初期値はオン)
    var rideDetectionEnabled: Bool {
        didSet { defaults.set(rideDetectionEnabled, forKey: Keys.rideDetectionEnabled) }
    }
    /// 移動: 記録の保存期間(初期値は今日だけ)
    var movementRetention: MovementRetention {
        didSet { defaults.set(movementRetention.rawValue, forKey: Keys.movementRetention) }
    }
    /// 移動: 駅まで歩く時間の計算(直線距離にかける係数、歩く速さ km/h、駅の中の移動 分)
    var walkRouteFactor: Double {
        didSet { defaults.set(walkRouteFactor, forKey: Keys.walkRouteFactor) }
    }
    var walkSpeedKmh: Double {
        didSet { defaults.set(walkSpeedKmh, forKey: Keys.walkSpeedKmh) }
    }
    var stationAccessMinutes: Double {
        didSet { defaults.set(stationAccessMinutes, forKey: Keys.stationAccessMinutes) }
    }
    /// 移動: 経路の検索での乗り換えの時間(分)
    var transferMinutes: Double {
        didSet { defaults.set(transferMinutes, forKey: Keys.transferMinutes) }
    }

    var walkSettings: WalkSettings {
        WalkSettings(routeFactor: walkRouteFactor, speedKmh: walkSpeedKmh, accessMinutes: stationAccessMinutes)
    }

    /// 開発者向け: 位置のデバッグ(初期値はオフ)
    var movementDebugEnabled: Bool {
        didSet { defaults.set(movementDebugEnabled, forKey: Keys.movementDebugEnabled) }
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
        scopeUsesHeight = defaults.object(forKey: Keys.scopeUsesHeight) as? Bool ?? true
        scopeHeightSource = defaults.string(forKey: Keys.scopeHeightSource).flatMap(ObserverHeightSource.init(rawValue:)) ?? .groundPlusHand
        scopeHandHeight = defaults.object(forKey: Keys.scopeHandHeight) as? Double ?? 1.5
        scopeTrainTarget = defaults.string(forKey: Keys.scopeTrainTarget).flatMap(ScopeTrainTarget.init(rawValue:)) ?? .registered
        scopeTrainRadiusKm = defaults.object(forKey: Keys.scopeTrainRadiusKm) as? Double ?? 3
        scopeTrainMaxCount = defaults.object(forKey: Keys.scopeTrainMaxCount) as? Int ?? 20
        scopeCarCounts = defaults.dictionary(forKey: Keys.scopeCarCounts) as? [String: Int] ?? [:]
        scopeCarOverrides = defaults.dictionary(forKey: Keys.scopeCarOverrides) as? [String: Int] ?? [:]
        scopeElevatedHeight = defaults.object(forKey: Keys.scopeElevatedHeight) as? Double ?? 8
        scopeUndergroundDepth = defaults.object(forKey: Keys.scopeUndergroundDepth) as? Double ?? 15
        claude = Self.loadJSON(ClaudeSettings.self, from: defaults, forKey: Keys.claude) ?? ClaudeSettings()
        scriptToolsStopped = defaults.bool(forKey: Keys.scriptToolsStopped)
        disabledScriptTools = defaults.stringArray(forKey: Keys.disabledScriptTools) ?? []
        scriptPermissions = Self.loadJSON(ScriptPermissionGrants.self, from: defaults, forKey: Keys.scriptPermissions) ?? ScriptPermissionGrants()
        nearbyRadius = NearbyRadius.clamped(defaults.object(forKey: Keys.nearbyRadius) as? Int ?? NearbyRadius.initial)
        nearbyCategories = NearbyCategory.normalizedOrder(defaults.stringArray(forKey: Keys.nearbyCategories))
        tabOrder = TabOrder.decode(defaults.stringArray(forKey: Keys.tabOrder))
        yearEndHolidayTimetable = defaults.object(forKey: Keys.yearEndHolidayTimetable) as? Bool ?? true
        timetableOverrideDayKey = defaults.string(forKey: Keys.timetableOverrideDayKey)
        timetableOverrideType = defaults.string(forKey: Keys.timetableOverrideType).flatMap(DayType.init(rawValue:))
        cellularLimitMB = defaults.object(forKey: Keys.cellularLimitMB) as? Int ?? 100
        rideDetectionEnabled = defaults.object(forKey: Keys.rideDetectionEnabled) as? Bool ?? true
        movementRetention = defaults.string(forKey: Keys.movementRetention).flatMap(MovementRetention.init(rawValue:)) ?? .today
        movementDebugEnabled = defaults.bool(forKey: Keys.movementDebugEnabled)
        walkRouteFactor = defaults.object(forKey: Keys.walkRouteFactor) as? Double ?? 1.3
        walkSpeedKmh = defaults.object(forKey: Keys.walkSpeedKmh) as? Double ?? 4.8
        stationAccessMinutes = defaults.object(forKey: Keys.stationAccessMinutes) as? Double ?? 2
        transferMinutes = defaults.object(forKey: Keys.transferMinutes) as? Double ?? 5
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
        static let scopeUsesHeight = "scope.usesHeight"
        static let scopeHeightSource = "scope.heightSource"
        static let scopeHandHeight = "scope.handHeight"
        static let scopeTrainTarget = "scope.trainTarget"
        static let scopeTrainRadiusKm = "scope.trainRadiusKm"
        static let scopeTrainMaxCount = "scope.trainMaxCount"
        static let scopeCarCounts = "scope.carCounts"
        static let scopeCarOverrides = "scope.carOverrides"
        static let scopeElevatedHeight = "scope.elevatedHeight"
        static let scopeUndergroundDepth = "scope.undergroundDepth"
        static let claude = "claude.settings"
        static let scriptToolsStopped = "tools.scriptStopped"
        static let disabledScriptTools = "tools.scriptDisabled"
        static let scriptPermissions = "tools.scriptPermissions"
        static let nearbyRadius = "scope.nearbyRadius"
        static let nearbyCategories = "scope.nearbyCategories"
        static let tabOrder = "tabs.order"
        static let yearEndHolidayTimetable = "train.yearEndHolidayTimetable"
        static let timetableOverrideDayKey = "train.timetableOverrideDayKey"
        static let timetableOverrideType = "train.timetableOverrideType"
        static let cellularLimitMB = "usage.cellularLimitMB"
        static let rideDetectionEnabled = "movement.rideDetection"
        static let movementRetention = "movement.retention"
        static let movementDebugEnabled = "movement.debug"
        static let walkRouteFactor = "movement.walkRouteFactor"
        static let walkSpeedKmh = "movement.walkSpeedKmh"
        static let stationAccessMinutes = "movement.stationAccessMinutes"
        static let transferMinutes = "movement.transferMinutes"
    }
}

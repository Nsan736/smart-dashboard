import Foundation

/// Open-MeteoのForecast APIの応答(timeformat=unixtime で要求した場合)。
/// 値が欠けることがある配列は要素をOptionalで受ける。
struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let time: TimeInterval
        let temperature_2m: Double
        let apparent_temperature: Double
        let relative_humidity_2m: Double
        let weather_code: Int
        let wind_speed_10m: Double
        let surface_pressure: Double
        let precipitation: Double
    }

    struct Hourly: Decodable {
        let time: [TimeInterval]
        let temperature_2m: [Double?]
        let precipitation_probability: [Double?]
        let weather_code: [Int?]
    }

    struct Daily: Decodable {
        let time: [TimeInterval]
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
        let precipitation_probability_max: [Double?]
        let weather_code: [Int?]
        let sunrise: [TimeInterval?]?
        let sunset: [TimeInterval?]?
        let uv_index_max: [Double?]?
    }

    /// 15分ごとの降水量(mm)
    struct Minutely15: Decodable {
        let time: [TimeInterval]
        let precipitation: [Double?]
    }

    let latitude: Double
    let longitude: Double
    let utc_offset_seconds: Int
    let current: Current
    let minutely_15: Minutely15?
    let hourly: Hourly
    let daily: Daily
}

/// キャッシュと表示に使う天気データ
struct WeatherSnapshot: Codable, Equatable {
    struct Current: Codable, Equatable {
        var time: Date
        var temperature: Double
        var apparentTemperature: Double
        var humidity: Double
        var weatherCode: Int
        var windSpeed: Double
        var pressure: Double
        var precipitation: Double
    }

    struct Hour: Codable, Equatable, Identifiable {
        var time: Date
        var temperature: Double?
        var precipitationProbability: Double?
        var weatherCode: Int?
        var id: Date { time }
    }

    struct Day: Codable, Equatable, Identifiable {
        var date: Date
        var temperatureMax: Double?
        var temperatureMin: Double?
        var precipitationProbability: Double?
        var weatherCode: Int?
        var sunrise: Date?
        var sunset: Date?
        var uvIndexMax: Double?
        var id: Date { date }
    }

    /// 15分ごとの降水量
    struct RainSlot: Codable, Equatable, Identifiable {
        var time: Date
        var precipitation: Double
        var id: Date { time }
    }

    /// "current" または登録地点のID。地点を切り替えたらキャッシュを古いとみなす。
    var sourceID: String
    var placeName: String
    /// 取得に使った座標(小さな地図の表示用)。古いキャッシュにはない。
    var latitude: Double?
    var longitude: Double?
    var utcOffsetSeconds: Int
    var current: Current
    var hourly: [Hour]
    var daily: [Day]
    /// 今後2時間の15分ごとの降水量。古いキャッシュにはない。
    var rain: [RainSlot]?

    init(response r: OpenMeteoResponse, sourceID: String, placeName: String, latitude: Double? = nil, longitude: Double? = nil) {
        self.sourceID = sourceID
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        utcOffsetSeconds = r.utc_offset_seconds
        current = Current(
            time: Date(timeIntervalSince1970: r.current.time),
            temperature: r.current.temperature_2m,
            apparentTemperature: r.current.apparent_temperature,
            humidity: r.current.relative_humidity_2m,
            weatherCode: r.current.weather_code,
            windSpeed: r.current.wind_speed_10m,
            pressure: r.current.surface_pressure,
            precipitation: r.current.precipitation
        )
        hourly = r.hourly.time.enumerated().map { i, t in
            Hour(
                time: Date(timeIntervalSince1970: t),
                temperature: r.hourly.temperature_2m[safe: i] ?? nil,
                precipitationProbability: r.hourly.precipitation_probability[safe: i] ?? nil,
                weatherCode: r.hourly.weather_code[safe: i] ?? nil
            )
        }
        daily = r.daily.time.enumerated().map { i, t in
            Day(
                date: Date(timeIntervalSince1970: t),
                temperatureMax: r.daily.temperature_2m_max[safe: i] ?? nil,
                temperatureMin: r.daily.temperature_2m_min[safe: i] ?? nil,
                precipitationProbability: r.daily.precipitation_probability_max[safe: i] ?? nil,
                weatherCode: r.daily.weather_code[safe: i] ?? nil,
                sunrise: Self.value(r.daily.sunrise, i).map { Date(timeIntervalSince1970: $0) },
                sunset: Self.value(r.daily.sunset, i).map { Date(timeIntervalSince1970: $0) },
                uvIndexMax: Self.value(r.daily.uv_index_max, i)
            )
        }
        rain = r.minutely_15.map { minutely in
            minutely.time.enumerated().map { i, t in
                RainSlot(time: Date(timeIntervalSince1970: t), precipitation: (minutely.precipitation[safe: i] ?? nil) ?? 0)
            }
        }
    }

    /// 省略されることのある配列から、欠損も考慮して値を取り出す
    private static func value<T>(_ array: [T?]?, _ index: Int) -> T? {
        guard let array, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// 現在時刻以降の15分値(最大2時間分)
    func upcomingRain(now: Date) -> [RainSlot] {
        Array((rain ?? []).filter { $0.time.addingTimeInterval(15 * 60) > now }.prefix(8))
    }

    /// 現在時刻以降の予報(キャッシュが古くなっても過去の時間帯を出さない)
    func upcomingHours(now: Date, limit: Int = 24) -> [Hour] {
        Array(hourly.filter { $0.time > now.addingTimeInterval(-3600) }.prefix(limit))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 直近の雨の要約(ホーム用)
enum RainSummary {
    /// 雨とみなす15分あたりの降水量(mm)
    static let threshold = 0.1

    static func text(slots: [WeatherSnapshot.RainSlot], now: Date) -> String? {
        guard !slots.isEmpty else { return nil }
        let rainy = slots.map { $0.precipitation >= threshold }
        guard let first = rainy.firstIndex(of: true) else { return "2時間は雨の予報なし" }
        if first == 0 {
            guard let stop = rainy.firstIndex(of: false) else { return "2時間は雨が続く予報" }
            let minutes = max(0, Int(slots[stop].time.timeIntervalSince(now) / 60))
            return "雨の予報(あと\(roundToFive(minutes))分ほどでやむ見込み)"
        }
        let minutes = max(0, Int(slots[first].time.timeIntervalSince(now) / 60))
        return "\(roundToFive(minutes))分後から雨の予報"
    }

    private static func roundToFive(_ minutes: Int) -> Int {
        max(5, Int((Double(minutes) / 5).rounded()) * 5)
    }
}

/// 登録した地点
struct SavedPlace: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
}

/// WMOの天気コードをSF Symbolsと日本語ラベルに変換する
enum WeatherCode {
    static func label(_ code: Int?) -> String {
        guard let code else { return "不明" }
        switch code {
        case 0: return "快晴"
        case 1: return "晴れ"
        case 2: return "一部曇り"
        case 3: return "曇り"
        case 45, 48: return "霧"
        case 51: return "弱い霧雨"
        case 53: return "霧雨"
        case 55: return "強い霧雨"
        case 56, 57: return "着氷性の霧雨"
        case 61: return "弱い雨"
        case 63: return "雨"
        case 65: return "強い雨"
        case 66, 67: return "着氷性の雨"
        case 71: return "弱い雪"
        case 73: return "雪"
        case 75: return "強い雪"
        case 77: return "霧雪"
        case 80: return "弱いにわか雨"
        case 81: return "にわか雨"
        case 82: return "激しいにわか雨"
        case 85: return "弱いにわか雪"
        case 86: return "強いにわか雪"
        case 95: return "雷雨"
        case 96, 99: return "ひょうを伴う雷雨"
        default: return "不明(\(code))"
        }
    }

    static func symbol(_ code: Int?, isNight: Bool = false) -> String {
        guard let code else { return "questionmark.circle" }
        switch code {
        case 0, 1: return isNight ? "moon.stars.fill" : "sun.max.fill"
        case 2: return isNight ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }
}

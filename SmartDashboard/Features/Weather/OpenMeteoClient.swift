import Foundation

protocol WeatherAPI: Sendable {
    func fetch(latitude: Double, longitude: Double) async throws -> OpenMeteoResponse
}

struct OpenMeteoClient: WeatherAPI {
    let http: HTTPClient

    func fetch(latitude: Double, longitude: Double) async throws -> OpenMeteoResponse {
        let data = try await http.get(Self.makeURL(latitude: latitude, longitude: longitude))
        return try Self.decode(data)
    }

    /// 使う変数だけを指定し、期間も必要な分(15分値は2時間、1時間値は24時間、日別は7日)に絞る。リクエストは1回。
    static func makeURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,surface_pressure,precipitation"),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code,sunrise,sunset,uv_index_max"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "forecast_hours", value: "24"),
            URLQueryItem(name: "forecast_minutely_15", value: "8"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
        ]
        return c.url!
    }

    static func decode(_ data: Data) throws -> OpenMeteoResponse {
        try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
    }
}

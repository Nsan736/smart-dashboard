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

    /// 使う変数だけを指定し、期間も必要な分(24時間・3日)に絞る
    static func makeURL(latitude: Double, longitude: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,surface_pressure,precipitation"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            URLQueryItem(name: "forecast_days", value: "3"),
            URLQueryItem(name: "forecast_hours", value: "24"),
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

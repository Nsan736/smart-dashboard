import XCTest
@testable import SmartDashboard

enum Fixture {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Token.self).url(forResource: name, withExtension: "json"), "fixture \(name).json がありません")
        return try Data(contentsOf: url)
    }
}

final class OpenMeteoDecodingTests: XCTestCase {
    func testDecodeFixture() throws {
        let response = try OpenMeteoClient.decode(Fixture.data("open_meteo"))
        XCTAssertEqual(response.utc_offset_seconds, 32400)
        XCTAssertEqual(response.current.temperature_2m, 21.4)
        XCTAssertEqual(response.current.weather_code, 2)
        XCTAssertEqual(response.current.surface_pressure, 1016.0)
        XCTAssertEqual(response.hourly.time.count, 24)
        XCTAssertEqual(response.daily.time.count, 7)
        XCTAssertEqual(response.minutely_15?.time.count, 8)

        let snapshot = WeatherSnapshot(response: response, sourceID: "current", placeName: "現在地")
        XCTAssertEqual(snapshot.current.humidity, 96)
        XCTAssertEqual(snapshot.hourly.count, 24)
        XCTAssertEqual(snapshot.hourly[0].precipitationProbability, 53)
        XCTAssertEqual(snapshot.daily.count, 7)
        XCTAssertEqual(snapshot.daily[0].sunrise, Date(timeIntervalSince1970: 1789763177))
        XCTAssertEqual(snapshot.daily[0].sunset, Date(timeIntervalSince1970: 1789807381))
        XCTAssertEqual(snapshot.daily[0].uvIndexMax, 5.25)
        XCTAssertEqual(snapshot.rain?.count, 8)
        XCTAssertEqual(snapshot.rain?[3].precipitation, 0.1)
        XCTAssertEqual(snapshot.daily[2].temperatureMax, 26.3)
        XCTAssertEqual(snapshot.daily[1].weatherCode, 65)
    }

    func testNullValuesInArrays() throws {
        let json = """
        {"latitude":35.7,"longitude":139.75,"utc_offset_seconds":32400,
         "current":{"time":1789803000,"temperature_2m":21.3,"apparent_temperature":24.5,"relative_humidity_2m":94,
                    "weather_code":51,"wind_speed_10m":1.61,"surface_pressure":1016.1,"precipitation":0.1},
         "hourly":{"time":[1789801200],"temperature_2m":[null],"precipitation_probability":[null],"weather_code":[null]},
         "daily":{"time":[1789743600],"temperature_2m_max":[22.4],"temperature_2m_min":[null],
                  "precipitation_probability_max":[null],"weather_code":[63]}}
        """
        let response = try OpenMeteoClient.decode(Data(json.utf8))
        let snapshot = WeatherSnapshot(response: response, sourceID: "x", placeName: "x")
        XCTAssertNil(snapshot.hourly[0].temperature)
        XCTAssertNil(snapshot.daily[0].temperatureMin)
        XCTAssertEqual(snapshot.daily[0].weatherCode, 63)
    }

    func testUpcomingHoursDropsPast() throws {
        let response = try OpenMeteoClient.decode(Fixture.data("open_meteo"))
        let snapshot = WeatherSnapshot(response: response, sourceID: "current", placeName: "現在地")
        let now = Date(timeIntervalSince1970: 1789808400 + 3 * 3600 + 600)
        let hours = snapshot.upcomingHours(now: now)
        XCTAssertEqual(hours.first?.time, Date(timeIntervalSince1970: 1789808400 + 3 * 3600))
        XCTAssertEqual(hours.count, 21)
    }

    func testRequestIsNarrowed() {
        let url = OpenMeteoClient.makeURL(latitude: 35.681236, longitude: 139.767125)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["latitude"], "35.68")
        XCTAssertEqual(query["longitude"], "139.77")
        XCTAssertEqual(query["forecast_days"], "7")
        XCTAssertEqual(query["minutely_15"], "precipitation")
        XCTAssertEqual(query["forecast_minutely_15"], "8")
        XCTAssertEqual(query["daily"], "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code,sunrise,sunset,uv_index_max")
        XCTAssertEqual(query["forecast_hours"], "24")
        XCTAssertEqual(query["timeformat"], "unixtime")
        XCTAssertEqual(query["hourly"], "temperature_2m,precipitation_probability,weather_code")
    }

    func testOldCacheWithoutNewFieldsStillDecodes() throws {
        // 区切りCより前に保存されたキャッシュ(座標、15分値、日の出などがない)
        let json = """
        {"sourceID":"current","placeName":"現在地","utcOffsetSeconds":32400,
         "current":{"time":0,"temperature":20,"apparentTemperature":20,"humidity":50,"weatherCode":0,
                    "windSpeed":1,"pressure":1000,"precipitation":0},
         "hourly":[],"daily":[{"date":0,"temperatureMax":25,"weatherCode":1}]}
        """
        let snapshot = try JSONDecoder().decode(WeatherSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.rain)
        XCTAssertNil(snapshot.latitude)
        XCTAssertNil(snapshot.daily[0].sunrise)
        XCTAssertTrue(snapshot.upcomingRain(now: Date()).isEmpty)
    }

    func testRainSummary() throws {
        let response = try OpenMeteoClient.decode(Fixture.data("open_meteo"))
        let snapshot = WeatherSnapshot(response: response, sourceID: "current", placeName: "現在地")
        let start = Date(timeIntervalSince1970: 1789810200)
        // フィクスチャは 0, 0, 0, 0.1, 0.1, 0.1, 0.1, 0 (mm/15分)
        XCTAssertEqual(RainSummary.text(slots: snapshot.upcomingRain(now: start), now: start), "45分後から雨の予報")
        let later = start.addingTimeInterval(50 * 60)
        XCTAssertEqual(snapshot.upcomingRain(now: later).count, 5)
        XCTAssertEqual(RainSummary.text(slots: snapshot.upcomingRain(now: later), now: later), "雨の予報(あと55分ほどでやむ見込み)")

        let dry = (0..<8).map { WeatherSnapshot.RainSlot(time: start.addingTimeInterval(Double($0) * 900), precipitation: 0) }
        XCTAssertEqual(RainSummary.text(slots: dry, now: start), "2時間は雨の予報なし")
        let wet = dry.map { WeatherSnapshot.RainSlot(time: $0.time, precipitation: 1.2) }
        XCTAssertEqual(RainSummary.text(slots: wet, now: start), "2時間は雨が続く予報")
        XCTAssertNil(RainSummary.text(slots: [], now: start))
    }

    func testWeatherCodeLabels() {
        XCTAssertEqual(WeatherCode.label(0), "快晴")
        XCTAssertEqual(WeatherCode.label(63), "雨")
        XCTAssertEqual(WeatherCode.symbol(95), "cloud.bolt.rain.fill")
        XCTAssertEqual(WeatherCode.label(nil), "不明")
    }
}

final class ERAPIDecodingTests: XCTestCase {
    func testDecodeFixtureAndConvert() throws {
        let response = try ERAPIClient.decode(Fixture.data("er_api"))
        XCTAssertEqual(response.base_code, "JPY")
        let rates = try ExchangeRates(response: response)
        XCTAssertEqual(rates.providerUpdatedAt, Date(timeIntervalSince1970: 1789776151))
        XCTAssertEqual(rates.nextUpdateAt, Date(timeIntervalSince1970: 1789863261))

        let usd = try XCTUnwrap(rates.yenPerUnit("USD"))
        XCTAssertEqual(usd, 1 / 0.006367, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(rates.toYen(100, from: "USD")), 100 / 0.006367, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rates.fromYen(10000, to: "KRW")), 88214.28, accuracy: 0.001)
        XCTAssertNil(rates.yenPerUnit("XXX"))
        XCTAssertFalse(rates.availableCodes.contains("JPY"))
    }

    func testErrorResult() throws {
        let json = #"{"result":"error","time_last_update_unix":0,"time_next_update_unix":0,"base_code":"JPY","rates":{}}"#
        let response = try ERAPIClient.decode(Data(json.utf8))
        XCTAssertThrowsError(try ExchangeRates(response: response))
    }

    func testSkipsFetchBeforeNextUpdate() {
        let next = Date(timeIntervalSince1970: 2_000_000)
        let rates = ExchangeRates(base: "JPY", rates: [:], providerUpdatedAt: next.addingTimeInterval(-86400), nextUpdateAt: next)
        let cached = CachedValue(value: rates, fetchedAt: next.addingTimeInterval(-80000))
        XCTAssertFalse(ExchangeStore.isWorthFetching(cached, now: next.addingTimeInterval(-1)))
        XCTAssertTrue(ExchangeStore.isWorthFetching(cached, now: next))
        XCTAssertTrue(ExchangeStore.isWorthFetching(nil, now: next))
    }
}

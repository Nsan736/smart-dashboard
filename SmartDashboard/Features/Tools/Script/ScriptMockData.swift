import Foundation

extension WeatherSnapshot {
    /// 項目をそのまま指定して作る(スクリプトの仮のデータとテスト用)
    init(sourceID: String, placeName: String, latitude: Double?, longitude: Double?, utcOffsetSeconds: Int,
         current: Current, hourly: [Hour], daily: [Day], rain: [RainSlot]?) {
        self.sourceID = sourceID
        self.placeName = placeName
        self.latitude = latitude
        self.longitude = longitude
        self.utcOffsetSeconds = utcOffsetSeconds
        self.current = current
        self.hourly = hourly
        self.daily = daily
        self.rain = rain
    }
}

/// 試しの実行(ScriptTrial)と、保存する前のプレビューで渡す仮のデータ。実際のデータではなく、それらしい値。
/// 本物と同じ関数(ScriptAppData)で作るので、形は本物と同じ。どの種類にも sample: true が入る。
enum ScriptMockData {
    static let latitude = 35.6812
    static let longitude = 139.7671

    /// JSON に書いた種類はすべて許可したものとして、仮のデータを作る(日付と祝日は本物の計算)
    static func all(requested: [ScriptPermission], now: Date) -> [String: String] {
        let granted = Set(requested)
        var result: [String: String] = [:]
        for kind in ScriptDataKind.allCases where kind.isAllowed(granted) {
            guard var object = object(kind, granted: granted, requested: requested, now: now) else { continue }
            if kind != .calendar && kind != .permissions { object["sample"] = true }
            result[kind.rawValue] = ScriptJSON.string(object)
        }
        return result
    }

    static func object(_ kind: ScriptDataKind, granted: Set<ScriptPermission>, requested: [ScriptPermission], now: Date) -> [String: Any]? {
        let coarse = granted.contains(.locationCoarse)
        let precise = granted.contains(.locationPrecise)
        switch kind {
        case .weather:
            return ScriptAppData.weather(weather(now: now), fetchedAt: now.addingTimeInterval(-12 * 60), rain: rain, nowcast: nowcast(now: now),
                                         place: coarse ? "東京都千代田区" : nil,
                                         coordinate: precise ? (latitude: latitude, longitude: longitude) : nil, now: now)
        case .warnings:
            let snapshot = WarningSnapshot(
                area: WarningArea(officeCode: "130000", areaCodes: ["1310100"], name: "千代田区", prefecture: "東京都"),
                warnings: [
                    ActiveWarning(code: "14", name: "雷注意報", level: .advisory, status: "発表", additions: []),
                    ActiveWarning(code: "15", name: "強風注意報", level: .advisory, status: "継続", additions: []),
                ],
                reportedAt: now.addingTimeInterval(-40 * 60))
            return ScriptAppData.warnings(snapshot, fetchedAt: now.addingTimeInterval(-8 * 60), includesArea: coarse)
        case .quakes:
            var first = Quake(time: now.addingTimeInterval(-3 * 3600), place: "千葉県北西部", magnitude: 4.2, maxScale: 30,
                              prefectureScales: ["千葉県": 30, "東京都": 20, "茨城県": 20])
            first.depth = 60
            first.latitude = 35.7
            first.longitude = 140.1
            first.domesticTsunami = "None"
            var second = Quake(time: now.addingTimeInterval(-20 * 3600), place: "茨城県南部", magnitude: 3.5, maxScale: 20,
                               prefectureScales: ["茨城県": 20, "栃木県": 10])
            second.depth = 50
            second.latitude = 36.1
            second.longitude = 140.0
            second.domesticTsunami = "None"
            return ScriptAppData.quakes([first, second], fetchedAt: now.addingTimeInterval(-4 * 60), homePrefecture: coarse ? "東京都" : nil)
        case .pressure:
            let measured = stride(from: 24 * 12, through: 0, by: -1).map { step -> PressureSample in
                let time = now.addingTimeInterval(-Double(step) * 300)
                return PressureSample(time: time, hPa: 1012 + 3 * sin(time.timeIntervalSince1970 / 40_000))
            }
            let forecast = (-24...48).map { hour -> PressureForecastPoint in
                let time = now.addingTimeInterval(Double(hour) * 3600)
                return PressureForecastPoint(time: time, hPa: 1012 + 3 * sin(time.timeIntervalSince1970 / 40_000) - max(0, Double(hour)) * 0.08)
            }
            return ScriptAppData.pressure(measured: measured, forecast: forecast,
                                          change: PressureChange(hours: 3, delta: -1.4, baseIsMeasured: true),
                                          latest: measured.last?.hPa, forecastFetchedAt: now.addingTimeInterval(-50 * 60), now: now)
        case .exchange:
            let rates = ExchangeRates(base: "JPY", rates: ["USD": 0.0068, "EUR": 0.0062, "GBP": 0.0053, "CNY": 0.048, "KRW": 9.5, "JPY": 1],
                                      providerUpdatedAt: now.addingTimeInterval(-6 * 3600), nextUpdateAt: now.addingTimeInterval(18 * 3600))
            return ScriptAppData.exchange(rates, fetchedAt: now.addingTimeInterval(-3 * 3600), codes: ["USD", "EUR", "GBP", "CNY", "KRW"])
        case .trains:
            return trains(now: now)
        case .places:
            let places = [
                Waypoint(name: "東京タワー", latitude: 35.6586, longitude: 139.7454, colorIndex: 1, isPinned: true),
                Waypoint(name: "スカイツリー", latitude: 35.7101, longitude: 139.8107, colorIndex: 4),
                Waypoint(name: "富士山", latitude: 35.3606, longitude: 138.7274, colorIndex: 2),
            ]
            var withHeights = places
            withHeights[0].groundElevation = 18
            withHeights[1].groundElevation = 4
            withHeights[2].groundElevation = 3776
            return ScriptAppData.places(withHeights, origin: ScriptAppData.Origin(latitude: latitude, longitude: longitude, height: 5,
                                                                                  time: now.addingTimeInterval(-90)),
                                        includesCoordinates: precise)
        case .location:
            return ScriptAppData.location(ScriptAppData.Location(latitude: latitude, longitude: longitude, altitude: 5, accuracy: 15,
                                                                 time: now.addingTimeInterval(-90), prefecture: "東京都", city: "千代田区"),
                                          coarse: coarse, precise: precise)
        case .sensors:
            return sensors(now: now, active: [])
        case .calendar:
            return ScriptAppData.calendar(now: now, resolver: DayTypeResolver())
        case .permissions:
            return ScriptAppData.permissions(requested: requested, granted: granted)
        }
    }

    static let rain = RainOutlook(headline: "今は降っていません。40分後から弱い雨", later: "2時間後まで弱い雨の予想(予報モデル)", note: nil)

    static func weather(now: Date) -> WeatherSnapshot {
        let calendar = JapaneseHolidays.calendar
        let hourStart = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let dayStart = calendar.startOfDay(for: now)
        let codes = [1, 2, 3, 3, 61, 61, 3, 2, 1, 0]
        let hourly = (-24..<48).map { offset -> WeatherSnapshot.Hour in
            let time = hourStart.addingTimeInterval(Double(offset) * 3600)
            let hour = Double(calendar.component(.hour, from: time))
            return WeatherSnapshot.Hour(time: time, temperature: 18 + 5 * sin((hour - 9) / 24 * 2 * .pi),
                                        precipitationProbability: Double((offset * 7 + 30) % 80),
                                        weatherCode: codes[(offset + 24) % codes.count], pressure: 1012 - Double(max(0, offset)) * 0.08)
        }
        let daily = (0..<7).map { offset -> WeatherSnapshot.Day in
            let date = dayStart.addingTimeInterval(Double(offset) * 86_400)
            return WeatherSnapshot.Day(date: date, temperatureMax: 22 + Double(offset % 3), temperatureMin: 13 + Double(offset % 2),
                                       precipitationProbability: Double([10, 60, 80, 30, 20, 10, 40][offset]),
                                       weatherCode: [1, 61, 63, 3, 2, 1, 3][offset],
                                       sunrise: date.addingTimeInterval(5.8 * 3600), sunset: date.addingTimeInterval(17.1 * 3600), uvIndexMax: 4.5)
        }
        let slotStart = now.addingTimeInterval(-now.timeIntervalSince1970.truncatingRemainder(dividingBy: 900))
        let rain = (0..<8).map { WeatherSnapshot.RainSlot(time: slotStart.addingTimeInterval(Double($0) * 900), precipitation: $0 < 3 ? 0 : 0.4) }
        return WeatherSnapshot(
            sourceID: "current", placeName: "東京都千代田区丸の内", latitude: latitude, longitude: longitude, utcOffsetSeconds: 9 * 3600,
            current: WeatherSnapshot.Current(time: now.addingTimeInterval(-10 * 60), temperature: 19.4, apparentTemperature: 18.2, humidity: 64,
                                             weatherCode: 2, windSpeed: 3.1, pressure: 1011.8, precipitation: 0),
            hourly: hourly, daily: daily, rain: rain)
    }

    static func nowcast(now: Date) -> RainNowcast {
        let base = now.addingTimeInterval(-now.timeIntervalSince1970.truncatingRemainder(dividingBy: 300) - 300)
        let points = (0...12).map { step in
            RainNowcast.Point(time: base.addingTimeInterval(Double(step) * 300), isForecast: step > 0, level: step >= 8 ? 1 : 0)
        }
        return RainNowcast(latitude: latitude, longitude: longitude, points: points)
    }

    static func trains(now: Date) -> [String: Any] {
        let station = RegisteredStation(operatorID: "odpt.Operator:Sample", railwayID: "odpt.Railway:Sample.Line", railwayName: "サンプル線",
                                        stationID: "odpt.Station:Sample.Line.Chuo", stationName: "中央",
                                        directionID: "odpt.RailDirection:Northbound", directionName: "北町方面")
        let minuteStart = now.addingTimeInterval(-now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        let upcoming = [3, 9, 15, 22, 30].enumerated().map { index, minutes in
            UpcomingDeparture(date: minuteStart.addingTimeInterval(Double(minutes) * 60),
                              departure: StoredTimetable.Departure(minutes: 0, trainType: index % 2 == 0 ? "各停" : "急行",
                                                                   destination: index % 2 == 0 ? "北町" : "港", isLast: false))
        }
        let position = TrainPosition(id: "Sample.Line.A1234", number: "A1234", direction: "odpt.RailDirection:Northbound", trainType: "急行",
                                     destination: "港", delay: .realtime(120), fromStation: 2, toStation: 3, fraction: 0.4,
                                     isStopped: false, isWaitingToDepart: false,
                                     upcoming: [TrainPosition.UpcomingStop(station: 3, arrival: now.addingTimeInterval(150), platform: "2")])
        let item = ScriptAppData.TrainItem(railwayID: station.railwayID, railwayName: station.railwayName, position: position,
                                           fromName: "南町", toName: "中央", nextName: "中央")
        let info = [TrainInfoItem(railwayID: station.railwayID, railwayName: station.railwayName, status: .delay,
                                  statusText: "遅延", text: "信号の確認のため、一部の列車に遅れが出ています。")]
        return ScriptAppData.trains(info: info, infoFetchedAt: now.addingTimeInterval(-3 * 60),
                                    registeredLines: [(station.railwayID, station.railwayName)],
                                    boards: [ScriptAppData.StationBoard(station: station, upcoming: upcoming)],
                                    positions: [item], dayType: JapaneseHolidays.dayType(of: now), now: now)
    }

    /// センサーの仮の値(動かしているセンサーだけ。時刻で少しずつ変える)
    static func sensors(now: Date, active: Set<String>) -> [String: Any] {
        let t = now.timeIntervalSince1970
        var snapshot = ScriptSensorSnapshot(
            active: active,
            steps: .init(today: 4321, distance: 3050, pace: 0.8, cadence: 1.8, time: now),
            speed: .init(metersPerSecond: 1.3 + 0.2 * sin(t), course: 90, accuracy: 0.5, time: now),
            heading: .init(degrees: (t * 10).truncatingRemainder(dividingBy: 360), accuracy: 10, time: now),
            pressure: .init(hPa: 1011.8 + 0.05 * sin(t / 5), relativeAltitude: 0.4, time: now),
            motion: .init(x: 0.02 * sin(t * 3), y: -0.02, z: 0.03, pitch: 10, roll: -3, yaw: 45, time: now),
            available: Set(ScriptSensorKind.allCases.map(\.rawValue))
        )
        snapshot.setActive(active)
        var object = snapshot.object
        object["sample"] = true
        return object
    }
}

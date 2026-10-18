import Foundation

/// スクリプトの app.* で読めるデータの種類(onData(kind) の kind と同じ名前)
enum ScriptDataKind: String, CaseIterable {
    case weather
    case warnings
    case quakes
    case pressure
    case exchange
    case trains
    case places
    case location
    case sensors
    /// 日付・祝日・今日のダイヤ(計算で分かるので、許可は要らない)
    case calendar
    /// どの種類を許可したか(許可は要らない)
    case permissions

    /// 読むのに必要な許可(どれか1つ)。空なら許可なしで読める。
    var permissions: [ScriptPermission] {
        switch self {
        case .weather, .warnings: return [.weather]
        case .quakes: return [.quake]
        case .pressure: return [.pressure]
        case .exchange: return [.exchange]
        case .trains: return [.trains]
        case .places: return [.places]
        case .location: return [.locationCoarse, .locationPrecise]
        case .sensors: return [.sensors]
        case .calendar, .permissions: return []
        }
    }

    func isAllowed(_ granted: Set<ScriptPermission>) -> Bool {
        permissions.isEmpty || permissions.contains { granted.contains($0) }
    }
}

/// スクリプトに渡すデータの件数の上限(渡す量が大きくなりすぎないように)
enum ScriptDataLimit {
    static let hourly = 48
    static let daily = 7
    static let rainModel = 8
    static let nowcast = 13
    static let warnings = 30
    static let quakes = 5
    static let quakePrefectures = 10
    static let measured = 288
    static let forecast = 72
    static let exchangeRates = 200
    static let trainLines = 20
    static let stations = 20
    static let departures = 5
    static let positions = 60
    static let upcomingStops = 5
    static let places = 100
    static let days = 14
    static let holidays = 20
    /// 1つの種類の JSON の大きさの上限(バイト)。超えたら null にする。
    static let bytes = 256 * 1024
}

/// JSON にする値(Optional や NaN を、JSON で扱える形に直す)
enum ScriptJSON {
    /// JSON の null(三項演算子の両側の型を Any にそろえるため)
    static let null: Any = NSNull()

    /// 時刻は 1970年1月1日からのミリ秒(JavaScript の new Date(値) でそのまま使える)
    static func time(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }

    static func number(_ value: Double?, _ digits: Int = 2) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        let factor = pow(10, Double(digits))
        return (value * factor).rounded() / factor
    }

    static func int(_ value: Int?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    static func text(_ value: String?, max: Int = 200) -> Any {
        guard let value, !value.isEmpty else { return NSNull() }
        return String(value.prefix(max))
    }

    /// JSON の文字列。作れないか、大きすぎるときは "null"。
    static func string(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= ScriptDataLimit.bytes,
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}

/// アプリが持っているデータから、スクリプトに渡す写し(辞書)を作る。どれも通信しない。
/// 画面の状態に触れない純粋な関数にしてあり、仮のデータ(ScriptMockData)とテストも同じ関数を通す。
enum ScriptAppData {
    typealias Coordinate = (latitude: Double, longitude: Double)

    // MARK: - 天気・雨・警報

    static func weather(_ snapshot: WeatherSnapshot, fetchedAt: Date, rain: RainOutlook?, nowcast: RainNowcast?,
                        place: String?, coordinate: Coordinate?, now: Date) -> [String: Any] {
        let c = snapshot.current
        let current: [String: Any] = [
            "time": ScriptJSON.time(c.time),
            "temperature": ScriptJSON.number(c.temperature, 1),
            "apparentTemperature": ScriptJSON.number(c.apparentTemperature, 1),
            "humidity": ScriptJSON.number(c.humidity, 0),
            "precipitation": ScriptJSON.number(c.precipitation, 1),
            "windSpeed": ScriptJSON.number(c.windSpeed, 1),
            "pressure": ScriptJSON.number(c.pressure, 1),
            "weatherCode": c.weatherCode,
            "label": WeatherCode.label(c.weatherCode),
            "symbol": WeatherCode.symbol(c.weatherCode),
        ]
        let hourly: [[String: Any]] = snapshot.upcomingHours(now: now, limit: ScriptDataLimit.hourly).map { hour in
            [
                "time": ScriptJSON.time(hour.time),
                "temperature": ScriptJSON.number(hour.temperature, 1),
                "precipitationProbability": ScriptJSON.number(hour.precipitationProbability, 0),
                "weatherCode": ScriptJSON.int(hour.weatherCode),
                "label": WeatherCode.label(hour.weatherCode),
                "pressure": ScriptJSON.number(hour.pressure, 1),
            ]
        }
        let daily: [[String: Any]] = snapshot.daily.prefix(ScriptDataLimit.daily).map { day in
            [
                "date": ScriptJSON.time(day.date),
                "temperatureMax": ScriptJSON.number(day.temperatureMax, 1),
                "temperatureMin": ScriptJSON.number(day.temperatureMin, 1),
                "precipitationProbability": ScriptJSON.number(day.precipitationProbability, 0),
                "weatherCode": ScriptJSON.int(day.weatherCode),
                "label": WeatherCode.label(day.weatherCode),
                "sunrise": ScriptJSON.time(day.sunrise),
                "sunset": ScriptJSON.time(day.sunset),
                "uvIndexMax": ScriptJSON.number(day.uvIndexMax, 1),
            ]
        }
        let nowcastPoints: [[String: Any]] = (nowcast?.points ?? []).sorted { $0.time < $1.time }
            .filter { $0.time.addingTimeInterval(30 * 60) > now }
            .prefix(ScriptDataLimit.nowcast).map { point in
                [
                    "time": ScriptJSON.time(point.time),
                    "level": point.level,
                    "label": RainLevel.label(point.level),
                    "isForecast": point.isForecast,
                ]
            }
        let model: [[String: Any]] = snapshot.upcomingRain(now: now).prefix(ScriptDataLimit.rainModel).map { slot in
            ["time": ScriptJSON.time(slot.time), "precipitation": ScriptJSON.number(slot.precipitation, 1)]
        }
        let rainSummary: [String: Any] = [
            "headline": ScriptJSON.text(rain?.headline),
            "later": ScriptJSON.text(rain?.later),
            "note": ScriptJSON.text(rain?.note),
            "nowcast": nowcastPoints,
            "model": model,
        ]
        return [
            "fetchedAt": ScriptJSON.time(fetchedAt),
            "place": ScriptJSON.text(place),
            "latitude": ScriptJSON.number(coordinate?.latitude, 6),
            "longitude": ScriptJSON.number(coordinate?.longitude, 6),
            "current": current,
            "hourly": hourly,
            "daily": daily,
            "rain": rainSummary,
        ]
    }

    static func warnings(_ snapshot: WarningSnapshot, fetchedAt: Date, includesArea: Bool) -> [String: Any] {
        let items: [[String: Any]] = snapshot.warnings.prefix(ScriptDataLimit.warnings).map { warning in
            [
                "code": warning.code,
                "name": warning.name,
                "level": warning.level.rawValue,
                "levelLabel": warning.level.label,
                "status": warning.status,
            ]
        }
        var area = ScriptJSON.null
        if includesArea {
            area = [
                "prefecture": snapshot.area.prefecture,
                "name": snapshot.area.name,
                "wholeCity": snapshot.area.coversWholeCity,
            ] as [String: Any]
        }
        return [
            "fetchedAt": ScriptJSON.time(fetchedAt),
            "reportedAt": ScriptJSON.time(snapshot.reportedAt),
            "area": area,
            "maxLevel": ScriptJSON.int(snapshot.maxLevel?.rawValue),
            "maxLevelLabel": ScriptJSON.text(snapshot.maxLevel?.label),
            "items": items,
        ]
    }

    // MARK: - 地震

    /// homePrefecture は「おおよその地域」を許可したときだけ渡す(その都道府県の震度を足す)
    static func quakes(_ quakes: [Quake], fetchedAt: Date, homePrefecture: String?) -> [String: Any] {
        let items: [[String: Any]] = quakes.sorted { $0.time > $1.time }.prefix(ScriptDataLimit.quakes).map { quake in
            let prefectures: [[String: Any]] = quake.prefectureScales.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(ScriptDataLimit.quakePrefectures).map { ["prefecture": $0.key, "scale": $0.value, "scaleLabel": SeismicScale.label($0.value)] }
            let local = homePrefecture.flatMap { quake.scale(inPrefecture: $0) }
            return [
                "time": ScriptJSON.time(quake.time),
                "place": ScriptJSON.text(quake.place),
                "magnitude": ScriptJSON.number(quake.magnitude, 1),
                "depth": ScriptJSON.number(quake.depth, 0),
                "latitude": ScriptJSON.number(quake.latitude, 2),
                "longitude": ScriptJSON.number(quake.longitude, 2),
                "maxScale": ScriptJSON.int(quake.maxScale),
                "maxScaleLabel": ScriptJSON.text(quake.maxScale.map { SeismicScale.label($0) }),
                "tsunami": QuakeTsunami.domestic(quake.domesticTsunami).text,
                "revised": quake.wasRevised ?? false,
                "prefectures": prefectures,
                "localScale": ScriptJSON.int(local),
                "localScaleLabel": ScriptJSON.text(local.map { SeismicScale.label($0) }),
            ]
        }
        return ["fetchedAt": ScriptJSON.time(fetchedAt), "items": items]
    }

    // MARK: - 気圧

    static func pressure(measured: [PressureSample], forecast: [PressureForecastPoint], change: PressureChange?,
                         latest: Double?, forecastFetchedAt: Date?, now: Date) -> [String: Any] {
        let measuredPoints: [[String: Any]] = measured.filter { $0.time > now.addingTimeInterval(-24 * 3600) && $0.time <= now.addingTimeInterval(60) }
            .sorted { $0.time < $1.time }.suffix(ScriptDataLimit.measured)
            .map { ["time": ScriptJSON.time($0.time), "hPa": ScriptJSON.number($0.hPa, 2)] }
        let forecastPoints: [[String: Any]] = forecast.filter { $0.time > now.addingTimeInterval(-24 * 3600) && $0.time <= now.addingTimeInterval(48 * 3600) }
            .sorted { $0.time < $1.time }.prefix(ScriptDataLimit.forecast)
            .map { ["time": ScriptJSON.time($0.time), "hPa": ScriptJSON.number($0.hPa, 1)] }
        var changeObject = ScriptJSON.null
        if let change {
            changeObject = ["hours": change.hours, "delta": ScriptJSON.number(change.delta, 1),
                            "baseIsMeasured": change.baseIsMeasured, "text": change.text] as [String: Any]
        }
        return [
            "fetchedAt": ScriptJSON.time(forecastFetchedAt),
            "measuredAt": ScriptJSON.time(measured.map(\.time).max()),
            "latest": ScriptJSON.number(latest ?? measured.max { $0.time < $1.time }?.hPa, 2),
            "measured": measuredPoints,
            "forecast": forecastPoints,
            "change3h": changeObject,
        ]
    }

    // MARK: - 為替

    static func exchange(_ rates: ExchangeRates, fetchedAt: Date, codes: [String]) -> [String: Any] {
        let selected: [[String: Any]] = codes.prefix(ScriptDataLimit.exchangeRates).compactMap { code in
            guard let yen = rates.yenPerUnit(code) else { return nil }
            return ["code": code, "name": CurrencyName.japanese(code), "yen": ScriptJSON.number(yen, 6)]
        }
        var all: [String: Any] = [:]
        for code in rates.availableCodes.sorted().prefix(ScriptDataLimit.exchangeRates) {
            if let yen = rates.yenPerUnit(code), yen.isFinite { all[code] = ScriptJSON.number(yen, 6) }
        }
        return [
            "fetchedAt": ScriptJSON.time(fetchedAt),
            "updatedAt": ScriptJSON.time(rates.providerUpdatedAt),
            "base": rates.base,
            "rates": selected,
            "all": all,
        ]
    }

    // MARK: - 電車

    /// 登録した駅の、次の電車
    struct StationBoard {
        var station: RegisteredStation
        var upcoming: [UpcomingDeparture]
    }

    /// 列車の位置(駅の名前は、呼ぶ側で引いておく)
    struct TrainItem {
        var railwayID: String
        var railwayName: String
        var position: TrainPosition
        var fromName: String
        var toName: String
        var nextName: String?
    }

    static func trains(info: [TrainInfoItem], infoFetchedAt: Date?, registeredLines: [(railwayID: String, name: String)],
                       boards: [StationBoard], positions: [TrainItem], dayType: DayType, now: Date) -> [String: Any] {
        let infoByID = Dictionary(info.map { ($0.railwayID, $0) }, uniquingKeysWith: { first, _ in first })
        let lines: [[String: Any]] = registeredLines.prefix(ScriptDataLimit.trainLines).map { line in
            let item = infoByID[line.railwayID]
            return [
                "id": line.railwayID,
                "name": line.name,
                "status": item?.status.rawValue ?? "unknown",
                "statusLabel": item?.status.label ?? "不明",
                "statusText": ScriptJSON.text(item?.statusText),
                "text": ScriptJSON.text(item?.text, max: 400),
            ]
        }
        let departures: [[String: Any]] = boards.prefix(ScriptDataLimit.stations).map { board in
            let trains: [[String: Any]] = board.upcoming.prefix(ScriptDataLimit.departures).map { upcoming in
                [
                    "time": ScriptJSON.time(upcoming.date),
                    "minutes": Int(floor(upcoming.date.timeIntervalSince(now) / 60)),
                    "type": ScriptJSON.text(upcoming.departure.trainType),
                    "destination": ScriptJSON.text(upcoming.departure.destination),
                    "isLast": upcoming.departure.isLast,
                ]
            }
            return [
                "station": board.station.stationName,
                "stationID": board.station.stationID,
                "railwayID": board.station.railwayID,
                "railway": board.station.railwayName,
                "direction": board.station.directionName,
                "trains": trains,
            ]
        }
        let trainItems: [[String: Any]] = positions.prefix(ScriptDataLimit.positions).map { item in
            let p = item.position
            var delay = ScriptJSON.null
            if case .realtime(let seconds) = p.delay { delay = ScriptJSON.number(seconds, 0) }
            let next = p.upcoming.first
            return [
                "id": p.id,
                "railwayID": item.railwayID,
                "railway": item.railwayName,
                "number": p.number,
                "type": p.trainType,
                "destination": p.destination,
                "direction": ODPTID.tail(p.direction),
                "delaySeconds": delay,
                "delayLabel": p.delay.label,
                "from": item.fromName,
                "to": item.toName,
                "fraction": ScriptJSON.number(p.fraction, 3),
                "stopped": p.isStopped,
                "next": ScriptJSON.text(item.nextName),
                "nextArrival": ScriptJSON.time(next?.arrival),
                "platform": ScriptJSON.text(p.currentPlatform ?? next?.platform),
            ]
        }
        return [
            "fetchedAt": ScriptJSON.time(infoFetchedAt),
            "positionsAt": ScriptJSON.time(now),
            "dayType": dayType.rawValue,
            "dayTypeLabel": dayTypeLabel(dayType),
            "lines": lines,
            "departures": departures,
            "positions": trainItems,
        ]
    }

    static func dayTypeLabel(_ type: DayType) -> String {
        switch type {
        case .weekday: return "平日"
        case .saturday: return "土曜"
        case .holiday: return "休日"
        }
    }

    // MARK: - 地点

    struct Origin {
        var latitude: Double
        var longitude: Double
        var height: Double?
        var time: Date
    }

    static let placeColors = ["#424ACC", "#FF3B30", "#34C759", "#FF9500", "#AF52DE", "#FF2D55", "#32ADE6", "#FFCC00"]

    /// 緯度経度は includesCoordinates(現在地の緯度経度を許可)のときだけ入れる
    static func places(_ waypoints: [Waypoint], origin: Origin?, includesCoordinates: Bool) -> [String: Any] {
        var rows: [(distance: Double, item: [String: Any])] = []
        for waypoint in waypoints {
            var item: [String: Any] = [
                "id": waypoint.id.uuidString,
                "name": waypoint.name,
                "memo": ScriptJSON.text(waypoint.memo, max: 200),
                "color": placeColors[min(max(waypoint.colorIndex, 0), placeColors.count - 1)],
                "colorName": WaypointPalette.names[min(max(waypoint.colorIndex, 0), WaypointPalette.names.count - 1)],
                "pinned": waypoint.isPinned,
                "hidden": waypoint.isHidden,
                "altitude": ScriptJSON.number(waypoint.altitude, 1),
                "bearing": NSNull(),
                "compass": NSNull(),
                "distance": NSNull(),
                "heightDifference": NSNull(),
                "latitude": NSNull(),
                "longitude": NSNull(),
            ]
            var distance = Double.greatestFiniteMagnitude
            if let origin {
                distance = WaypointMath.distance(fromLatitude: origin.latitude, longitude: origin.longitude,
                                                 toLatitude: waypoint.latitude, longitude: waypoint.longitude)
                let bearing = WaypointMath.bearing(fromLatitude: origin.latitude, longitude: origin.longitude,
                                                   toLatitude: waypoint.latitude, longitude: waypoint.longitude)
                item["distance"] = ScriptJSON.number(distance, 0)
                item["bearing"] = ScriptJSON.number(bearing, 1)
                item["compass"] = WaypointMath.compassPoint(bearing)
                if let height = origin.height, let altitude = waypoint.altitude {
                    item["heightDifference"] = ScriptJSON.number(altitude - height, 1)
                }
            }
            if includesCoordinates {
                item["latitude"] = ScriptJSON.number(waypoint.latitude, 6)
                item["longitude"] = ScriptJSON.number(waypoint.longitude, 6)
            }
            rows.append((distance, item))
        }
        // 現在地が分かるときは近い順、分からなければ登録の順
        if origin != nil { rows.sort { $0.distance < $1.distance } }
        var originObject = ScriptJSON.null
        if let origin {
            originObject = [
                "time": ScriptJSON.time(origin.time),
                "height": ScriptJSON.number(origin.height, 1),
                "latitude": includesCoordinates ? ScriptJSON.number(origin.latitude, 6) : ScriptJSON.null,
                "longitude": includesCoordinates ? ScriptJSON.number(origin.longitude, 6) : ScriptJSON.null,
            ] as [String: Any]
        }
        return [
            "fetchedAt": ScriptJSON.time(origin?.time),
            "origin": originObject,
            "count": waypoints.count,
            "items": rows.prefix(ScriptDataLimit.places).map { $0.item },
        ]
    }

    // MARK: - 現在地

    struct Location {
        var latitude: Double
        var longitude: Double
        var altitude: Double?
        var accuracy: Double?
        var time: Date
        var prefecture: String?
        var city: String?
    }

    /// 許可した範囲だけを入れる(おおよそ=都道府県と市区町村、正確=緯度経度と高度)。どちらも許可していなければ nil。
    static func location(_ location: Location, coarse: Bool, precise: Bool) -> [String: Any]? {
        guard coarse || precise else { return nil }
        return [
            "fetchedAt": ScriptJSON.time(location.time),
            "prefecture": coarse ? ScriptJSON.text(location.prefecture) : ScriptJSON.null,
            "city": coarse ? ScriptJSON.text(location.city) : ScriptJSON.null,
            "latitude": precise ? ScriptJSON.number(location.latitude, 6) : ScriptJSON.null,
            "longitude": precise ? ScriptJSON.number(location.longitude, 6) : ScriptJSON.null,
            "altitude": precise ? ScriptJSON.number(location.altitude, 1) : ScriptJSON.null,
            "accuracy": precise ? ScriptJSON.number(location.accuracy, 0) : ScriptJSON.null,
        ]
    }

    // MARK: - 日付・祝日・今日のダイヤ

    static func calendar(now: Date, resolver: DayTypeResolver) -> [String: Any] {
        let calendar = JapaneseHolidays.calendar
        func day(_ date: Date) -> [String: Any] {
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let type = resolver.dayType(of: date)
            return [
                "date": DayTypeResolver.dayKey(date),
                "weekday": (c.weekday ?? 1) - 1,
                "dayType": type.rawValue,
                "dayTypeLabel": dayTypeLabel(type),
                "holiday": ScriptJSON.text(JapaneseHolidays.holidayName(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)),
            ]
        }
        let start = calendar.startOfDay(for: now)
        let days = (0..<ScriptDataLimit.days).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }.map(day)
        var holidays: [[String: Any]] = []
        var offset = 0
        while holidays.count < ScriptDataLimit.holidays, offset < 800 {
            if let date = calendar.date(byAdding: .day, value: offset, to: start) {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                if let name = JapaneseHolidays.holidayName(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0) {
                    holidays.append(["date": DayTypeResolver.dayKey(date), "name": name])
                }
            }
            offset += 1
        }
        var today = day(now)
        today["dayTypeOverridden"] = resolver.isOverridden(on: now)
        today["days"] = days
        today["holidays"] = holidays
        return today
    }

    // MARK: - 許可

    static func permissions(requested: [ScriptPermission], granted: Set<ScriptPermission>) -> [String: Any] {
        var result: [String: Any] = [:]
        for permission in ScriptPermission.allCases {
            result[permission.rawValue] = requested.contains(permission) && granted.contains(permission)
        }
        return result
    }
}

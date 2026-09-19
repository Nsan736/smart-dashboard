import XCTest
@testable import SmartDashboard

final class ODPTDecodingTests: XCTestCase {
    func testTrainInformation() throws {
        let list = try ODPTClient.decode([ODPTTrainInformation].self, from: Fixture.data("odpt_train_information"))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].railway, "odpt.Railway:Toei.Asakusa")
        XCTAssertEqual(list[0].operatorID, "odpt.Operator:Toei")
        XCTAssertNil(list[0].status)
        XCTAssertEqual(list[0].text?.text, "現在、１５分以上の遅延はありません。")

        let lines = [
            RegisteredLine(operatorID: "odpt.Operator:Toei", railwayID: "odpt.Railway:Toei.Mita", railwayName: "三田線"),
            RegisteredLine(operatorID: "odpt.Operator:Toei", railwayID: "odpt.Railway:Toei.Oedo", railwayName: "大江戸線"),
        ]
        let items = TrainStore.makeItems(lines: lines, response: list)
        XCTAssertEqual(items.map(\.status), [.normal, .normal])
        XCTAssertNotNil(items[0].text)
        XCTAssertNil(items[1].text)
    }

    func testStatusAsObjectOrString() throws {
        let json = """
        [{"owl:sameAs":"a","odpt:operator":"odpt.Operator:X","odpt:railway":"r1",
          "odpt:trainInformationStatus":{"ja":"遅延"},"odpt:trainInformationText":{"ja":"遅れています"}},
         {"owl:sameAs":"b","odpt:operator":"odpt.Operator:X","odpt:railway":"r2",
          "odpt:trainInformationStatus":"運転見合わせ","odpt:trainInformationText":"見合わせています"}]
        """
        let list = try ODPTClient.decode([ODPTTrainInformation].self, from: Data(json.utf8))
        XCTAssertEqual(TrainStatus.classify(status: list[0].status?.text, text: list[0].text?.text), .delay)
        XCTAssertEqual(TrainStatus.classify(status: list[1].status?.text, text: list[1].text?.text), .suspended)
        XCTAssertEqual(TrainStatus.classify(status: nil, text: nil), .normal)
        XCTAssertEqual(TrainStatus.classify(status: "直通運転中止", text: nil), .other)
    }

    func testRailway() throws {
        let list = try ODPTClient.decode([ODPTRailway].self, from: Fixture.data("odpt_railway"))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].sameAs, "odpt.Railway:Toei.Asakusa")
        XCTAssertEqual(list[0].name, "浅草線")
        XCTAssertEqual(list[0].stationOrder?.first?.stationTitle?.text, "西馬込")
        XCTAssertEqual(list[0].directions.first, "odpt.RailDirection:Northbound")
        XCTAssertEqual(list[0].directions.count, 2)

        // キャッシュ用に再エンコードしても読める
        let again = try JSONDecoder().decode([ODPTRailway].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(again, list)
    }

    func testRailDirectionAndTrainType() throws {
        let directions = try ODPTClient.decode([ODPTRailDirection].self, from: Fixture.data("odpt_rail_direction"))
        XCTAssertTrue(directions.contains { $0.sameAs == "odpt.RailDirection:Toei.Waseda" && $0.name == "早稲田方面" })
        let types = try ODPTClient.decode([ODPTTrainType].self, from: Fixture.data("odpt_train_type"))
        XCTAssertTrue(types.contains { $0.sameAs == "odpt.TrainType:Toei.AccessExpress" && $0.name == "アクセス特急" })
    }

    func testRequestURLs() throws {
        let publicURL = ODPTClient.makeURL(type: "odpt:TrainInformation",
                                           query: [("odpt:railway", "odpt.Railway:Toei.Asakusa,odpt.Railway:Toei.Mita")],
                                           endpoint: .publicAPI, token: "SHOULD-NOT-APPEAR")
        let publicParts = try XCTUnwrap(URLComponents(url: publicURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(publicParts.host, "api-public.odpt.org")
        XCTAssertEqual(publicParts.path, "/api/v4/odpt:TrainInformation")
        XCTAssertEqual(publicParts.queryItems, [URLQueryItem(name: "odpt:railway", value: "odpt.Railway:Toei.Asakusa,odpt.Railway:Toei.Mita")])
        XCTAssertFalse(publicURL.absoluteString.contains("SHOULD-NOT-APPEAR"))

        let authURL = ODPTClient.makeURL(type: "odpt:Railway", query: [("odpt:operator", "odpt.Operator:TokyoMetro")],
                                         endpoint: .authenticated, token: "DUMMY")
        let authParts = try XCTUnwrap(URLComponents(url: authURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(authParts.host, "api.odpt.org")
        XCTAssertEqual(authParts.queryItems?.last, URLQueryItem(name: "acl:consumerKey", value: "DUMMY"))
    }
}

final class TimetableTests: XCTestCase {
    private func makeTimetable() throws -> StoredTimetable {
        let tables = try ODPTClient.decode([ODPTStationTimetable].self, from: Fixture.data("odpt_station_timetable"))
        XCTAssertEqual(tables.count, 2)
        return StoredTimetable(
            registrationID: UUID(), downloadedAt: Date(), tables: tables,
            trainTypeNames: ["odpt.TrainType:Toei.Local": "普通"],
            stationNames: [:])
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        JapaneseHolidays.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testMidnightRollover() throws {
        let timetable = try makeTimetable()
        let weekday = try XCTUnwrap(timetable.departuresByCalendar["odpt.Calendar:Weekday"])
        XCTAssertEqual(weekday.count, 7)
        XCTAssertEqual(weekday.first?.minutes, 5 * 60 + 3)
        XCTAssertEqual(weekday.first?.trainType, "普通")
        XCTAssertEqual(weekday.last?.minutes, 24 * 60 + 23)
        XCTAssertEqual(weekday.last?.isLast, true)
        XCTAssertEqual(weekday.map(\.minutes), weekday.map(\.minutes).sorted())
    }

    func testNextTrainInMorning() throws {
        let timetable = try makeTimetable()
        // 2026-09-17(木)は平日
        let upcoming = TimetableCalculator.upcoming(in: timetable, now: date(2026, 9, 17, 5, 10), count: 2)
        XCTAssertEqual(upcoming.map(\.date), [date(2026, 9, 17, 5, 20), date(2026, 9, 17, 5, 33)])
    }

    func testAfterMidnightUsesPreviousServiceDay() throws {
        let timetable = try makeTimetable()
        // 金曜の深夜(土曜 0:10)は、金曜(平日)の時刻表の 0:23 が次の列車
        let upcoming = TimetableCalculator.upcoming(in: timetable, now: date(2026, 9, 19, 0, 10), count: 2)
        XCTAssertEqual(upcoming.first?.date, date(2026, 9, 19, 0, 23))
        XCTAssertEqual(upcoming.first?.departure.isLast, true)
        // その次は土曜(土休日ダイヤ)の始発
        let saturdayFirst = try XCTUnwrap(timetable.departuresByCalendar["odpt.Calendar:SaturdayHoliday"]?.first)
        XCTAssertEqual(upcoming.last?.date, date(2026, 9, 19, 0, 0).addingTimeInterval(TimeInterval(saturdayFirst.minutes * 60)))
    }

    func testCalendarSelection() throws {
        let timetable = try makeTimetable()
        XCTAssertEqual(timetable.departures(for: .saturday), timetable.departuresByCalendar["odpt.Calendar:SaturdayHoliday"])
        XCTAssertEqual(timetable.departures(for: .holiday), timetable.departuresByCalendar["odpt.Calendar:SaturdayHoliday"])
        XCTAssertEqual(timetable.departures(for: .weekday), timetable.departuresByCalendar["odpt.Calendar:Weekday"])
    }
}

final class HolidayTests: XCTestCase {
    private func type(_ y: Int, _ m: Int, _ d: Int) -> DayType {
        JapaneseHolidays.dayType(of: JapaneseHolidays.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!)
    }

    func testDayTypes() {
        XCTAssertEqual(type(2026, 9, 17), .weekday)
        XCTAssertEqual(type(2026, 9, 19), .saturday)
        XCTAssertEqual(type(2026, 9, 20), .holiday)
        XCTAssertEqual(type(2026, 9, 21), .holiday)
        XCTAssertEqual(type(2026, 9, 22), .holiday)
        XCTAssertEqual(type(2026, 9, 23), .holiday)
        XCTAssertEqual(type(2026, 9, 24), .weekday)
        XCTAssertEqual(type(2026, 5, 6), .holiday)
        XCTAssertEqual(type(2027, 1, 11), .holiday)
        XCTAssertEqual(type(2027, 3, 21), .holiday)
        XCTAssertEqual(type(2027, 3, 22), .holiday)
        XCTAssertEqual(type(2026, 12, 25), .weekday)
    }
}

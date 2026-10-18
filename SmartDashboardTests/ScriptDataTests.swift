import XCTest
@testable import SmartDashboard

/// スクリプト型の小ツールから読むアプリのデータ: 許可の形式と判定、null になること、データの写しの形と上限、センサーの開始と終了
final class ScriptPermissionTests: XCTestCase {
    private func parse(_ json: String) -> CustomToolParser.Result {
        CustomToolParser.parse(json)
    }

    func testParsePermissions() throws {
        let json = #"{"format":1,"id":"x","name":"X","type":"script","permissions":["trains","weather","trains","location.precise"],"script":"function frame(){}"}"#
        guard case .success(let tool) = parse(json) else { return XCTFail("読めるはず") }
        // 重複は1つにまとめ、並びは決まった順
        XCTAssertEqual(tool.script?.permissions, [.weather, .trains, .locationPrecise])

        guard case .success(let none) = parse(#"{"format":1,"id":"x","name":"X","type":"script","script":"1"}"#) else { return XCTFail("読めるはず") }
        XCTAssertEqual(none.script?.permissions, [])

        guard case .failure(let issues) = parse(#"{"format":1,"id":"x","name":"X","type":"script","permissions":["weather","camera",3],"script":"1"}"#) else {
            return XCTFail("知らない種類は誤り")
        }
        XCTAssertEqual(issues.map(\.path), ["permissions[1]", "permissions[2]"])
        guard case .failure(let notList) = parse(#"{"format":1,"id":"x","name":"X","type":"script","permissions":"weather","script":"1"}"#) else {
            return XCTFail("配列でなければ誤り")
        }
        XCTAssertEqual(notList.map(\.path), ["permissions"])
    }

    func testGrantsAreStoredPerToolAndOnlyForRequestedKinds() throws {
        var grants = ScriptPermissionGrants()
        let requested: [ScriptPermission] = [.weather, .sensors]
        XCTAssertEqual(grants.undecided(requested, toolID: "a"), [.weather, .sensors])
        grants.record([.weather: true, .sensors: false], toolID: "a")
        XCTAssertEqual(grants.undecided(requested, toolID: "a"), [])
        XCTAssertEqual(grants.granted(requested, toolID: "a"), [.weather])
        // ほかのツールには効かない
        XCTAssertEqual(grants.granted(requested, toolID: "b"), [])
        // JSON に書いていない種類は、許可の記録があっても渡さない
        grants.set(.exchange, granted: true, toolID: "a")
        XCTAssertEqual(grants.granted(requested, toolID: "a"), [.weather])
        // JSON に種類が増えたら、増えた分だけを聞く
        XCTAssertEqual(grants.undecided([.weather, .sensors, .trains], toolID: "a"), [.trains])
        // 取り消すと、もう一度聞く
        grants.reset(toolID: "a")
        XCTAssertEqual(grants.undecided(requested, toolID: "a"), requested)
        // 保存の形
        let data = try JSONEncoder().encode(grants)
        XCTAssertEqual(try JSONDecoder().decode(ScriptPermissionGrants.self, from: data), grants)
    }

    func testDataKindsNeedPermissions() {
        XCTAssertTrue(ScriptDataKind.weather.isAllowed([.weather]))
        XCTAssertTrue(ScriptDataKind.warnings.isAllowed([.weather]))
        XCTAssertFalse(ScriptDataKind.weather.isAllowed([.trains]))
        XCTAssertTrue(ScriptDataKind.location.isAllowed([.locationCoarse]))
        XCTAssertTrue(ScriptDataKind.location.isAllowed([.locationPrecise]))
        XCTAssertFalse(ScriptDataKind.location.isAllowed([.places]))
        // 計算で分かる情報と、許可の一覧は、許可なしで読める
        XCTAssertTrue(ScriptDataKind.calendar.isAllowed([]))
        XCTAssertTrue(ScriptDataKind.permissions.isAllowed([]))
        XCTAssertFalse(ScriptDataKind.sensors.isAllowed([]))
        XCTAssertFalse(ScriptRuntime.accepts("weather", granted: []))
        XCTAssertFalse(ScriptRuntime.accepts("unknown", granted: Set(ScriptPermission.allCases)))
    }

    /// 確認の画面: 目立たせる種類と、初めから選んでおく種類
    func testSensitiveKindsForConfirmation() throws {
        XCTAssertEqual(ScriptPermission.allCases.filter(\.isSensitive), [.locationPrecise, .sensors])
        XCTAssertFalse(ScriptPermission.locationPrecise.grantedByDefault)
        XCTAssertFalse(ScriptPermission.sensors.grantedByDefault)
        XCTAssertTrue(ScriptPermission.weather.grantedByDefault)
        for permission in ScriptPermission.allCases {
            XCTAssertFalse(permission.title.isEmpty)
            XCTAssertFalse(permission.detail.isEmpty)
            XCTAssertFalse(permission.symbol.isEmpty)
        }
        // サンプルの permissions(確認の画面の一覧に出る)
        let json = try XCTUnwrap(String(data: Fixture.data("tool_script_place_compass"), encoding: .utf8))
        guard case .success(let tool) = CustomToolParser.parse(json) else { return XCTFail("読めるはず") }
        XCTAssertEqual(tool.script?.permissions, [.places, .sensors])
        XCTAssertTrue(tool.script?.permissions.contains(where: \.isSensitive) == true)
    }
}

final class ScriptAppDataRuntimeTests: XCTestCase {
    private let screen = ScriptScreen(width: 300, height: 200, dark: false, scale: 2)

    private func runtime(_ script: String, permissions: [ScriptPermission], data: [String: String],
                         granted: Set<ScriptPermission>) -> ScriptRuntime {
        var content = ScriptToolContent(script: script, controls: [], controlsAtTop: false, fps: 30, aspect: nil)
        content.permissions = permissions
        return ScriptRuntime(content: content, storage: ScriptStorage(fileURL: nil), timeLimit: 2, headless: true, data: data, granted: granted)
    }

    func testUngrantedAndUnlistedKindsAreNull() {
        var data = ScriptMockData.all(requested: ScriptPermission.allCases, now: Date())
        data["permissions"] = ScriptJSON.string(ScriptAppData.permissions(requested: [.weather, .quake], granted: [.weather]))
        // JSON には天気と地震だけ。許可したのは天気と為替(為替は JSON に書いていない)
        let runtime = runtime("""
        function setup() {
          console.log(JSON.stringify([app.weather !== null, app.warnings !== null, app.quakes, app.exchange, app.location,
                                      app.trains, app.places, app.pressure, app.calendar !== null]));
          console.log(JSON.stringify([app.permissions.weather, app.permissions.quake, app.permissions.exchange]));
          console.log(JSON.stringify([app.sensors.heading, app.sensors.start('heading')]));
        }
        """, permissions: [.weather, .quake], data: data, granted: [.weather, .exchange])
        let output = runtime.load(screen: screen)
        XCTAssertNil(output.error)
        XCTAssertEqual(output.logs.map(\.text), [
            "[true,true,null,null,null,null,null,null,true]",
            "[true,false,false]",
            "[null,false]",
        ])
        XCTAssertEqual(output.sensorRequests, [])
    }

    func testAppIsReadOnlyCopy() {
        let data = ScriptMockData.all(requested: [.weather], now: Date())
        let runtime = runtime("""
        function setup() {
          var w = app.weather;
          w.current.temperature = 999;
          app.weather = null;
          try { delete app.weather; } catch (e) {}
          app.sensors.start = function () { return true; };
          console.log(String(app.weather.current.temperature !== 999) + ',' + String(app.weather !== w) + ',' + typeof __native);
          console.log(String(app.sensors.start('heading')));
        }
        """, permissions: [.weather], data: data, granted: [.weather])
        let output = runtime.load(screen: screen)
        XCTAssertNil(output.error)
        XCTAssertEqual(output.logs.map(\.text), ["true,true,undefined", "false"])
    }

    func testOnDataIsCalledOnlyForAcceptedKinds() {
        let runtime = runtime("""
        var seen = [];
        function onData(kind) { seen.push(kind + ':' + (app[kind] ? app[kind].v : 'null')); }
        function frame() { if (seen.length) { console.log(seen.join(' ')); seen = []; } }
        """, permissions: [.weather], data: [:], granted: [.weather])
        XCTAssertNil(runtime.load(screen: screen).error)
        let output = runtime.tick(t: 0, dt: 0, screen: screen, touches: [], inputs: [],
                                  data: ["weather": #"{"v":1}"#, "exchange": #"{"v":2}"#, "calendar": #"{"v":3}"#, "bogus": "{}"])
        XCTAssertEqual(output.logs.map(\.text), ["calendar:3 weather:1"])
        let cleared = runtime.tick(t: 0, dt: 0, screen: screen, touches: [], inputs: [], data: ["weather": "null"])
        XCTAssertEqual(cleared.logs.map(\.text), ["weather:null"])
    }

    func testSensorStartAndStopRequests() {
        let runtime = runtime("""
        function setup() { console.log(String(app.sensors.start('heading')) + String(app.sensors.start('steps'))); }
        function onTouch() { app.sensors.stop('heading'); }
        function onStop() { app.sensors.stop('steps'); }
        """, permissions: [.sensors], data: [:], granted: [.sensors])
        let loaded = runtime.load(screen: screen)
        XCTAssertEqual(loaded.logs.map(\.text), ["truetrue"])
        XCTAssertEqual(loaded.sensorRequests, [ScriptSensorRequest(kind: .heading, on: true), ScriptSensorRequest(kind: .steps, on: true)])
        let touched = runtime.tick(t: 0, dt: 0, screen: screen, touches: [ScriptTouch(phase: .down, x: 1, y: 1)], inputs: [])
        XCTAssertEqual(touched.sensorRequests, [ScriptSensorRequest(kind: .heading, on: false)])
        // 知らない名前は例外
        let bad = self.runtime("function setup() { app.sensors.start('camera'); }", permissions: [.sensors], data: [:], granted: [.sensors])
        XCTAssertNotNil(bad.load(screen: screen).error)
        // 値は、動かしているセンサーの分だけ
        let values = ScriptMockData.sensors(now: Date(), active: ["heading"])
        XCTAssertTrue(values["heading"] is [String: Any])
        XCTAssertTrue(values["steps"] is NSNull)
        XCTAssertEqual(values["active"] as? [String], ["heading"])
    }

    func testHolidayNames() {
        XCTAssertEqual(JapaneseHolidays.holidayName(year: 2026, month: 1, day: 1), "元日")
        XCTAssertEqual(JapaneseHolidays.holidayName(year: 2026, month: 5, day: 6), "振替休日")
        XCTAssertEqual(JapaneseHolidays.holidayName(year: 2026, month: 9, day: 22), "国民の休日")
        XCTAssertEqual(JapaneseHolidays.holidayName(year: 2026, month: 9, day: 21), "敬老の日")
        XCTAssertNil(JapaneseHolidays.holidayName(year: 2026, month: 10, day: 19))
        XCTAssertTrue(JapaneseHolidays.isHoliday(year: 2026, month: 10, day: 12))
        let runtime = runtime("function setup() { console.log(app.holidayName(2026, 11, 3) + ',' + app.holidayName(2026, 11, 4)); }",
                              permissions: [], data: [:], granted: [])
        XCTAssertEqual(runtime.load(screen: screen).logs.map(\.text), ["文化の日,null"])
    }
}

/// データの写しの形と件数の上限
final class ScriptAppDataShapeTests: XCTestCase {
    private func json(_ text: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(text?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMockDataHasEveryKindWithFetchTimes() throws {
        let all = ScriptMockData.all(requested: ScriptPermission.allCases, now: Date())
        XCTAssertEqual(Set(all.keys), Set(ScriptDataKind.allCases.map(\.rawValue)))
        for kind in ["weather", "warnings", "quakes", "pressure", "exchange", "trains", "places", "location"] {
            let object = try json(all[kind])
            XCTAssertNotNil(object["fetchedAt"] as? Double, kind)
            XCTAssertEqual(object["sample"] as? Bool, true, kind)
        }
        let weather = try json(all["weather"])
        XCTAssertEqual((weather["hourly"] as? [Any])?.count, ScriptDataLimit.hourly)
        XCTAssertEqual((weather["daily"] as? [Any])?.count, ScriptDataLimit.daily)
        let current = try XCTUnwrap(weather["current"] as? [String: Any])
        XCTAssertEqual(current["label"] as? String, WeatherCode.label(2))
        let pressure = try json(all["pressure"])
        XCTAssertLessThanOrEqual((pressure["measured"] as? [Any])?.count ?? 0, ScriptDataLimit.measured)
        XCTAssertLessThanOrEqual((pressure["forecast"] as? [Any])?.count ?? 0, ScriptDataLimit.forecast)
        XCTAssertNotNil(pressure["change3h"] as? [String: Any])
        let trains = try json(all["trains"])
        let departures = try XCTUnwrap(trains["departures"] as? [[String: Any]])
        XCTAssertEqual((departures.first?["trains"] as? [Any])?.count, ScriptDataLimit.departures)
        XCTAssertNotNil(trains["dayType"] as? String)
        let calendar = try json(all["calendar"])
        XCTAssertEqual((calendar["days"] as? [Any])?.count, ScriptDataLimit.days)
        XCTAssertEqual((calendar["holidays"] as? [Any])?.count, ScriptDataLimit.holidays)
        let permissions = try json(all["permissions"])
        XCTAssertEqual(permissions["location.precise"] as? Bool, true)
    }

    func testLocationDetailFollowsPermissions() throws {
        let now = Date()
        let coarse = try json(ScriptMockData.all(requested: [.weather, .places, .locationCoarse], now: now)["location"])
        XCTAssertEqual(coarse["prefecture"] as? String, "東京都")
        XCTAssertTrue(coarse["latitude"] is NSNull)
        let precise = try json(ScriptMockData.all(requested: [.locationPrecise], now: now)["location"])
        XCTAssertTrue(precise["prefecture"] is NSNull)
        XCTAssertNotNil(precise["latitude"] as? Double)
        XCTAssertNil(ScriptMockData.all(requested: [.weather], now: now)["location"])
        // 天気の地点名は「おおよその地域」、緯度経度は「現在地の緯度経度」を許可したときだけ
        let weatherOnly = try json(ScriptMockData.all(requested: [.weather], now: now)["weather"])
        XCTAssertTrue(weatherOnly["place"] is NSNull)
        XCTAssertTrue(weatherOnly["latitude"] is NSNull)
        let weatherCoarse = try json(ScriptMockData.all(requested: [.weather, .locationCoarse], now: now)["weather"])
        XCTAssertNotNil(weatherCoarse["place"] as? String)
        XCTAssertTrue(weatherCoarse["latitude"] is NSNull)
        // 地点の緯度経度も同じ
        let places = try json(ScriptMockData.all(requested: [.places], now: now)["places"])
        let first = try XCTUnwrap((places["items"] as? [[String: Any]])?.first)
        XCTAssertTrue(first["latitude"] is NSNull)
        XCTAssertNotNil(first["distance"] as? Double)
        XCTAssertNil(ScriptAppData.location(ScriptAppData.Location(latitude: 1, longitude: 2, altitude: nil, accuracy: nil, time: now),
                                            coarse: false, precise: false))
    }

    func testBuildersCapCounts() {
        let now = Date()
        let waypoints = (0..<150).map { Waypoint(name: "地点\($0)", latitude: 35 + Double($0) * 0.01, longitude: 139) }
        let places = ScriptAppData.places(waypoints, origin: ScriptAppData.Origin(latitude: 35, longitude: 139, height: nil, time: now),
                                          includesCoordinates: false)
        XCTAssertEqual((places["items"] as? [[String: Any]])?.count, ScriptDataLimit.places)
        XCTAssertEqual(places["count"] as? Int, 150)
        // 近い順
        XCTAssertEqual((places["items"] as? [[String: Any]])?.first?["name"] as? String, "地点0")

        let quakes = (0..<9).map { Quake(time: now.addingTimeInterval(-Double($0) * 600), place: "震源\($0)", magnitude: 3, maxScale: 20, prefectureScales: [:]) }
        let quakeData = ScriptAppData.quakes(quakes, fetchedAt: now, homePrefecture: nil)
        XCTAssertEqual((quakeData["items"] as? [[String: Any]])?.count, ScriptDataLimit.quakes)
        XCTAssertEqual((quakeData["items"] as? [[String: Any]])?.first?["place"] as? String, "震源0")

        let warnings = WarningSnapshot(area: WarningArea(officeCode: "1", areaCodes: ["1"], name: "市", prefecture: "県"),
                                       warnings: (0..<40).map { ActiveWarning(code: "\($0)", name: "注意報", level: .advisory, status: "発表", additions: []) },
                                       reportedAt: nil)
        let warningData = ScriptAppData.warnings(warnings, fetchedAt: now, includesArea: false)
        XCTAssertEqual((warningData["items"] as? [Any])?.count, ScriptDataLimit.warnings)
        XCTAssertTrue(warningData["area"] is NSNull)

        let measured = (0..<600).map { PressureSample(time: now.addingTimeInterval(-Double($0) * 60), hPa: 1000) }
        let pressure = ScriptAppData.pressure(measured: measured, forecast: [], change: nil, latest: nil, forecastFetchedAt: nil, now: now)
        XCTAssertEqual((pressure["measured"] as? [Any])?.count, ScriptDataLimit.measured)
        XCTAssertTrue(pressure["change3h"] is NSNull)
        XCTAssertEqual(pressure["latest"] as? Double, 1000)
    }

    func testJSONValuesAreSafe() {
        XCTAssertTrue(ScriptJSON.number(Double.nan) is NSNull)
        XCTAssertTrue(ScriptJSON.number(Double.infinity) is NSNull)
        XCTAssertTrue(ScriptJSON.number(nil) is NSNull)
        XCTAssertEqual(ScriptJSON.number(1.23456, 2) as? Double, 1.23)
        XCTAssertEqual(ScriptJSON.time(Date(timeIntervalSince1970: 12.5)) as? Double, 12500)
        XCTAssertEqual(ScriptJSON.string(["a": 1]), #"{"a":1}"#)
        XCTAssertEqual(ScriptJSON.string(["a": Double.nan]), "null")
        XCTAssertEqual(ScriptJSON.string(["a": String(repeating: "x", count: ScriptDataLimit.bytes)]), "null")
    }
}

/// センサーは、ツールの画面を閉じたら必ず止まる
@MainActor
final class ScriptSessionDataTests: XCTestCase {
    final class FakeData: ScriptDataSource {
        var sensorCalls: [String] = []
        var stopped = 0
        var paused = 0
        var resumed = 0
        var onUpdate: (([String: String]) -> Void)?

        func initialData() -> [String: String] { ["permissions": #"{"sensors":true}"#] }
        func start(onUpdate: @escaping ([String: String]) -> Void) { self.onUpdate = onUpdate }
        func stop() { stopped += 1 }
        func pause() { paused += 1 }
        func resume() { resumed += 1 }
        func setSensor(_ kind: ScriptSensorKind, on: Bool) { sensorCalls.append(kind.rawValue + (on ? "+" : "-")) }
    }

    private func session(script: String, permissions: [ScriptPermission], granted: Set<ScriptPermission>, data: FakeData) throws -> ScriptSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var content = ScriptToolContent(script: script, controls: [], controlsAtTop: false, fps: 30, aspect: nil)
        content.permissions = permissions
        let tool = CustomTool(id: "sensor-test", name: "センサー", summary: "", symbol: "sensor", category: .other, keywords: [], kind: .script)
        return ScriptSession(tool: tool, content: content, isPreview: true,
                             runGuard: ScriptRunGuard(fileURL: directory.appendingPathComponent("running.json")),
                             storageDirectory: directory, granted: granted, data: data)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testSensorsStartOnRequestAndStopWhenClosed() async throws {
        let data = FakeData()
        let session = try session(script: "function setup() { app.sensors.start('heading'); }", permissions: [.sensors], granted: [.sensors], data: data)
        session.start(screen: ScriptScreen(width: 100, height: 100, dark: false, scale: 2))
        try await waitUntil { !data.sensorCalls.isEmpty }
        XCTAssertEqual(data.sensorCalls, ["heading+"])
        XCTAssertNotNil(data.onUpdate)
        session.pause()
        XCTAssertEqual(data.paused, 1)
        session.resume()
        XCTAssertEqual(data.resumed, 1)
        session.close()
        XCTAssertEqual(data.stopped, 1)
        XCTAssertEqual(session.status, .closed)
    }

    func testSensorsAreNotStartedWithoutPermission() async throws {
        let data = FakeData()
        let session = try session(script: "function setup() { console.log(String(app.sensors.start('heading'))); }",
                                  permissions: [.sensors], granted: [], data: data)
        session.start(screen: ScriptScreen(width: 100, height: 100, dark: false, scale: 2))
        try await waitUntil { !session.logs.isEmpty }
        XCTAssertEqual(session.logs.map(\.text), ["false"])
        XCTAssertEqual(data.sensorCalls, [])
        session.close()
        XCTAssertEqual(data.stopped, 1)
    }
}

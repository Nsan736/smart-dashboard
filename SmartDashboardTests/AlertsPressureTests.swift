import SwiftUI
import XCTest
@testable import SmartDashboard

/// 警報の地域の決定と抽出
final class WarningTests: XCTestCase {
    private let table = JMAAreaTable(entries: [
        .init(code: "1310100", name: "千代田区", officeCode: "130000"),
        .init(code: "1340100", name: "八丈町", officeCode: "130000"),
        .init(code: "1410011", name: "横浜市北部", officeCode: "140000"),
        .init(code: "1410012", name: "横浜市南部", officeCode: "140000"),
        .init(code: "1413000", name: "川崎市", officeCode: "140000"),
        .init(code: "0442101", name: "大和町東部", officeCode: "040000"),
        .init(code: "0442102", name: "大和町西部", officeCode: "040000"),
        .init(code: "0440100", name: "蔵王町", officeCode: "040000"),
        .init(code: "0720300", name: "郡山市", officeCode: "070000"),
        .init(code: "0720302", name: "郡山市湖南", officeCode: "070000"),
        .init(code: "2920300", name: "大和郡山市", officeCode: "290000"),
        .init(code: "0120200", name: "函館市", officeCode: "017000"),
    ])

    func testResolvesMunicipalityByName() {
        let area = WarningAreaResolver.resolve(prefecture: "東京都", municipality: "千代田区", table: table)
        XCTAssertEqual(area?.officeCode, "130000")
        XCTAssertEqual(area?.areaCodes, ["1310100"])
        XCTAssertEqual(area?.prefecture, "東京都")
        XCTAssertFalse(area?.coversWholeCity ?? true)
        // 北海道は府県予報区が複数あるので、市区町村の表から決める
        XCTAssertEqual(WarningAreaResolver.resolve(prefecture: "北海道", municipality: "函館市", table: table)?.officeCode, "017000")
    }

    func testSplitCityCoversAllParts() {
        let area = WarningAreaResolver.resolve(prefecture: "神奈川県", municipality: "横浜市", table: table)
        XCTAssertEqual(area?.areaCodes, ["1410011", "1410012"])
        XCTAssertEqual(area?.name, "横浜市")
        XCTAssertTrue(area?.coversWholeCity ?? false)
    }

    func testCountyPrefixAndConfusingNames() {
        // 「黒川郡大和町」→ 大和町(分割されているので全区域)
        XCTAssertEqual(WarningAreaResolver.resolve(prefecture: "宮城県", municipality: "黒川郡大和町", table: table)?.areaCodes,
                       ["0442101", "0442102"])
        XCTAssertEqual(WarningAreaResolver.resolve(prefecture: "宮城県", municipality: "刈田郡蔵王町", table: table)?.areaCodes, ["0440100"])
        // 「郡」を含む市の名前を壊さない。完全一致があれば、付属の区域(湖南)は含めない
        XCTAssertEqual(WarningAreaResolver.resolve(prefecture: "福島県", municipality: "郡山市", table: table)?.areaCodes, ["0720300"])
        XCTAssertEqual(WarningAreaResolver.resolve(prefecture: "奈良県", municipality: "大和郡山市", table: table)?.areaCodes, ["2920300"])
    }

    func testUnknownPlaceIsNotGuessed() {
        XCTAssertNil(WarningAreaResolver.resolve(prefecture: "東京都", municipality: "存在しない市", table: table))
        XCTAssertNil(WarningAreaResolver.resolve(prefecture: "東京都", municipality: "川崎市", table: table))
        XCTAssertNil(WarningAreaResolver.resolve(prefecture: nil, municipality: "千代田区", table: table))
        XCTAssertNil(WarningAreaResolver.resolve(prefecture: "California", municipality: "Cupertino", table: table))
        XCTAssertEqual(WarningAreaResolver.prefectureCode("沖縄県"), "47")
    }

    func testBundledTableCoversAllMunicipalities() throws {
        let table = try XCTUnwrap(JMAAreaTable.bundled())
        XCTAssertGreaterThan(table.entries.count, 1700)
        let chiyoda = WarningAreaResolver.resolve(prefecture: "東京都", municipality: "千代田区", table: table)
        XCTAssertEqual(chiyoda?.areaCodes, ["1310100"])
        XCTAssertEqual(chiyoda?.officeCode, "130000")
        XCTAssertEqual(WarningAreaResolver.resolve(prefecture: "神奈川県", municipality: "横浜市", table: table)?.areaCodes.count, 2)
        XCTAssertEqual(WarningAreaResolver.resolve(prefecture: "沖縄県", municipality: "那覇市", table: table)?.officeCode, "471000")
    }

    func testExtractsActiveWarningsFromFixture() throws {
        let reports = try JMAWarningReport.decode(Fixture.data("jma_warning_r8"))
        XCTAssertEqual(reports.count, 5)
        // 千代田区: 雷注意報が継続、濃霧注意報は解除されたので出さない
        let chiyoda = WarningExtractor.active(reports: reports, areaCodes: ["1310100"])
        XCTAssertEqual(chiyoda.map(\.name), ["雷注意報"])
        XCTAssertEqual(chiyoda.first?.additions, ["突風"])
        // 八丈町: 波浪警報が一番上に来る
        let hachijo = WarningExtractor.active(reports: reports, areaCodes: ["1340100"])
        XCTAssertEqual(hachijo.first?.name, "波浪警報")
        XCTAssertEqual(hachijo.first?.level, .warning)
        XCTAssertEqual(Set(hachijo.map(\.code)), ["07", "10", "29", "15", "14"])
        XCTAssertNotNil(WarningExtractor.latestReportDate(reports))
        // 対象の地域がなければ空
        XCTAssertTrue(WarningExtractor.active(reports: reports, areaCodes: ["9999999"]).isEmpty)
    }

    func testMergesPartsAndUnknownCodes() throws {
        let json = """
        [{"reportDatetime":"2026-09-20T10:04:00+09:00","warning":{"class20Items":[
          {"areaCode":"A","kinds":[{"status":"発表警報・注意報はなし"}]},
          {"areaCode":"B","kinds":[{"code":"43","status":"発表"},{"code":"99","status":"発表"}]}]}}]
        """
        let reports = try JMAWarningReport.decode(Data(json.utf8))
        let merged = WarningExtractor.active(reports: reports, areaCodes: ["A", "B"])
        XCTAssertEqual(merged.first?.name, "大雨危険警報")
        XCTAssertEqual(merged.first?.level, .danger)
        XCTAssertEqual(merged.last?.level, .unknown)
        XCTAssertTrue(WarningExtractor.active(reports: reports, areaCodes: ["A"]).isEmpty)
        XCTAssertEqual(WarningStore.url(officeCode: "130000").absoluteString, "https://www.jma.go.jp/bosai/warning/data/r8/130000.json")
    }

    func testUsageCategory() {
        XCTAssertEqual(UsageCategory.from(url: URL(string: "https://www.jma.go.jp/bosai/warning/data/r8/130000.json")), .alerts)
        XCTAssertEqual(UsageCategory.from(url: URL(string: "https://api.p2pquake.net/v2/history?codes=551&limit=10")), .alerts)
        XCTAssertEqual(UsageCategory.from(url: URL(string: "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json")), .radar)
    }
}

/// 地震の一覧と絞り込み
final class QuakeTests: XCTestCase {
    func testMergesReportsOfSameQuake() throws {
        let items = try P2PQuakeItem.decode(Fixture.data("p2pquake_history"))
        XCTAssertEqual(items.count, 5)
        let quakes = QuakeList.make(items)
        // 天草灘の地震は3つの報(各地の震度、震源、震度速報)が1件にまとまる
        XCTAssertEqual(quakes.count, 3)
        XCTAssertEqual(quakes[0].place, "宮古島近海")
        XCTAssertEqual(quakes[1].place, "天草灘")
        XCTAssertEqual(quakes[1].magnitude, 4.4)
        XCTAssertEqual(quakes[1].maxScale, 30)
        XCTAssertEqual(quakes[1].scale(inPrefecture: "熊本県"), 30)
        XCTAssertNil(quakes[1].scale(inPrefecture: "東京都"))
        XCTAssertEqual(QuakeList.make(items, limit: 2).count, 2)
    }

    func testRecentFilterAndMerge() throws {
        let now = try XCTUnwrap(QuakeList.parseTime("2026/09/20 12:00:00"))
        func quake(_ hoursAgo: Double, _ scale: Int?) -> Quake {
            Quake(time: now.addingTimeInterval(-hoursAgo * 3600), place: "テスト", magnitude: 4, maxScale: scale, prefectureScales: [:])
        }
        let quakes = [quake(1, 10), quake(5, 30), quake(23, 45), quake(25, 50), quake(2, nil)]
        XCTAssertEqual(QuakeList.recent(quakes, minimumScale: 30, now: now).map(\.maxScale), [30, 45])
        XCTAssertEqual(QuakeList.recent(quakes, minimumScale: 45, now: now).count, 1)
        XCTAssertTrue(QuakeList.recent(quakes, minimumScale: 60, now: now).isEmpty)
        // 小さな地震が続いても、24時間以内の地震は残す。それより古いものは新しい順の5件まで
        let small = (0..<6).map { quake(Double($0) * 0.5 + 0.1, 10) }
        let merged = QuakeList.merge(old: [quake(20, 40), quake(30, 50)], new: small, now: now)
        XCTAssertEqual(merged.count, 7)
        XCTAssertTrue(merged.contains { $0.maxScale == 40 })
        XCTAssertFalse(merged.contains { $0.maxScale == 50 })
        XCTAssertEqual(SeismicScale.label(45), "5弱")
        XCTAssertEqual(QuakeStore.url().absoluteString, "https://api.p2pquake.net/v2/history?codes=551&limit=10")
    }
}

/// 気圧の記録、予報の補正、変化量
final class PressureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// 予報は1時間ごと、過去24時間〜今後24時間。1時間に0.5hPaずつ下がる。
    private var forecast: [PressureForecastPoint] {
        (-24...24).map { PressureForecastPoint(time: now.addingTimeInterval(Double($0) * 3600), hPa: 1010 - Double($0) * 0.5) }
    }

    func testDecodesPressureFromRealResponse() throws {
        let response = try OpenMeteoClient.decode(Fixture.data("open_meteo_pressure"))
        XCTAssertEqual(response.hourly.time.count, 48)
        let snapshot = WeatherSnapshot(response: response, sourceID: "current", placeName: "テスト")
        XCTAssertEqual(snapshot.hourly.compactMap(\.pressure).count, 48)
        // 過去の時間帯が入っても、今後の予報の表示には出さない
        let current = snapshot.current.time
        XCTAssertTrue(snapshot.upcomingHours(now: current).allSatisfy { $0.time > current.addingTimeInterval(-3600) })
    }

    func testRecordingRule() {
        XCTAssertTrue(PressureLog.shouldRecord(last: nil, now: now))
        XCTAssertFalse(PressureLog.shouldRecord(last: now.addingTimeInterval(-299), now: now))
        XCTAssertTrue(PressureLog.shouldRecord(last: now.addingTimeInterval(-300), now: now))
        let samples = [PressureSample(time: now.addingTimeInterval(-49 * 3600), hPa: 1000),
                       PressureSample(time: now.addingTimeInterval(-47 * 3600), hPa: 1001)]
        XCTAssertEqual(PressureLog.trimmed(samples, now: now).map(\.hPa), [1001])
    }

    func testForecastIsShiftedToMeetMeasured() {
        // 実測は直近1時間だけ。予報より2hPa低い。
        let measured = stride(from: -60.0, through: 0, by: 5).map {
            PressureSample(time: now.addingTimeInterval($0 * 60), hPa: 1008 - $0 / 60 * 0.5)
        }
        let series = PressureSeries.make(measured: measured, forecast: forecast, now: now)
        XCTAssertEqual(series.correction, -2, accuracy: 0.001)
        XCTAssertTrue(series.hasMeasured)
        // 実測のある時間帯(±30分)には予報の点を入れない
        XCTAssertFalse(series.points.contains { $0.source == .forecast && abs($0.time.timeIntervalSince(now)) < 3600 })
        // 境目で段差にならない: 最後の実測(1008)と、1時間後の予報の差は、予報どおりの変化(1時間で−0.5)だけ
        let next = series.points.first { $0.source == .forecast && $0.time > now }
        XCTAssertEqual(next?.hPa ?? 0, 1008 - 0.5, accuracy: 0.001)
        XCTAssertEqual(series.nearest(to: now.addingTimeInterval(10))?.source, .measured)
        XCTAssertEqual(series.nearest(to: now.addingTimeInterval(5 * 3600))?.source, .forecast)
        XCTAssertEqual(series.points, series.points.sorted { $0.time < $1.time })
    }

    func testWithoutMeasuredUsesForecastAsIs() {
        let series = PressureSeries.make(measured: [], forecast: forecast, now: now)
        XCTAssertEqual(series.correction, 0)
        XCTAssertFalse(series.hasMeasured)
        XCTAssertEqual(series.points.count, 49)
        XCTAssertEqual(PressureSeries.interpolate(forecast, at: now.addingTimeInterval(1800)) ?? 0, 1009.75, accuracy: 0.001)
        XCTAssertNil(PressureSeries.interpolate(forecast, at: now.addingTimeInterval(25 * 3600)))
    }

    func testChangeOverThreeHours() throws {
        // 起点は最新の実測(予報より2hPa低い)。終点は補正した予報なので、差は予報どおりの −1.5
        let measured = [PressureSample(time: now.addingTimeInterval(-120), hPa: 1008 + 120.0 / 3600 * 0.5)]
        let change = try XCTUnwrap(PressureChange.make(measured: measured, forecast: forecast, now: now))
        XCTAssertTrue(change.baseIsMeasured)
        XCTAssertEqual(change.delta, -1.5, accuracy: 0.02)
        XCTAssertEqual(change.text, "今後3時間の変化：−1.5hPa")
        XCTAssertFalse(change.isAlert(threshold: 4))
        XCTAssertTrue(change.isAlert(threshold: 1.5 - 0.1))
        // 実測が古い(30分より前)ときは、予報を起点にする
        let old = [PressureSample(time: now.addingTimeInterval(-3 * 3600), hPa: 990)]
        let fromForecast = try XCTUnwrap(PressureChange.make(measured: old, forecast: forecast, now: now))
        XCTAssertFalse(fromForecast.baseIsMeasured)
        XCTAssertEqual(fromForecast.delta, -1.5, accuracy: 0.001)
        XCTAssertNil(PressureChange.make(measured: [], forecast: [], now: now))
    }

    func testBackgroundRecordingVerdict() {
        let start = now.addingTimeInterval(-3600)
        let every5 = stride(from: 300.0, to: 3600, by: 300).map { start.addingTimeInterval($0) }
        XCTAssertEqual(BackgroundRecordingCheck.verdict(backgroundStart: start, end: now, sampleTimes: every5), .recorded)
        XCTAssertEqual(BackgroundRecordingCheck.verdict(backgroundStart: start, end: now, sampleTimes: []), .notRecorded)
        // 閉じた直後の1件だけでは「記録できた」としない
        XCTAssertEqual(BackgroundRecordingCheck.verdict(backgroundStart: start, end: now, sampleTimes: [start.addingTimeInterval(30)]), .notRecorded)
        XCTAssertEqual(BackgroundRecordingCheck.verdict(backgroundStart: now.addingTimeInterval(-600), end: now, sampleTimes: []), .tooShort)
    }

    func testBackgroundStopReasons() {
        XCTAssertEqual(BackgroundStopReason.decide(enabled: false, batteryLevel: 1, isLowPowerMode: false), .disabled)
        XCTAssertEqual(BackgroundStopReason.decide(enabled: true, batteryLevel: 0.19, isLowPowerMode: false), .lowBattery)
        XCTAssertEqual(BackgroundStopReason.decide(enabled: true, batteryLevel: 0.9, isLowPowerMode: true), .lowPowerMode)
        XCTAssertNil(BackgroundStopReason.decide(enabled: true, batteryLevel: 0.2, isLowPowerMode: false))
        // 電池残量が分からない(シミュレーターなど)ときは止めない
        XCTAssertNil(BackgroundStopReason.decide(enabled: true, batteryLevel: -1, isLowPowerMode: false))
    }
}

/// ホームのカードの並び順と表示
final class HomeLayoutTests: XCTestCase {
    func testInitialOrderKeepsExistingCardsFirst() {
        let layout = HomeLayout.initial
        XCTAssertEqual(layout.order.prefix(8), [.timer, .nextTrain, .trainInfo, .weather, .rain, .exchange, .speed, .sensors])
        XCTAssertEqual(layout.order.suffix(3), [.warnings, .quakes, .pressure])
        XCTAssertEqual(layout.visible, layout.order)
    }

    func testNewCardsAreAppendedAndUnknownOnesDropped() {
        let stored = Data(#"{"order":["exchange","removedCard","weather","exchange"],"hidden":["weather","removedCard"]}"#.utf8)
        let layout = HomeLayout.decode(stored)
        XCTAssertEqual(layout.order.prefix(2), [.exchange, .weather])
        XCTAssertEqual(layout.order.count, HomeCardKind.allCases.count)
        XCTAssertEqual(Set(layout.order), Set(HomeCardKind.allCases))
        XCTAssertEqual(layout.hidden, [.weather])
        XCTAssertFalse(layout.visible.contains(.weather))
        XCTAssertEqual(HomeLayout.decode(nil), .initial)
        XCTAssertEqual(HomeLayout.decode(Data("broken".utf8)), .initial)
    }

    func testRoundTripAndFetchNeeds() {
        var layout = HomeLayout.initial
        layout.order.move(fromOffsets: IndexSet(integer: 10), toOffset: 0)
        layout.hidden = [.exchange, .quakes, .speed]
        XCTAssertEqual(HomeLayout.decode(layout.encoded()), layout)
        XCTAssertEqual(layout.order.first, .pressure)
        XCTAssertFalse(layout.needsExchange)
        XCTAssertFalse(layout.needsQuakes)
        XCTAssertTrue(layout.needsWeather)
        // 天気を使うカードをすべて隠したら、天気も取得しない
        layout.hidden = [.weather, .rain, .pressure, .warnings]
        XCTAssertFalse(layout.needsWeather)
        XCTAssertFalse(layout.needsRain)
    }

    @MainActor
    func testSettingsPersistLayoutAndMigrateSpeedToggle() {
        let name = "HomeLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(false, forKey: "home.showsSpeed")
        let settings = AppSettings(defaults: defaults)
        // 以前「ホームで速度を表示する」をオフにしていたら、速度のカードを非表示で引き継ぐ
        XCTAssertEqual(settings.homeLayout.hidden, [.speed])
        settings.homeLayout.hidden.insert(.quakes)
        XCTAssertEqual(AppSettings(defaults: defaults).homeLayout.hidden, [.speed, .quakes])
        XCTAssertEqual(settings.quakeMinimumScale, 30)
        XCTAssertEqual(settings.pressureAlertDrop, 4)
        XCTAssertFalse(settings.backgroundPressureEnabled)
    }
}

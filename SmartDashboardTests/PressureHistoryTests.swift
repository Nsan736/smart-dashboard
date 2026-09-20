import XCTest
@testable import SmartDashboard

/// 気圧の履歴(追記、重複の除去、保存期間)、間引き、急な低下の区間、詳細画面のデータ
final class PressureHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func point(_ hours: Double, _ hPa: Double) -> PressureHistory.Point {
        PressureHistory.Point(time: now.addingTimeInterval(hours * 3600), hPa: hPa)
    }

    private func chartPoint(_ hours: Double, _ hPa: Double, _ source: PressurePoint.Source = .forecast) -> PressurePoint {
        PressurePoint(time: now.addingTimeInterval(hours * 3600), hPa: hPa, source: source)
    }

    func testDecodesHistoryFixtureAndSkipsNulls() throws {
        let response = try JSONDecoder().decode(OpenMeteoPressureResponse.self, from: Fixture.data("open_meteo_pressure_history"))
        XCTAssertEqual(response.points.count, 72)
        XCTAssertEqual(response.points[1].time.timeIntervalSince(response.points[0].time), 3600)
        // Forecast API の past_days では、古い時間帯が null で返る。null は捨てる
        let withNulls = try JSONDecoder().decode(OpenMeteoPressureResponse.self,
                                                 from: Data(#"{"hourly":{"time":[0,3600,7200],"surface_pressure":[null,1010.5,null]}}"#.utf8))
        XCTAssertEqual(withNulls.points.map(\.hPa), [1010.5])
    }

    func testMergeAppendsDeduplicatesAndTrims() {
        let base = PressureHistory(latitude: 35.68, longitude: 139.76,
                                   points: [point(-101 * 24, 990), point(-99 * 24, 1000), point(-2, 1005), point(-1, 1006)], backfilledAt: now)
        let merged = base.merged(with: [point(-1, 1007), point(0, 1008), point(24, 1001), point(-3, 1004)], now: now)
        // 100日より古いものは捨て、同じ時刻は新しい値で置き換え、時刻順に並べる。未来の分は残す
        XCTAssertEqual(merged.points.map(\.hPa), [1000, 1004, 1005, 1007, 1008, 1001])
        XCTAssertEqual(merged.points, merged.points.sorted { $0.time < $1.time })
        XCTAssertEqual(merged.backfilledAt, now)
        XCTAssertEqual(merged.lastPastTime(now: now), now)
        // 同じ内容をもう一度足しても変わらない
        XCTAssertEqual(merged.merged(with: [point(0, 1008)], now: now), merged)
    }

    func testIncrementalRangeAndBackfillDecision() {
        var history = PressureHistory.empty(latitude: 35.68, longitude: 139.76)
        XCTAssertTrue(history.needsBackfill(now: now))
        XCTAssertEqual(history.neededPastHours(now: now), 24)
        history = history.merged(with: [point(-50, 1000)], now: now)
        // まとめての取得がまだなら、保存があっても必要
        XCTAssertTrue(history.needsBackfill(now: now))
        history.backfilledAt = now.addingTimeInterval(-50 * 3600)
        XCTAssertFalse(history.needsBackfill(now: now))
        // 足りない分だけ: 空白50時間 → 52時間分。上限は168時間
        XCTAssertEqual(history.neededPastHours(now: now), 52)
        XCTAssertEqual(history.neededPastHours(now: now.addingTimeInterval(30 * 24 * 3600)), 168)
        // 空白が7日を超えたら、まとめて取り直す
        XCTAssertTrue(history.needsBackfill(now: now.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertFalse(history.needsBackfill(now: now.addingTimeInterval(4 * 24 * 3600)))
    }

    func testRelocation() {
        let tokyo = PressureHistory.empty(latitude: 35.68, longitude: 139.76)
        XCTAssertFalse(tokyo.isFar(latitude: 35.44, longitude: 139.64))
        XCTAssertTrue(tokyo.isFar(latitude: 34.69, longitude: 135.50))
        XCTAssertEqual(PressureHistory.distanceKm(35.68, 139.76, 34.69, 135.50), 397, accuracy: 10)
    }

    func testRequests() {
        let backfill = PressureRequests.backfillURL(latitude: 35.681, longitude: 139.767, now: now)
        XCTAssertEqual(backfill.host, "historical-forecast-api.open-meteo.com")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: backfill, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["hourly"], "surface_pressure")
        XCTAssertEqual(items["timeformat"], "unixtime")
        XCTAssertEqual(items["end_date"], "2026-09-21")
        XCTAssertEqual(items["start_date"], "2026-06-14")
        XCTAssertEqual(items["latitude"], "35.68")
        let outlook = PressureRequests.outlookURL(latitude: 35.681, longitude: 139.767, pastHours: 52)
        XCTAssertEqual(outlook.host, "api.open-meteo.com")
        XCTAssertTrue(outlook.absoluteString.contains("past_hours=52"))
        XCTAssertTrue(outlook.absoluteString.contains("forecast_hours=168"))
        XCTAssertEqual(UsageCategory.from(url: backfill), .weather)
    }

    func testSampleFilesRoundTrip() {
        let samples = [PressureSample(time: Date(timeIntervalSince1970: 1_790_000_100), hPa: 1008.256, inBackground: true),
                       PressureSample(time: Date(timeIntervalSince1970: 1_790_000_400), hPa: 1008.3, inBackground: false)]
        let decoded = PressureSampleCodec.decode(PressureSampleCodec.encode(samples))
        XCTAssertEqual(decoded.map(\.time), samples.map(\.time))
        XCTAssertEqual(decoded[0].hPa, 1008.26, accuracy: 0.001)
        XCTAssertEqual(decoded.map(\.inBackground), [true, false])
        XCTAssertEqual(PressureSampleCodec.dayIndex(Date(timeIntervalSince1970: 86400 * 3 + 5)), 3)
        XCTAssertTrue(PressureSampleCodec.decode(Data("broken".utf8)).isEmpty)
        // 1件あたり約30バイト → 100日分(28,800件)で1MB未満
        XCTAssertLessThan(PressureSampleCodec.encode(samples).count / samples.count, 40)
    }

    func testThinning() {
        // 5分ごとの実測を1時間ごとにまとめる
        let base = (now.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        let fine = (0..<24).map { PressurePoint(time: Date(timeIntervalSince1970: base + Double($0) * 300), hPa: 1000 + Double($0), source: .measured) }
        let thinned = PressureThinning.thin(fine, step: 3600)
        XCTAssertEqual(thinned.count, 2)
        XCTAssertEqual(thinned[0].hPa, 1005.5, accuracy: 0.001)
        XCTAssertEqual(thinned[0].source, .measured)
        // 区切りの中に実測があれば、実測だけを使う
        let mixed = [PressurePoint(time: Date(timeIntervalSince1970: base), hPa: 990, source: .forecast),
                     PressurePoint(time: Date(timeIntervalSince1970: base + 600), hPa: 1000, source: .measured)]
        XCTAssertEqual(PressureThinning.thin(mixed, step: 3600), [PressurePoint(time: Date(timeIntervalSince1970: base + 600), hPa: 1000, source: .measured)])
        // 1時間ごとの予報は、時刻がずれない
        let hourly = (0..<5).map { PressurePoint(time: Date(timeIntervalSince1970: base + Double($0) * 3600), hPa: 1000, source: .forecast) }
        XCTAssertEqual(PressureThinning.thin(hourly, step: 3600), hourly)
        XCTAssertEqual(PressureThinning.thin(hourly, step: 0), hourly)
    }

    func testDropIntervals() {
        // 0〜10時間は横ばい、10〜13時間で6hPa下がり、その後は横ばい
        let points = (0...24).map { hour -> PressurePoint in
            let h = Double(hour)
            let value = h <= 10 ? 1010 : (h <= 13 ? 1010 - (h - 10) * 2 : 1004)
            return chartPoint(h, value)
        }
        let intervals = PressureAnalysis.dropIntervals(in: points, threshold: 4)
        XCTAssertEqual(intervals.count, 1)
        // 3時間で4hPa以上下がった時刻は 12〜14時。区間は下がり始め(3時間前)から含める
        XCTAssertEqual(intervals[0].start, now.addingTimeInterval(9 * 3600))
        XCTAssertEqual(intervals[0].end, now.addingTimeInterval(14 * 3600))
        XCTAssertTrue(PressureAnalysis.dropIntervals(in: points, threshold: 7).isEmpty)
        XCTAssertTrue(PressureAnalysis.dropIntervals(in: [], threshold: 4).isEmpty)
        XCTAssertEqual(PressureAnalysis.change(in: points, at: now.addingTimeInterval(13 * 3600)) ?? 0, -6, accuracy: 0.001)
        XCTAssertNil(PressureAnalysis.change(in: points, at: now.addingTimeInterval(2 * 3600)))
        XCTAssertEqual(PressureAnalysis.value(in: points, at: now.addingTimeInterval(11.5 * 3600)) ?? 0, 1007, accuracy: 0.001)
        XCTAssertEqual(PressureAnalysis.nearest(in: points, to: now.addingTimeInterval(11.4 * 3600))?.time, now.addingTimeInterval(11 * 3600))
    }

    func testStats() throws {
        let calendar = JapaneseHolidays.calendar
        let midnight = calendar.startOfDay(for: now)
        let points = (0..<48).map { PressurePoint(time: midnight.addingTimeInterval(Double($0) * 3600), hPa: 1000 + Double($0), source: .forecast) }
        let stats = try XCTUnwrap(PressureStats.make(points, from: midnight, to: midnight.addingTimeInterval(47 * 3600), calendar: calendar))
        XCTAssertEqual(stats.high, 1047)
        XCTAssertEqual(stats.low, 1000)
        XCTAssertEqual(stats.mean, 1023.5, accuracy: 0.001)
        // 新しい日が上
        XCTAssertEqual(stats.days.map(\.high), [1047, 1023])
        XCTAssertEqual(stats.days.map(\.low), [1024, 1000])
        XCTAssertNil(PressureStats.make(points, from: midnight.addingTimeInterval(-7200), to: midnight.addingTimeInterval(-3600), calendar: calendar))
    }

    func testLongSeriesUsesMeasuredWhereAvailable() {
        // 予報モデルは過去100日〜7日先の1時間ごと。実測は3日前の1時間分だけ
        let forecast = stride(from: -100.0 * 24, through: 7 * 24, by: 1).map { PressureForecastPoint(time: now.addingTimeInterval($0 * 3600), hPa: 1010) }
        let measured = stride(from: -72.0 * 60, through: -71 * 60, by: 5).map { PressureSample(time: now.addingTimeInterval($0 * 60), hPa: 1008) }
        let series = PressureSeries.make(measured: measured, forecast: forecast, now: now,
                                         past: PressureDetailData.past, future: PressureDetailData.future)
        XCTAssertEqual(series.correction, -2, accuracy: 0.001)
        XCTAssertEqual(series.points.first?.time, now.addingTimeInterval(-100 * 24 * 3600))
        XCTAssertEqual(series.points.last?.time, now.addingTimeInterval(7 * 24 * 3600))
        XCTAssertEqual(series.points.filter { $0.source == .measured }.count, 13)
        // 実測のある時間帯(−72時間と−71時間)には、予報モデルの点を入れない
        XCTAssertEqual(series.points.filter { $0.source == .forecast }.count, forecast.count - 2)
        XCTAssertTrue(PressureSeries.hasSample(near: now, in: [now.addingTimeInterval(-1700)]))
        XCTAssertFalse(PressureSeries.hasSample(near: now, in: [now.addingTimeInterval(-1900), now.addingTimeInterval(1900)]))
    }

    func testDetailDataThinsByRange() {
        let full = stride(from: -10.0 * 24 * 12, through: 0, by: 1).map { chartPoint($0 / 12, 1000, .measured) }
        let hourly = PressureThinning.thin(full, step: 3600)
        XCTAssertEqual(PressureDetailData.displayed(full: full, hourly: hourly, span: .month, center: now), hourly)
        let week = PressureDetailData.displayed(full: full, hourly: hourly, span: .week, center: now)
        XCTAssertLessThan(week.count, full.count / 5)
        // 1日表示は、表示中の付近(前後1.5日)だけ細かく、それ以外は1時間ごと
        let day = PressureDetailData.displayed(full: full, hourly: hourly, span: .day, center: now.addingTimeInterval(-5 * 24 * 3600))
        XCTAssertLessThan(day.count, 3 * 24 * 12 + hourly.count)
        XCTAssertGreaterThan(day.count, 3 * 24 * 12)
        XCTAssertEqual(day, day.sorted { $0.time < $1.time })
        // 開いたときは「今」が左から75%の位置。幅を変えても中央の時刻は同じ
        let start = PressureDetailData.initialScroll(now: now, span: .week)
        XCTAssertEqual(now.timeIntervalSince(start), 0.75 * 7 * 24 * 3600, accuracy: 1)
        let switched = PressureDetailData.scroll(keepingCenterOf: start, from: .week, to: .day)
        XCTAssertEqual(switched.addingTimeInterval(12 * 3600), start.addingTimeInterval(3.5 * 24 * 3600))
        XCTAssertEqual(PressureDetailData.fiveSteps(in: 995...1016), [995, 1000, 1005, 1010, 1015])
        XCTAssertEqual(PressureDetailData.dayStarts(from: now, to: now.addingTimeInterval(3 * 24 * 3600)).count, 4)
    }

    func testOldWeatherCacheIsRefetched() throws {
        // 気圧の項目がない古い形式のキャッシュは、更新間隔に関係なく取り直す
        let old = try OpenMeteoClient.decode(Fixture.data("open_meteo"))
        XCTAssertFalse(WeatherStore.isUsable(WeatherSnapshot(response: old, sourceID: "current", placeName: "テスト")))
        let current = try OpenMeteoClient.decode(Fixture.data("open_meteo_pressure"))
        XCTAssertTrue(WeatherStore.isUsable(WeatherSnapshot(response: current, sourceID: "current", placeName: "テスト")))
        XCTAssertFalse(WeatherStore.isUsable(nil))
    }
}

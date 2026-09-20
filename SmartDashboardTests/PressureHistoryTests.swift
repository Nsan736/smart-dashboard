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

    func testDecodesOutlookFixtureAndSkipsNulls() throws {
        // past_hours=24、forecast_hours=384(16日先)の実際の応答。末尾の11時間分は null で返る。null は捨てる
        let response = try JSONDecoder().decode(OpenMeteoPressureResponse.self, from: Fixture.data("open_meteo_pressure_outlook"))
        XCTAssertEqual(response.hourly.time.count, 408)
        XCTAssertEqual(response.points.count, 397)
        XCTAssertEqual(response.points[1].time.timeIntervalSince(response.points[0].time), 3600)
        let span = try XCTUnwrap(response.points.last).time.timeIntervalSince(response.points[0].time)
        XCTAssertGreaterThan(span, 16 * 24 * 3600)
    }

    func testMergeAppendsDeduplicatesAndTrims() {
        let base = PressureHistory(latitude: 35.68, longitude: 139.76,
                                   points: [point(-8 * 24, 990), point(-6 * 24, 1000), point(-2, 1005), point(-1, 1006)], backfilledAt: nil)
        let merged = base.merged(with: [point(-1, 1007), point(0, 1008), point(24, 1001), point(-3, 1004)], now: now)
        // 7日より古いものは捨て、同じ時刻は新しい値で置き換え、時刻順に並べる。未来の分は残す
        XCTAssertEqual(merged.points.map(\.hPa), [1000, 1004, 1005, 1007, 1008, 1001])
        XCTAssertEqual(merged.points, merged.points.sorted { $0.time < $1.time })
        XCTAssertEqual(merged.lastPastTime(now: now), now)
        // 同じ内容をもう一度足しても変わらない
        XCTAssertEqual(merged.merged(with: [point(0, 1008)], now: now), merged)
    }

    func testOldHundredDayDataIsCutToSevenDays() throws {
        // 以前の版で保存した100日分(backfilledAt 付き)を読み込み、何も足さずに整理すると、7日分と未来の分だけが残る
        let old = PressureHistory(latitude: 35.68, longitude: 139.76,
                                  points: stride(from: -100.0 * 24, through: 7 * 24, by: 1).map { point($0, 1010) }, backfilledAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let loaded = try decoder.decode(PressureHistory.self, from: encoder.encode(old))
        let trimmed = loaded.merged(with: [], now: now)
        XCTAssertEqual(trimmed.points.count, 7 * 24 + 7 * 24 + 1)
        XCTAssertEqual(trimmed.points.first?.time, now.addingTimeInterval(-7 * 24 * 3600))
        XCTAssertEqual(trimmed.points.last?.time, now.addingTimeInterval(7 * 24 * 3600))
        // 実測も7日分だけを残す
        let samples = [PressureSample(time: now.addingTimeInterval(-50 * 24 * 3600), hPa: 1000),
                       PressureSample(time: now.addingTimeInterval(-6.9 * 24 * 3600), hPa: 1001)]
        XCTAssertEqual(PressureLog.trimmed(samples, now: now).map(\.hPa), [1001])
    }

    func testNeededPastHoursFillsOnlyTheGap() {
        // 保存がなければ、表示する4日分(余裕を含めて98時間)
        XCTAssertEqual(PressureHistory.empty(latitude: 35.68, longitude: 139.76).neededPastHours(now: now), 98)
        // 過去4日分が1時間ごとにそろっていれば、最小の24時間
        let complete = PressureHistory(latitude: 35.68, longitude: 139.76,
                                       points: stride(from: -96.0, through: 0, by: 1).map { point($0, 1010) }, backfilledAt: nil)
        XCTAssertEqual(complete.neededPastHours(now: now), 24)
        // 最後の保存が50時間前 → 52時間分
        let stale = PressureHistory(latitude: 35.68, longitude: 139.76,
                                    points: stride(from: -96.0, through: -50, by: 1).map { point($0, 1010) }, backfilledAt: nil)
        XCTAssertEqual(stale.neededPastHours(now: now), 52)
        // 途中の空白(70〜30時間前)。直近24時間は天気の更新で埋まっていても、空白の始まりから取り直す
        let holed = PressureHistory(latitude: 35.68, longitude: 139.76,
                                    points: (Array(stride(from: -96.0, through: -70, by: 1)) + Array(stride(from: -30.0, through: 0, by: 1))).map { point($0, 1010) },
                                    backfilledAt: nil)
        XCTAssertEqual(holed.neededPastHours(now: now), 72)
    }

    func testRelocation() {
        let tokyo = PressureHistory.empty(latitude: 35.68, longitude: 139.76)
        XCTAssertFalse(tokyo.isFar(latitude: 35.44, longitude: 139.64))
        XCTAssertTrue(tokyo.isFar(latitude: 34.69, longitude: 135.50))
        XCTAssertEqual(PressureHistory.distanceKm(35.68, 139.76, 34.69, 135.50), 397, accuracy: 10)
    }

    func testRequests() {
        let outlook = PressureRequests.outlookURL(latitude: 35.681, longitude: 139.767, pastHours: 52)
        XCTAssertEqual(outlook.host, "api.open-meteo.com")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: outlook, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["hourly"], "surface_pressure")
        XCTAssertEqual(items["timeformat"], "unixtime")
        XCTAssertEqual(items["latitude"], "35.68")
        XCTAssertEqual(items["past_hours"], "52")
        // 予報は Open-Meteo の上限の16日先(384時間)まで
        XCTAssertEqual(items["forecast_hours"], "384")
        XCTAssertEqual(UsageCategory.from(url: outlook), .weather)
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
        // 1件あたり約25バイト → 7日分(2,016件)で約50KB
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

    func testDetailSeriesCoversFourDaysBackToSixteenDaysAhead() {
        // 保存は過去7日〜16日先の1時間ごと。実測は3日前の1時間分だけ
        let forecast = stride(from: -7.0 * 24, through: 16 * 24, by: 1).map { PressureForecastPoint(time: now.addingTimeInterval($0 * 3600), hPa: 1010) }
        let measured = stride(from: -72.0 * 60, through: -71 * 60, by: 5).map { PressureSample(time: now.addingTimeInterval($0 * 60), hPa: 1008) }
        let series = PressureSeries.make(measured: measured, forecast: forecast, now: now,
                                         past: PressureDetailData.past, future: PressureDetailData.future)
        XCTAssertEqual(series.correction, -2, accuracy: 0.001)
        // 表示は過去4日分だけ(保存は7日分あっても出さない)。先は16日先まで
        XCTAssertEqual(series.points.first?.time, now.addingTimeInterval(-4 * 24 * 3600))
        XCTAssertEqual(series.points.last?.time, now.addingTimeInterval(16 * 24 * 3600))
        XCTAssertEqual(series.points.filter { $0.source == .measured }.count, 13)
        // 実測のある時間帯(−72時間と−71時間)には、予報モデルの点を入れない
        XCTAssertEqual(series.points.filter { $0.source == .forecast }.count, 20 * 24 + 1 - 2)
        XCTAssertTrue(PressureSeries.hasSample(near: now, in: [now.addingTimeInterval(-1700)]))
        XCTAssertFalse(PressureSeries.hasSample(near: now, in: [now.addingTimeInterval(-1900), now.addingTimeInterval(1900)]))
    }

    func testDetailRangeAndScroll() {
        let domain = PressureDetailData.domain(now: now)
        XCTAssertEqual(domain.lowerBound, now.addingTimeInterval(-4 * 24 * 3600))
        XCTAssertEqual(domain.upperBound, now.addingTimeInterval(16 * 24 * 3600))
        XCTAssertEqual(PressureSpan.all.seconds, 20 * 24 * 3600)
        XCTAssertEqual(PressureSpan.allCases.map(\.label), ["1日", "1週間", "全体"])
        // 開いたときは「今」が左から25%の位置
        let week = PressureDetailData.initialScroll(now: now, span: .week)
        XCTAssertEqual(now.timeIntervalSince(week), 0.25 * 7 * 24 * 3600, accuracy: 1)
        XCTAssertEqual(now.timeIntervalSince(PressureDetailData.initialScroll(now: now, span: .day)), 6 * 3600, accuracy: 1)
        // 全体表示は、範囲の左端から(スクロールしない)
        XCTAssertEqual(PressureDetailData.initialScroll(now: now, span: .all), domain.lowerBound)
        // 幅を変えても中央の時刻は同じ。範囲の外には出ない
        let day = PressureDetailData.scroll(keepingCenterOf: week, from: .week, to: .day, now: now)
        XCTAssertEqual(day.addingTimeInterval(12 * 3600), week.addingTimeInterval(3.5 * 24 * 3600))
        XCTAssertEqual(PressureDetailData.scroll(keepingCenterOf: week, from: .week, to: .all, now: now), domain.lowerBound)
        let end = PressureDetailData.clamped(now.addingTimeInterval(30 * 24 * 3600), span: .week, now: now)
        XCTAssertEqual(end, domain.upperBound.addingTimeInterval(-7 * 24 * 3600))
        XCTAssertEqual(PressureDetailData.clamped(now.addingTimeInterval(-30 * 24 * 3600), span: .day, now: now), domain.lowerBound)
    }

    func testDetailDataThinsByRange() {
        // 過去4日分の5分ごとの実測と、16日先までの1時間ごとの予報
        let measured = stride(from: -4.0 * 24 * 12, through: 0, by: 1).map { chartPoint($0 / 12, 1000, .measured) }
        let forecast = stride(from: 1.0, through: 16 * 24, by: 1).map { chartPoint($0, 1000) }
        let full = measured + forecast
        // 1日表示は間引かない。1週間は30分ごと、全体は1時間ごと
        XCTAssertEqual(PressureDetailData.displayed(full: full, span: .day), full)
        let week = PressureDetailData.displayed(full: full, span: .week)
        let all = PressureDetailData.displayed(full: full, span: .all)
        XCTAssertLessThan(week.count, 4 * 48 + 16 * 24 + 3)
        XCTAssertGreaterThan(week.count, all.count)
        XCTAssertLessThan(all.count, 20 * 24 + 3)
        XCTAssertEqual(all, all.sorted { $0.time < $1.time })
        // 予報の点は、間引いても時刻も数も変わらない
        XCTAssertEqual(all.filter { $0.source == .forecast }, forecast)
        XCTAssertEqual(PressureDetailData.fiveSteps(in: 995...1016), [995, 1000, 1005, 1010, 1015])
        let days = PressureDetailData.dayStarts(from: now, to: now.addingTimeInterval(3 * 24 * 3600))
        XCTAssertEqual(days.count, 4)
        // 全体表示のラベルは月曜と木曜だけ
        let twenty = PressureDetailData.dayStarts(from: now, to: now.addingTimeInterval(19.5 * 24 * 3600))
        XCTAssertLessThanOrEqual(PressureDetailData.labeledDays(twenty, span: .all).count, 6)
        XCTAssertEqual(PressureDetailData.labeledDays(twenty, span: .week), twenty)
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

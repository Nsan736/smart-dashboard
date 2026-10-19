import XCTest
@testable import SmartDashboard

/// Swift のままの内蔵ツール(世界時計・メトロノーム)と、JSON のリスト型のルーレットの円盤
final class MoreToolLogicTests: XCTestCase {
    // MARK: - ルーレット

    func testRouletteStopsOnTheResult() {
        for count in [1, 2, 3, 7, 12, 40] {
            var rotation = 0.0
            for index in 0..<count {
                for fraction in [0.0, 0.15, 0.5, 0.85, 1.0] {
                    let target = RouletteWheel.stopRotation(current: rotation, index: index, count: count, turns: 4, fraction: fraction)
                    XCTAssertGreaterThanOrEqual(target, rotation + 4 * 360)
                    XCTAssertLessThan(target, rotation + 5 * 360 + 0.0001)
                    XCTAssertEqual(RouletteWheel.index(atRotation: target, count: count), index)
                    rotation = target
                }
            }
        }
        // 回していなければ、針の下は先頭の項目。少し時計回りに回すと、最後の項目
        XCTAssertEqual(RouletteWheel.index(atRotation: 0, count: 4), 0)
        XCTAssertEqual(RouletteWheel.index(atRotation: 10, count: 4), 3)
        XCTAssertEqual(RouletteWheel.index(atRotation: -100, count: 4), 1)
    }

    func testRouletteShortName() {
        XCTAssertEqual(RouletteWheel.shortName("ABCDEF", units: 6), "ABCDEF")
        XCTAssertEqual(RouletteWheel.shortName("あいうえお", units: 6), "あいう…")
        XCTAssertEqual(RouletteWheel.shortName("ｱｲｳｴｵｶｷ", units: 6), "ｱｲｳｴｵｶ…")
        XCTAssertTrue(RouletteWheel.isHalfWidth("a"))
        XCTAssertFalse(RouletteWheel.isHalfWidth("あ"))
    }

    // MARK: - 世界時計

    func testWorldClockOffsets() throws {
        func date(_ text: String) throws -> Date { try XCTUnwrap(ISO8601DateFormatter().date(from: text)) }
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let delhi = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let sydney = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let winter = try date("2026-01-15T03:00:00Z")
        let summer = try date("2026-07-15T03:00:00Z")
        // 夏時間で1時間変わる
        XCTAssertEqual(WorldClock.offsetFromJapan(newYork, at: winter), -14 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(newYork, at: summer), -13 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(london, at: winter), -9 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(london, at: summer), -8 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(delhi, at: winter), -(3 * 3600 + 1800))
        XCTAssertEqual(WorldClock.offsetFromJapan(sydney, at: winter), 2 * 3600)
        XCTAssertEqual(WorldClock.offsetFromJapan(WorldClock.japan, at: winter), 0)

        XCTAssertEqual(WorldClock.offsetText(-14 * 3600), "−14時間")
        XCTAssertEqual(WorldClock.offsetText(-(3 * 3600 + 1800)), "−3時間30分")
        XCTAssertEqual(WorldClock.offsetText(2 * 3600), "+2時間")
        XCTAssertEqual(WorldClock.offsetText(0), "日本と同じ")

        // UTC 3:00 = 日本の12:00。ニューヨークは前日の22:00
        XCTAssertEqual(WorldClock.timeText(WorldClock.japan, at: winter), "12:00")
        XCTAssertEqual(WorldClock.timeText(newYork, at: winter), "22:00")
        XCTAssertEqual(WorldClock.dayDifference(newYork, at: winter), -1)
        XCTAssertEqual(WorldClock.dayDifference(london, at: winter), 0)
        // UTC 14:00 = 日本の23:00。シドニーは翌日の1:00
        XCTAssertEqual(WorldClock.dayDifference(sydney, at: try date("2026-01-15T14:00:00Z")), 1)
        XCTAssertEqual(WorldClock.dayText(-1), "前日")

        // 都市の表のタイムゾーンは、すべて iOS が知っている。IDは重複しない
        XCTAssertTrue(WorldClock.cities.allSatisfy { TimeZone(identifier: $0.zone) != nil })
        XCTAssertEqual(Set(WorldClock.cities.map(\.id)).count, WorldClock.cities.count)
        XCTAssertEqual(WorldClock.cities.first?.id, "tokyo")
        XCTAssertEqual(WorldClock.decode("london,nowhere,sydney").map(\.name), ["ロンドン", "シドニー"])
        XCTAssertEqual(WorldClock.encode(WorldClock.decode("london,sydney")), "london,sydney")
    }

    func testMetronome() {
        XCTAssertEqual(MetronomeLogic.framesPerBeat(bpm: 120, sampleRate: 44100), 22050)
        XCTAssertEqual(MetronomeLogic.clamped(10), 30)
        XCTAssertEqual(MetronomeLogic.clamped(999), 240)
        XCTAssertEqual(MetronomeLogic.beatIndex(elapsed: 0.1, bpm: 120, beatsPerBar: 4), 0)
        XCTAssertEqual(MetronomeLogic.beatIndex(elapsed: 1.6, bpm: 120, beatsPerBar: 4), 3)
        XCTAssertEqual(MetronomeLogic.beatIndex(elapsed: 2.1, bpm: 120, beatsPerBar: 4), 0)
        XCTAssertNil(MetronomeLogic.tapTempo([1.0]))
        XCTAssertEqual(MetronomeLogic.tapTempo([0, 0.5, 1.0, 1.5]), 120)
        // 2秒以上空いたら、数え直す
        XCTAssertEqual(MetronomeLogic.tapTempo([0, 0.5, 10, 11, 12]), 60)

        let samples = MetronomeLogic.barSamples(bpm: 120, beatsPerBar: 4, accent: true, sampleRate: 44100)
        XCTAssertEqual(samples.count, 22050 * 4)
        // 各拍の先頭だけに音があり、拍の後半は無音
        XCTAssertTrue(samples[1..<200].contains { abs($0) > 0.1 })
        XCTAssertTrue(samples[22051..<22250].contains { abs($0) > 0.1 })
        XCTAssertTrue(samples[11000..<22050].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 1 })
    }
}

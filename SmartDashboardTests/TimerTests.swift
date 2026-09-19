import XCTest
@testable import SmartDashboard

final class TimerModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testCountdownSurvivesRelaunch() throws {
        var timer = CountdownTimer(label: "test", duration: 300)
        XCTAssertEqual(timer.state(now: t0), .idle)
        timer.start(now: t0)
        XCTAssertEqual(timer.endDate, t0.addingTimeInterval(300))

        // 保存して読み直しても、終了時刻から残り時間を計算できる
        let restored = try JSONDecoder().decode(CountdownTimer.self, from: JSONEncoder().encode(timer))
        XCTAssertEqual(restored.state(now: t0.addingTimeInterval(120)), .running)
        XCTAssertEqual(restored.remaining(now: t0.addingTimeInterval(120)), 180, accuracy: 0.001)
        XCTAssertEqual(restored.state(now: t0.addingTimeInterval(301)), .finished)
        XCTAssertEqual(restored.remaining(now: t0.addingTimeInterval(301)), 0)
    }

    func testPauseAndResume() {
        var timer = CountdownTimer(label: "test", duration: 60)
        timer.start(now: t0)
        timer.pause(now: t0.addingTimeInterval(20))
        XCTAssertEqual(timer.state(now: t0.addingTimeInterval(500)), .paused)
        XCTAssertEqual(timer.remaining(now: t0.addingTimeInterval(500)), 40, accuracy: 0.001)
        timer.start(now: t0.addingTimeInterval(500))
        XCTAssertEqual(timer.endDate, t0.addingTimeInterval(540))
        timer.reset()
        XCTAssertEqual(timer.state(now: t0), .idle)
        XCTAssertEqual(timer.remaining(now: t0), 60)
    }

    func testStopwatchLaps() {
        var sw = Stopwatch()
        sw.start(now: t0)
        sw.lap(now: t0.addingTimeInterval(10))
        sw.lap(now: t0.addingTimeInterval(25))
        sw.stop(now: t0.addingTimeInterval(30))
        XCTAssertEqual(sw.elapsed(now: t0.addingTimeInterval(999)), 30, accuracy: 0.001)
        sw.start(now: t0.addingTimeInterval(100))
        XCTAssertEqual(sw.elapsed(now: t0.addingTimeInterval(105)), 35, accuracy: 0.001)
        let laps = sw.laps
        XCTAssertEqual(laps.count, 2)
        XCTAssertEqual(laps[1].lap, 15, accuracy: 0.001)
        XCTAssertEqual(laps[1].total, 25, accuracy: 0.001)
    }

    func testTimeText() {
        XCTAssertEqual(TimeText.countdown(59.2), "01:00")
        XCTAssertEqual(TimeText.countdown(3909), "1:05:09")
        XCTAssertEqual(TimeText.stopwatch(309.279), "05:09.27")
        XCTAssertEqual(TimeText.duration(3660), "1時間1分")
        XCTAssertEqual(TimeText.duration(0), "0秒")
    }
}

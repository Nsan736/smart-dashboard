import XCTest
@testable import SmartDashboard

/// GPS → 位置の差分 → 歩行ペース → 停止中 の切り替えのテスト
final class SpeedPriorityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let metersPerLatitudeStep = 1.1119

    private func fix(at seconds: Double, metersNorth: Double, speed: Double = -1, speedAccuracy: Double = -1,
                     accuracy: Double = 5) -> SpeedSample {
        SpeedSample(latitude: 35.0 + metersNorth / metersPerLatitudeStep * 0.00001, longitude: 139.0,
                    speed: speed, speedAccuracy: speedAccuracy, horizontalAccuracy: accuracy,
                    timestamp: t0.addingTimeInterval(seconds))
    }

    private func time(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// 屋内: 精度±22mで、歩いても位置の差分は誤差に埋もれる
    private func indoorEstimator() -> SpeedEstimator {
        var estimator = SpeedEstimator()
        let offsets = [0.0, 1.2, 2.5, 3.9, 5.0, 6.4, 7.5]
        for (second, offset) in offsets.enumerated() {
            estimator.add(fix(at: Double(second), metersNorth: offset, accuracy: 22))
        }
        return estimator
    }

    func testIndoorWithoutStepsIsStationaryNotJustZero() {
        let estimator = indoorEstimator()
        let reading = estimator.reading(now: time(6))
        XCTAssertEqual(reading, SpeedReading(speed: 0, source: .stationary))
        XCTAssertEqual(SpeedStatusText.method(reading.source, horizontalAccuracy: 22),
                       "停止中(精度±22mのため、ゆっくりした移動は検出できません)")
    }

    func testIndoorWalkingUsesPedometerPace() {
        var estimator = indoorEstimator()
        // 0.8秒/m = 1.25 m/s (4.5 km/h)
        estimator.addPedometer(steps: 1000, distance: 700, secondsPerMeter: nil, at: time(3))
        estimator.addPedometer(steps: 1006, distance: 704, secondsPerMeter: 0.8, at: time(6))
        let reading = estimator.reading(now: time(7))
        XCTAssertEqual(reading.source, .pedometer)
        XCTAssertEqual(reading.speed ?? -1, 1.25, accuracy: 0.001)
        XCTAssertTrue(SpeedStatusText.method(reading.source, horizontalAccuracy: 22).contains("歩行ペースから推定"))

        // 立ち止まって歩数の更新が止まると、停止中に戻る(GPSの測位は続いている)
        for second in 7...20 {
            estimator.add(fix(at: Double(second), metersNorth: 7.5, accuracy: 22))
        }
        XCTAssertEqual(estimator.reading(now: time(20)).source, .stationary)
    }

    func testReportedGPSSpeedWinsOverPedometer() {
        var estimator = SpeedEstimator()
        for second in 0...5 {
            estimator.add(fix(at: Double(second), metersNorth: Double(second) * 1.5, speed: 1.5, speedAccuracy: 0.4))
        }
        estimator.addPedometer(steps: 10, distance: 7, secondsPerMeter: nil, at: time(2))
        estimator.addPedometer(steps: 16, distance: 11, secondsPerMeter: 0.5, at: time(5))
        let reading = estimator.reading(now: time(5))
        XCTAssertEqual(reading.source, .reported)
        XCTAssertEqual(reading.speed ?? -1, 1.5, accuracy: 0.001)
    }

    func testDerivedSpeedWinsOverPedometerWhenMovementIsClear() {
        var estimator = SpeedEstimator()
        for second in 0...6 {
            estimator.add(fix(at: Double(second), metersNorth: Double(second) * 5))
        }
        estimator.addPedometer(steps: 10, distance: 7, secondsPerMeter: nil, at: time(3))
        estimator.addPedometer(steps: 20, distance: 20, secondsPerMeter: 0.4, at: time(6))
        let reading = estimator.reading(now: time(6))
        XCTAssertEqual(reading.source, .derived)
        XCTAssertEqual(reading.speed ?? -1, 5, accuracy: 0.1)
    }

    func testVehicleUsesGPSBecauseStepsDoNotIncrease() {
        var estimator = SpeedEstimator()
        for second in 0...5 {
            estimator.add(fix(at: Double(second), metersNorth: Double(second) * 20, speed: 20, speedAccuracy: 0.5))
        }
        // 座っているので歩数は増えず、ペースも出ない
        estimator.addPedometer(steps: 500, distance: 300, secondsPerMeter: nil, at: time(1))
        estimator.addPedometer(steps: 500, distance: 300, secondsPerMeter: nil, at: time(4))
        XCTAssertEqual(estimator.reading(now: time(5)), SpeedReading(speed: 20, source: .reported))
    }

    func testPedometerAloneWorksWithoutAnyGPSFix() {
        var estimator = SpeedEstimator()
        XCTAssertEqual(estimator.reading(now: time(0)), SpeedReading(speed: nil, source: nil))
        estimator.addPedometer(steps: 100, distance: 50, secondsPerMeter: 0.75, at: time(0))
        estimator.addPedometer(steps: 105, distance: 54, secondsPerMeter: 0.75, at: time(3))
        let reading = estimator.reading(now: time(4))
        XCTAssertEqual(reading.source, .pedometer)
        XCTAssertEqual(reading.speed ?? -1, 1 / 0.75, accuracy: 0.001)
        // 最高・平均・距離にも使う。距離は歩数計の増分(4m)。
        XCTAssertEqual(estimator.distance, 4, accuracy: 0.001)
        XCTAssertEqual(estimator.movingTime, 3, accuracy: 0.001)
        XCTAssertEqual(estimator.maxSpeed, 1 / 0.75, accuracy: 0.001)

        // 歩数の更新が途絶えて10秒を過ぎたら使わない
        XCTAssertEqual(estimator.reading(now: time(14)), SpeedReading(speed: nil, source: nil))
    }

    func testStepsNotIncreasingClearsPace() {
        var estimator = SpeedEstimator()
        estimator.addPedometer(steps: 100, distance: 50, secondsPerMeter: 0.75, at: time(0))
        XCTAssertEqual(estimator.reading(now: time(1)).source, .pedometer)
        estimator.addPedometer(steps: 100, distance: 50, secondsPerMeter: 0.75, at: time(3))
        XCTAssertNil(estimator.reading(now: time(3)).speed)
    }

    func testDistanceIsNotCountedTwiceWhenGPSIsMoving() {
        var estimator = SpeedEstimator()
        // 屋外を 1.5 m/s で歩く。GPSも歩数計も動きを捉えている。
        for second in 0...10 {
            estimator.add(fix(at: Double(second), metersNorth: Double(second) * 1.5, speed: 1.5, speedAccuracy: 0.4))
            if second % 3 == 0 {
                estimator.addPedometer(steps: 100 + second * 2, distance: 50 + Double(second) * 1.5, secondsPerMeter: 0.667, at: time(Double(second)))
            }
        }
        // GPSの分(15m)だけ。歩数計の分を足すと約30mになってしまう。
        XCTAssertEqual(estimator.distance, 15, accuracy: 0.5)
        XCTAssertEqual(estimator.movingTime, 10, accuracy: 0.001)
    }

    func testNearZeroReportedSpeedYieldsToPedometer() {
        var estimator = SpeedEstimator()
        // 屋内で速度精度だけ良く、報告値がほぼ0のとき
        for second in 0...5 {
            estimator.add(fix(at: Double(second), metersNorth: 0, speed: 0.1, speedAccuracy: 0.5))
        }
        XCTAssertEqual(estimator.reading(now: time(5)).source, .reported)
        estimator.addPedometer(steps: 10, distance: 5, secondsPerMeter: nil, at: time(2))
        estimator.addPedometer(steps: 16, distance: 9, secondsPerMeter: 0.8, at: time(5))
        XCTAssertEqual(estimator.reading(now: time(5)).source, .pedometer)
    }

    func testStatusTexts() {
        XCTAssertEqual(SpeedStatusText.method(.reported, horizontalAccuracy: 5), "GPSの速度")
        XCTAssertEqual(SpeedStatusText.method(.derived, horizontalAccuracy: 5), "位置の差分から計算")
        XCTAssertEqual(SpeedStatusText.gps(lastUpdate: t0, horizontalAccuracy: 22, now: time(2)), "GPS: 水平精度 ±22m・最後の測位から2秒")
        XCTAssertEqual(SpeedStatusText.gps(lastUpdate: nil, horizontalAccuracy: nil, now: t0), "GPS: まだ測位できていません")
        XCTAssertTrue(SpeedStatusText.gps(lastUpdate: t0, horizontalAccuracy: 120, now: t0).contains("除外中"))
    }
}

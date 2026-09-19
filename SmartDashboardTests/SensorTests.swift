import XCTest
@testable import SmartDashboard

final class SpeedEstimatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// 緯度0.00001度は約1.11m
    private let metersPerLatitudeStep = 1.1119

    /// 北へ一定の速さで進む測位を作る
    private func sample(at seconds: Double, metersNorth: Double, speed: Double = -1, speedAccuracy: Double = -1,
                        accuracy: Double = 5) -> SpeedSample {
        SpeedSample(latitude: 35.0 + metersNorth / metersPerLatitudeStep * 0.00001, longitude: 139.0,
                    speed: speed, speedAccuracy: speedAccuracy, horizontalAccuracy: accuracy,
                    timestamp: t0.addingTimeInterval(seconds))
    }

    func testUsesReportedSpeedWhenAccurate() {
        var estimator = SpeedEstimator()
        estimator.add(sample(at: 0, metersNorth: 0, speed: 10, speedAccuracy: 0.5))
        XCTAssertEqual(estimator.currentSpeed ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(estimator.source, .reported)
    }

    func testInvalidSpeedIsNotShownAsZero() {
        var estimator = SpeedEstimator()
        // 最初の1点だけでは、速度が無効なら何も求められない(0ではなく「測位中」)
        estimator.add(sample(at: 0, metersNorth: 0))
        XCTAssertNil(estimator.currentSpeed)
        XCTAssertNil(estimator.source)
        // 速度の精度が悪いときも、GPSの速度は使わない
        estimator.add(sample(at: 1, metersNorth: 5, speed: 30, speedAccuracy: 10))
        XCTAssertNil(estimator.currentSpeed)
    }

    func testDerivesSpeedFromPositionsWhenSpeedIsInvalid() {
        var estimator = SpeedEstimator()
        // 5 m/s で北へ。speed は無効(-1)
        for second in 0...6 {
            estimator.add(sample(at: Double(second), metersNorth: Double(second) * 5))
        }
        XCTAssertEqual(estimator.source, .derived)
        XCTAssertEqual(estimator.currentSpeed ?? -1, 5, accuracy: 0.1)
    }

    func testStationaryJitterIsTreatedAsStopped() {
        var estimator = SpeedEstimator()
        // 止まっているが、測位が誤差(±5m)の範囲で2mほど揺らぐ
        let offsets = [0.0, 1.5, -1.0, 2.0, 0.5, -1.5, 1.0]
        for (second, offset) in offsets.enumerated() {
            estimator.add(sample(at: Double(second), metersNorth: offset))
        }
        XCTAssertEqual(estimator.currentSpeed, 0)
        XCTAssertEqual(estimator.distance, 0)
        XCTAssertEqual(estimator.maxSpeed, 0)
    }

    func testSmoothingAveragesRecentValues() {
        var estimator = SpeedEstimator()
        for (second, speed) in [10.0, 10.0, 16.0].enumerated() {
            estimator.add(sample(at: Double(second), metersNorth: Double(second) * 10, speed: speed, speedAccuracy: 0.5))
        }
        XCTAssertEqual(estimator.currentSpeed ?? -1, 12, accuracy: 0.001)
        // 1点だけの外れ値では、最高速度が跳ね上がらない
        XCTAssertEqual(estimator.maxSpeed, 12, accuracy: 0.001)
    }

    func testBadAccuracyFixesAreExcluded() {
        var estimator = SpeedEstimator()
        estimator.add(sample(at: 0, metersNorth: 0, speed: 10, speedAccuracy: 0.5))
        estimator.add(sample(at: 1, metersNorth: 10, speed: 10, speedAccuracy: 0.5))
        let before = estimator
        // 精度の悪い点(±500m、位置も速度もでたらめ)は無視する
        estimator.add(sample(at: 2, metersNorth: 900, speed: 99, speedAccuracy: 0.5, accuracy: 500))
        estimator.add(sample(at: 3, metersNorth: -400, speed: 80, speedAccuracy: 0.5, accuracy: -1))
        XCTAssertEqual(estimator, before)
        XCTAssertEqual(estimator.maxSpeed, 10, accuracy: 0.001)
        XCTAssertEqual(estimator.distance, 10, accuracy: 0.2)
    }

    func testStatisticsAndReset() {
        var estimator = SpeedEstimator()
        for second in 0...10 {
            estimator.add(sample(at: Double(second), metersNorth: Double(second) * 10, speed: 10, speedAccuracy: 0.5))
        }
        XCTAssertEqual(estimator.distance, 100, accuracy: 1)
        XCTAssertEqual(estimator.movingTime, 10, accuracy: 0.001)
        XCTAssertEqual(estimator.averageSpeed, 10, accuracy: 0.1)
        XCTAssertEqual(estimator.maxSpeed, 10, accuracy: 0.001)

        estimator.resetStatistics()
        XCTAssertEqual(estimator.distance, 0)
        XCTAssertEqual(estimator.maxSpeed, 0)
        XCTAssertEqual(estimator.averageSpeed, 0)
        // 現在の速度はリセットしない
        XCTAssertEqual(estimator.currentSpeed ?? -1, 10, accuracy: 0.001)
    }

    func testGapsAreNotCountedAsDistance() {
        var estimator = SpeedEstimator()
        estimator.add(sample(at: 0, metersNorth: 0, speed: 10, speedAccuracy: 0.5))
        // トンネルなどで60秒途切れたあと、600m先で再開。途切れた区間は距離に入れない。
        estimator.add(sample(at: 60, metersNorth: 600, speed: 10, speedAccuracy: 0.5))
        XCTAssertEqual(estimator.distance, 0)
        estimator.add(sample(at: 61, metersNorth: 610, speed: 10, speedAccuracy: 0.5))
        XCTAssertEqual(estimator.distance, 10, accuracy: 0.2)
    }

    func testSpeedExpiresWhenFixesStop() {
        var estimator = SpeedEstimator()
        estimator.add(sample(at: 0, metersNorth: 0, speed: 10, speedAccuracy: 0.5))
        XCTAssertNotNil(estimator.currentSpeed)
        // 精度の悪い測位しか来なくなった
        estimator.add(sample(at: 10, metersNorth: 100, accuracy: 300))
        XCTAssertNil(estimator.currentSpeed)
    }

    func testDistanceBetweenSamples() {
        let a = sample(at: 0, metersNorth: 0)
        let b = sample(at: 1, metersNorth: 100)
        XCTAssertEqual(SpeedEstimator.distance(a, b), 100, accuracy: 0.5)
    }
}

final class SensorLogicTests: XCTestCase {
    func testTilt() {
        let flat = MotionSensors.tilt(gravityX: 0, gravityY: 0, gravityZ: -1)
        XCTAssertEqual(flat.pitch, 0, accuracy: 0.001)
        XCTAssertEqual(flat.roll, 0, accuracy: 0.001)
        let upright = MotionSensors.tilt(gravityX: 0, gravityY: -1, gravityZ: 0)
        XCTAssertEqual(upright.pitch, 90, accuracy: 0.001)
    }

    @MainActor
    func testCompassLabel() {
        XCTAssertEqual(LocationSensors.compassLabel(0), "北")
        XCTAssertEqual(LocationSensors.compassLabel(359), "北")
        XCTAssertEqual(LocationSensors.compassLabel(90), "東")
        XCTAssertEqual(LocationSensors.compassLabel(225), "南西")
    }

    func testDecibelEstimateIsClamped() {
        XCTAssertEqual(NoiseMeter.estimateDecibels(fromPower: -160), 0)
        XCTAssertEqual(NoiseMeter.estimateDecibels(fromPower: -40), 60)
        XCTAssertEqual(NoiseMeter.estimateDecibels(fromPower: 30), 120)
    }

    func testPedometerTexts() {
        // 0.5秒/m = 8分20秒/km
        XCTAssertEqual(PedometerSnapshot.paceText(secondsPerMeter: 0.5), "8分20秒/km")
        XCTAssertNil(PedometerSnapshot.paceText(secondsPerMeter: nil))
        XCTAssertNil(PedometerSnapshot.paceText(secondsPerMeter: 0))
        XCTAssertEqual(PedometerSnapshot.cadenceText(stepsPerSecond: 1.87), "112歩/分")
        XCTAssertNil(PedometerSnapshot.cadenceText(stepsPerSecond: nil))
    }
}

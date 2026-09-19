import CoreLocation
import XCTest
@testable import SmartDashboard

final class SensorLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testTripRecorder() {
        var trip = TripRecorder()
        let a = CLLocationCoordinate2D(latitude: 35.0, longitude: 139.0)
        let b = CLLocationCoordinate2D(latitude: 35.001, longitude: 139.0)

        // 記録前は無視する
        trip.add(coordinate: a, speed: 10, horizontalAccuracy: 5, time: t0)
        XCTAssertEqual(trip.maxSpeed, 0)

        trip.start()
        trip.add(coordinate: a, speed: 10, horizontalAccuracy: 5, time: t0)
        trip.add(coordinate: b, speed: 12, horizontalAccuracy: 5, time: t0.addingTimeInterval(10))
        // 精度の悪い測位は無視する
        trip.add(coordinate: a, speed: 99, horizontalAccuracy: 500, time: t0.addingTimeInterval(11))
        XCTAssertEqual(trip.maxSpeed, 12)
        XCTAssertEqual(trip.distance, 111, accuracy: 1.5)
        XCTAssertEqual(trip.movingTime, 10, accuracy: 0.001)
        XCTAssertEqual(trip.averageSpeed, 11.1, accuracy: 0.2)

        trip.reset()
        XCTAssertTrue(trip.isRecording)
        XCTAssertEqual(trip.distance, 0)
    }

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
}

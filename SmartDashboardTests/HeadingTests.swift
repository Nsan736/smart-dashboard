import XCTest
@testable import SmartDashboard

/// カメラの向きから出す方角(端末を立てた・寝かせた・その間で連続して正しいか)と、方角の診断
final class HeadingTests: XCTestCase {
    private let size = CGSize(width: 375, height: 667)
    private let tangents = (horizontal: 0.6, vertical: 1.0)

    /// 背面カメラの方角 azimuth・仰角 elevation・左右の傾き roll(右が下がると正)の姿勢。
    /// CMRotationMatrix と同じ形(行が端末の軸、3行目は画面の手前 = 背面の逆)の値から作る
    private func attitude(azimuth: Double, elevation: Double, roll: Double = 0) -> CameraAttitude {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180, r = roll * .pi / 180
        let forward = Vector3(x: cos(e) * cos(a), y: -cos(e) * sin(a), z: sin(e))
        let right0 = Vector3(x: cos(a + .pi / 2), y: -sin(a + .pi / 2), z: 0)
        let up0 = Vector3.cross(right0, forward)
        let right = Vector3(x: right0.x * cos(r) - up0.x * sin(r), y: right0.y * cos(r) - up0.y * sin(r), z: right0.z * cos(r) - up0.z * sin(r))
        let up = Vector3(x: up0.x * cos(r) + right0.x * sin(r), y: up0.y * cos(r) + right0.y * sin(r), z: up0.z * cos(r) + right0.z * sin(r))
        return CameraAttitude(m11: right.x, m12: right.y, m13: right.z, m21: up.x, m22: up.y, m23: up.z,
                              m31: -forward.x, m32: -forward.y, m33: -forward.z)
    }

    private func assertAngle(_ a: Double, _ b: Double, accuracy: Double = 1e-6, _ message: String = "", line: UInt = #line) {
        XCTAssertEqual(HeadingDiagnostics.difference(a, b), 0, accuracy: accuracy, message, line: line)
    }

    func testAzimuthIsContinuousFromUprightToFlat() {
        // 仰角を −85°〜85° まで1°ずつ変えても(立てた → 寝かせた)、傾けても、方角はカメラの向きのまま(跳ばない)
        for azimuth in stride(from: 0.0, to: 360, by: 15) {
            for roll in [-40.0, 0, 25] {
                var previous: Double?
                for elevation in stride(from: -85.0, through: 85, by: 1) {
                    let value = attitude(azimuth: azimuth, elevation: elevation, roll: roll)
                    assertAngle(value.azimuth, azimuth, accuracy: 1e-6, "方角 \(azimuth) 仰角 \(elevation) 傾き \(roll)")
                    XCTAssertEqual(value.elevation, elevation, accuracy: 1e-6)
                    XCTAssertEqual(value.roll, roll, accuracy: 1e-6)
                    if let previous { assertAngle(value.azimuth, previous, accuracy: 1e-6) }
                    previous = value.azimuth
                }
            }
        }
    }

    func testTargetInCameraDirectionIsAtCenterInAnyPosture() {
        for azimuth in [0.0, 47, 133, 270] {
            for elevation in [-60.0, -10, 0, 20, 70] {
                for roll in [-30.0, 0, 30] {
                    let value = attitude(azimuth: azimuth, elevation: elevation, roll: roll)
                    let point = WaypointProjection.point(bearing: azimuth, elevation: elevation, attitude: value, tangents: tangents, viewSize: size)
                    XCTAssertEqual(point?.x ?? -1, size.width / 2, accuracy: 1e-6)
                    XCTAssertEqual(point?.y ?? -1, size.height / 2, accuracy: 1e-6)
                }
            }
        }
        // 右に10°の方向は、傾けていなければ画面の中央より右
        let north = attitude(azimuth: 0, elevation: 0)
        let right = WaypointProjection.point(bearing: 10, attitude: north, tangents: tangents, viewSize: size)
        XCTAssertGreaterThan(right?.x ?? 0, size.width / 2)
    }

    func testRowsOfRotationMatrixMatchGravity() {
        // 縦に持って北を向けたとき、iPhone の重力は端末の座標系で (0, −1, 0)。平らに置いたときは (0, 0, −1)。
        // 行列の行を端末の軸として読む読み方なら、行列から求めた鉛直と重力が一致する
        var diagnostics = HeadingDiagnostics()
        diagnostics.update(MotionSample(attitude: attitude(azimuth: 0, elevation: 0), rotationRate: Vector3(x: 0, y: 0, z: 0),
                                        gravity: Vector3(x: 0, y: -1, z: 0), timestamp: 0))
        XCTAssertEqual(diagnostics.gravityMismatch ?? 99, 0, accuracy: 1e-6)
        XCTAssertEqual(diagnostics.posture, .portrait)
        diagnostics.update(MotionSample(attitude: attitude(azimuth: 0, elevation: -90), rotationRate: Vector3(x: 0, y: 0, z: 0),
                                        gravity: Vector3(x: 0, y: 0, z: -1), timestamp: 1))
        XCTAssertEqual(diagnostics.gravityMismatch ?? 99, 0, accuracy: 1e-4)
        XCTAssertEqual(diagnostics.posture, .flat)
        // 列として読んだら(転置)、方角が合わない(方角30°・仰角20°・傾き10°のとき、80°になる)
        let tilted = attitude(azimuth: 30, elevation: 20, roll: 10)
        let transposed = CameraAttitude(m11: tilted.right.x, m12: tilted.up.x, m13: -tilted.forward.x,
                                        m21: tilted.right.y, m22: tilted.up.y, m23: -tilted.forward.y,
                                        m31: tilted.right.z, m32: tilted.up.z, m33: -tilted.forward.z)
        XCTAssertNotEqual(transposed.azimuth, 30, accuracy: 1)
        XCTAssertEqual(DevicePosture.make(gravity: Vector3(x: -0.9, y: -0.1, z: 0)), .landscapeLeft)
        XCTAssertEqual(DevicePosture.make(gravity: Vector3(x: 0.9, y: 0.1, z: 0.2)), .landscapeRight)
        XCTAssertEqual(DevicePosture.make(gravity: Vector3(x: 0, y: 0.9, z: 0.2)), .upsideDown)
    }

    func testRotateAndYawStep() {
        let base = attitude(azimuth: 30, elevation: 20, roll: 10)
        let turned = base.rotatedClockwise(by: 7)
        // 回すと方角だけが変わる
        assertAngle(turned.azimuth, 37)
        XCTAssertEqual(turned.elevation, base.elevation, accuracy: 1e-9)
        XCTAssertEqual(turned.roll, base.roll, accuracy: 1e-9)
        XCTAssertEqual(HeadingDiagnostics.yawStep(from: base, to: turned), 7, accuracy: 1e-9)
        XCTAssertEqual(HeadingDiagnostics.yawStep(from: turned, to: base), -7, accuracy: 1e-9)
        // 上下に向けるだけなら、鉛直まわりの回転は0
        XCTAssertEqual(HeadingDiagnostics.yawStep(from: attitude(azimuth: 30, elevation: 0), to: attitude(azimuth: 30, elevation: 12)), 0, accuracy: 1e-9)
    }

    func testSmoothingStaysOrthonormalAndSnapsOnLargeChange() {
        let north = attitude(azimuth: 0, elevation: 5, roll: 3)
        let thirty = attitude(azimuth: 30, elevation: 5, roll: 3)
        let halfway = north.smoothed(toward: thirty, weight: 0.5)
        assertAngle(halfway.azimuth, 15, accuracy: 0.01)
        XCTAssertEqual(halfway.forward.length, 1, accuracy: 1e-9)
        XCTAssertEqual(halfway.right.length, 1, accuracy: 1e-9)
        XCTAssertEqual(Vector3.dot(halfway.right, halfway.forward), 0, accuracy: 1e-9)
        XCTAssertEqual(Vector3.dot(halfway.up, halfway.forward), 0, accuracy: 1e-9)
        XCTAssertEqual(Vector3.dot(halfway.up, halfway.right), 0, accuracy: 1e-9)
        // 何度混ぜても、向きはゆがまない(最後は新しい値に収束する)
        var current = north
        for _ in 0..<200 { current = current.smoothed(toward: thirty, weight: 0.25) }
        assertAngle(current.azimuth, 30, accuracy: 1e-6)
        XCTAssertEqual(current.roll, 3, accuracy: 1e-6)
        // 1回で45°より大きく変わったら(再開の直後など)、混ぜずに新しい値
        let east = attitude(azimuth: 90, elevation: 5, roll: 3)
        XCTAssertEqual(north.smoothed(toward: east, weight: 0.25), east)
    }

    /// 1秒に30回、時計回りに degreesPerSecond で回る。CoreMotion の方角には、1回ごとに extra(度)を足す
    private func turning(_ diagnostics: inout HeadingDiagnostics, from start: Double, degreesPerSecond: Double, seconds: Double,
                         extra: Double = 0, elevation: Double = 10, startTime: TimeInterval = 0) -> Double {
        let steps = Int(seconds * 30)
        var azimuth = start
        var shown = start
        for step in 0...steps {
            let value = attitude(azimuth: shown, elevation: elevation, roll: 5)
            // 上から見て時計回り = 鉛直まわりに負の向き。角速度は端末の座標系で、鉛直の成分だけ
            let rate = HeadingDiagnostics.verticalInDevice(value).scaled(-degreesPerSecond * .pi / 180)
            diagnostics.update(MotionSample(attitude: value, rotationRate: rate, gravity: HeadingDiagnostics.verticalInDevice(value).scaled(-1),
                                            timestamp: startTime + Double(step) / 30))
            azimuth += degreesPerSecond / 30
            shown = azimuth + extra * Double(step + 1)
        }
        return shown
    }

    func testDiagnosticsMatchGyroWhenTurning() {
        var diagnostics = HeadingDiagnostics()
        _ = turning(&diagnostics, from: 350, degreesPerSecond: 40, seconds: 3)
        // 実際に回った分は、ジャイロで説明できる
        XCTAssertEqual(diagnostics.correction, 0, accuracy: 0.01)
        XCTAssertEqual(diagnostics.jumpCount, 0)
    }

    func testDiagnosticsFindCorrectionWithoutRotation() {
        // 端末は止まっているのに、CoreMotion の方角だけが少しずつ回る(磁気の乱れなど): 3秒で約90°
        var diagnostics = HeadingDiagnostics()
        let shown = turning(&diagnostics, from: 0, degreesPerSecond: 0, seconds: 3, extra: 1)
        XCTAssertEqual(diagnostics.correction, 90, accuracy: 0.01)
        XCTAssertEqual(diagnostics.jumpCount, 0)
        // ジャイロで保つときは、その分を打ち消すと、もとの方角に戻る
        let held = attitude(azimuth: shown - 1, elevation: 10, roll: 5).rotatedClockwise(by: -diagnostics.correction)
        assertAngle(held.azimuth, 0, accuracy: 1)
        // 一度に大きく変わったら「跳び」
        var jump = HeadingDiagnostics()
        jump.update(MotionSample(attitude: attitude(azimuth: 10, elevation: 0), rotationRate: Vector3(x: 0, y: 0, z: 0),
                                 gravity: Vector3(x: 0, y: -1, z: 0), timestamp: 0))
        jump.update(MotionSample(attitude: attitude(azimuth: 30, elevation: 0), rotationRate: Vector3(x: 0, y: 0, z: 0),
                                 gravity: Vector3(x: 0, y: -1, z: 0), timestamp: 1.0 / 30))
        XCTAssertEqual(jump.jumpCount, 1)
        XCTAssertEqual(jump.lastJump ?? 0, 20, accuracy: 1e-6)
    }

    func testRestartDoesNotChangeHeading() {
        // 止めて再開した(間が空いた)ときは比べないので、基準を取り直して方角が変わっても、累計は増えない
        var diagnostics = HeadingDiagnostics()
        _ = turning(&diagnostics, from: 0, degreesPerSecond: 20, seconds: 1)
        let before = diagnostics.correction
        _ = turning(&diagnostics, from: 140, degreesPerSecond: 20, seconds: 1, startTime: 5)
        XCTAssertEqual(diagnostics.correction, before, accuracy: 0.01)
        // 合わせ直すと0
        diagnostics.reset()
        XCTAssertEqual(diagnostics.correction, 0)
        XCTAssertEqual(diagnostics.jumpCount, 0)
        // 同じ姿勢を受け取り直しても、方角は同じ
        let value = attitude(azimuth: 123, elevation: 15, roll: -8)
        let reread = CameraAttitude(m11: value.right.x, m12: value.right.y, m13: value.right.z, m21: value.up.x, m22: value.up.y, m23: value.up.z,
                                    m31: -value.forward.x, m32: -value.forward.y, m33: -value.forward.z)
        assertAngle(reread.azimuth, 123)
    }

    func testCompassReferenceAxis() {
        // カメラが水平に近いときは背面の向き
        let upright = attitude(azimuth: 80, elevation: 10)
        XCTAssertEqual(HeadingDiagnostics.compassReference(upright)?.axis, "背面(カメラ)")
        assertAngle(HeadingDiagnostics.compassReference(upright)?.azimuth ?? 0, 80)
        // 平らに置いたとき(カメラが真下)は、端末の上端の向き。上端はカメラの方角の向き
        let flat = attitude(azimuth: 80, elevation: -85)
        XCTAssertEqual(HeadingDiagnostics.compassReference(flat)?.axis, "上端")
        assertAngle(HeadingDiagnostics.compassReference(flat)?.azimuth ?? 0, 80, accuracy: 1e-6)
        // 45°前後では比べない
        XCTAssertNil(HeadingDiagnostics.compassReference(attitude(azimuth: 80, elevation: -45)))
        XCTAssertEqual(HeadingDiagnostics.difference(10, 350), 20, accuracy: 1e-9)
        XCTAssertEqual(HeadingDiagnostics.difference(350, 10), -20, accuracy: 1e-9)
    }
}

import Foundation

/// CoreMotion の1回の更新(方角の診断に使う値だけ)。どれも平滑化する前の値。
struct MotionSample: Equatable {
    /// 姿勢(基準の座標系での、画面の右・画面の上・背面カメラの向き)
    var attitude: CameraAttitude
    /// 角速度(端末の座標系、rad/s。CMDeviceMotion.rotationRate)
    var rotationRate: Vector3
    /// 重力(端末の座標系、g。CMDeviceMotion.gravity)
    var gravity: Vector3
    /// 時刻(秒。CMDeviceMotion.timestamp)
    var timestamp: TimeInterval
}

/// 端末の持ち方(重力の向きから決める。画面の向きの判定とは別)
enum DevicePosture: String, Equatable {
    case portrait = "縦"
    case upsideDown = "逆さ"
    case landscapeLeft = "横(左が下)"
    case landscapeRight = "横(右が下)"
    case flat = "平ら"

    static func make(gravity g: Vector3) -> DevicePosture {
        if abs(g.z) > 0.8 { return .flat }
        if abs(g.y) >= abs(g.x) { return g.y < 0 ? .portrait : .upsideDown }
        return g.x < 0 ? .landscapeLeft : .landscapeRight
    }
}

/// 方角のデバッグ。CoreMotion の姿勢が、ジャイロ(角速度)で説明できない回り方をした量(磁気による補正や、基準の取り直し)を数える。
/// - 鉛直まわりの回転は、前の姿勢から今の姿勢への回転(基準の座標系)と、角速度の鉛直の成分(台形で積分)で比べる
/// - 差の累計(`correction`)が大きくなっていれば、映像は回っていないのに方角だけが回っている(磁気の乱れなど)
/// - 1回の更新で5°より大きい差は「跳び」として数える
/// - 0.5秒より間が空いたら(止めて再開したときなど)、比べずに次から数える
struct HeadingDiagnostics: Equatable {
    static let jumpThreshold = 5.0
    static let gapLimit = 0.5
    /// コンパスとの差がこれ以上なら目立たせる(度)
    static let warningDifference = 30.0

    /// ジャイロで説明できない鉛直まわりの回転の累計(度、上から見て時計回りが正。表示の方角が、この分だけ大きくずれている)
    private(set) var correction = 0.0
    /// 跳びの回数と、最後の跳び(度)
    private(set) var jumpCount = 0
    private(set) var lastJump: Double?
    /// 行列から求めた鉛直と、重力の向きの差(度)。行列の読み方が正しければ、ほぼ0
    private(set) var gravityMismatch: Double?
    private(set) var posture: DevicePosture?
    private var previous: MotionSample?

    mutating func reset() {
        correction = 0
        jumpCount = 0
        lastJump = nil
        previous = nil
    }

    mutating func update(_ sample: MotionSample) {
        gravityMismatch = Self.gravityMismatch(sample)
        posture = DevicePosture.make(gravity: sample.gravity)
        defer { previous = sample }
        guard let previous else { return }
        let dt = sample.timestamp - previous.timestamp
        guard dt > 0, dt <= Self.gapLimit else { return }
        let unexplained = Self.yawStep(from: previous.attitude, to: sample.attitude) - Self.gyroYawStep(previous, sample, dt: dt)
        correction = remainder(correction + unexplained, 360)
        if abs(unexplained) > Self.jumpThreshold {
            jumpCount += 1
            lastJump = unexplained
        }
    }

    /// 2つの姿勢の間の、鉛直まわりの回転(度、上から見て時計回りが正)。
    /// 基準の座標系での回転 R = Σ e_k(b)・e_k(a)ᵀ(e_k は端末の軸)。(R21 − R12) / 2 = sinθ・n_z(反時計回りが正)
    static func yawStep(from a: CameraAttitude, to b: CameraAttitude) -> Double {
        func term(_ p: Vector3, _ q: Vector3) -> Double { q.y * p.x - q.x * p.y }
        // 背面の向きは端末の z 軸の逆。符号は両方に付くので、そのまま使える
        let s = term(a.right, b.right) + term(a.up, b.up) + term(a.forward, b.forward)
        return -asin(max(-1, min(1, s / 2))) * 180 / .pi
    }

    /// 基準の座標系の鉛直(上)を、端末の座標系で表したもの(行列の3列目)
    static func verticalInDevice(_ attitude: CameraAttitude) -> Vector3 {
        Vector3(x: attitude.right.z, y: attitude.up.z, z: -attitude.forward.z)
    }

    /// 角速度から求めた、鉛直まわりの回転(度、上から見て時計回りが正。台形で積分)
    static func gyroYawStep(_ a: MotionSample, _ b: MotionSample, dt: TimeInterval) -> Double {
        let rateA = Vector3.dot(a.rotationRate, verticalInDevice(a.attitude))
        let rateB = Vector3.dot(b.rotationRate, verticalInDevice(b.attitude))
        return -(rateA + rateB) / 2 * dt * 180 / .pi
    }

    static func gravityMismatch(_ sample: MotionSample) -> Double? {
        let g = sample.gravity
        guard g.length > 0.1 else { return nil }
        // 重力は鉛直の逆向き
        let up = verticalInDevice(sample.attitude)
        let cosine = -Vector3.dot(g.unit, up.unit)
        return acos(max(-1, min(1, cosine))) * 180 / .pi
    }

    /// コンパス(CLHeading)と比べる方角と軸。カメラが水平に近いときは背面の向き、平らに近いときは端末の上端の向き。
    /// 間の姿勢(どちらも45°前後)では比べない
    static func compassReference(_ attitude: CameraAttitude) -> (azimuth: Double, axis: String)? {
        if abs(attitude.forward.z) < 0.7 { return (attitude.azimuth, "背面(カメラ)") }
        if abs(attitude.up.z) < 0.7 {
            return (WaypointMath.normalized(atan2(-attitude.up.y, attitude.up.x) * 180 / .pi), "上端")
        }
        return nil
    }

    /// 方角の差(−180〜180)
    static func difference(_ a: Double, _ b: Double) -> Double {
        remainder(a - b, 360)
    }
}

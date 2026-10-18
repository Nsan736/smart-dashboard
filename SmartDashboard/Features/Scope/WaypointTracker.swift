import AVFoundation
import CoreImage
import CoreLocation
import CoreMotion
import Foundation
import Observation
import SwiftUI
import UIKit

/// 方位の精度の目安
enum HeadingQuality: Equatable {
    case unknown
    case good(Double)
    case poor(Double)
    case invalid

    /// この値(度)より悪ければ、較正を案内する
    static let poorThreshold = 20.0

    static func make(accuracy: Double?) -> HeadingQuality {
        guard let accuracy else { return .unknown }
        if accuracy < 0 { return .invalid }
        return accuracy > poorThreshold ? .poor(accuracy) : .good(accuracy)
    }

    var text: String {
        switch self {
        case .unknown: return "方位の精度: 取得中"
        case .good(let value), .poor(let value): return "方位の精度: ±\(Int(value.rounded()))°"
        case .invalid: return "方位の精度: 不明(較正が必要)"
        }
    }

    var needsCalibration: Bool {
        switch self {
        case .poor, .invalid: return true
        default: return false
        }
    }

    static let calibrationHint = "iPhoneを8の字に動かすと方位の精度が上がります"
}

/// 現在地、方位、端末の向きを取得する。カメラ表示とコンパス表示の画面を開いている間だけ動かす。
@MainActor
@Observable
final class WaypointTracker: NSObject, CLLocationManagerDelegate {
    private(set) var locationAvailability: SensorAvailability = .unknown
    private(set) var motionAvailability: SensorAvailability = .unknown
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var horizontalAccuracy: Double?
    /// GPSの高度(m、CLLocation.altitude。平均海面から)。高さの精度が無効なら nil。
    private(set) var gpsAltitude: Double?
    private(set) var verticalAccuracy: Double?
    /// 位置を測った時刻(古い位置のままかを、方角のデバッグ表示で見る)
    private(set) var locationTimestamp: Date?
    /// 位置の精度が「おおよそ」(正確な位置情報がオフ)。近くのものの方向がずれる
    private(set) var isReducedAccuracy = false
    /// 端末の上端が向いている方位(真北基準)。コンパス表示に使う。端末を水平に持っていても使える。
    private(set) var compassHeading: Double?
    private(set) var headingAccuracy: Double?
    /// CLHeading の真北・磁北の値(方角のデバッグ表示で比べる。無効なら nil)
    private(set) var compassTrueHeading: Double?
    private(set) var compassMagneticHeading: Double?
    /// 平滑化した端末の向き。カメラ越しの表示に使う。
    private(set) var attitude: CameraAttitude?
    /// 真北基準の向きが使えず、磁北基準で代用している
    private(set) var usesMagneticNorth = false

    // 方角のデバッグ表示に使う値(CoreMotion の更新のたびに入れる)
    /// 平滑化する前の CoreMotion の姿勢(ジャイロで保つときも、補正する前の値)
    private(set) var rawAttitude: CameraAttitude?
    private(set) var diagnostics = HeadingDiagnostics()
    /// 頼んだ基準と、CMMotionManager が実際に使っている基準(attitudeReferenceFrame)
    private(set) var requestedFrame: CMAttitudeReferenceFrame?
    private(set) var activeFrame: CMAttitudeReferenceFrame?
    /// CoreMotion を始めた回数と、使っている基準が頼んだものと違った(変わった)回数
    private(set) var motionStartCount = 0
    private(set) var frameChangeCount = 0
    /// 磁気の較正の状態(CMMagneticFieldCalibrationAccuracy。−1 は未較正)と、CMDeviceMotion.heading(度)
    private(set) var magneticAccuracy: Int?
    private(set) var motionHeading: Double?
    /// 方角をジャイロで保つ(試験。磁気による補正を打ち消す。設定の開発者向け)
    @ObservationIgnored var holdsHeadingWithGyro = false

    @ObservationIgnored private let manager = CLLocationManager()
    /// CMMotionManager はアプリで1つにするよう求められているので、スコープの画面どうしでは使い回す。
    /// 止めるのは、今使っている画面(owner)だけ(別の画面が始めたものを止めない)
    private static let sharedMotion = CMMotionManager()
    private static var motionOwner: ObjectIdentifier?
    private var motion: CMMotionManager { Self.sharedMotion }
    @ObservationIgnored private var isRunning = false
    /// 位置が変わったとき(一覧とホームの距離の表示用に保存する)
    @ObservationIgnored var onLocation: (@MainActor (CLLocation) -> Void)?

    /// 平滑化の重み(30fpsで、約0.15秒で追従する)
    static let smoothingWeight = 0.25
    static let updateInterval = 1.0 / 30.0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.headingFilter = 1
    }

    func start(includesMotion: Bool) {
        if !isRunning {
            isRunning = true
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .denied, .restricted: locationAvailability = .denied
            default: break
            }
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        }
        if includesMotion { startMotion() } else { stopMotion() }
    }

    func stop() {
        isRunning = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        stopMotion()
    }

    private func stopMotion() {
        if Self.motionOwner == ObjectIdentifier(self) {
            if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
            Self.motionOwner = nil
        }
        attitude = nil
        rawAttitude = nil
    }

    /// ジャイロで保つときの補正を0に戻す(今の CoreMotion の方角に合わせ直す)
    func resetHeadingDiagnostics() {
        diagnostics.reset()
    }

    private func startMotion() {
        if motion.isDeviceMotionActive {
            if Self.motionOwner == ObjectIdentifier(self) { return }
            // 別の画面が始めたままのものは、止めてから始め直す
            motion.stopDeviceMotionUpdates()
        }
        guard motion.isDeviceMotionAvailable else {
            motionAvailability = .unsupported
            return
        }
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame
        if frames.contains(.xTrueNorthZVertical) {
            frame = .xTrueNorthZVertical
            usesMagneticNorth = false
        } else if frames.contains(.xMagneticNorthZVertical) {
            frame = .xMagneticNorthZVertical
            usesMagneticNorth = true
        } else {
            motionAvailability = .unsupported
            return
        }
        motion.deviceMotionUpdateInterval = Self.updateInterval
        motion.showsDeviceMovementDisplay = true
        Self.motionOwner = ObjectIdentifier(self)
        requestedFrame = frame
        activeFrame = nil
        motionStartCount += 1
        // 始め直したら、前の平滑化と診断は使わない(新しい基準の値と混ぜない)
        attitude = nil
        rawAttitude = nil
        diagnostics.reset()
        let owner = ObjectIdentifier(self)
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, error in
            MainActor.assumeIsolated {
                guard let self, Self.motionOwner == owner else { return }
                guard let data else {
                    if error != nil { self.motionAvailability = .unsupported }
                    return
                }
                self.motionAvailability = .available
                let matrix = data.attitude.rotationMatrix
                let raw = CameraAttitude(m11: matrix.m11, m12: matrix.m12, m13: matrix.m13,
                                         m21: matrix.m21, m22: matrix.m22, m23: matrix.m23,
                                         m31: matrix.m31, m32: matrix.m32, m33: matrix.m33)
                self.recordDiagnostics(data, raw: raw)
                // ジャイロで保つ(試験)ときは、ジャイロで説明できない回転の累計を打ち消す
                let held = self.holdsHeadingWithGyro ? raw.rotatedClockwise(by: -self.diagnostics.correction) : raw
                // 方角の手動補正(設定の「方角の補正」)
                let offset = HeadingCorrection.current
                let used = offset == 0 ? held : held.rotatedClockwise(by: offset)
                self.attitude = self.attitude?.smoothed(toward: used, weight: Self.smoothingWeight) ?? used
            }
        }
    }

    private func recordDiagnostics(_ data: CMDeviceMotion, raw: CameraAttitude) {
        rawAttitude = raw
        let rate = data.rotationRate
        let gravity = data.gravity
        diagnostics.update(MotionSample(attitude: raw, rotationRate: Vector3(x: rate.x, y: rate.y, z: rate.z),
                                        gravity: Vector3(x: gravity.x, y: gravity.y, z: gravity.z), timestamp: data.timestamp))
        magneticAccuracy = Int(data.magneticField.accuracy.rawValue)
        motionHeading = data.heading >= 0 ? data.heading : nil
        let frame = motion.attitudeReferenceFrame
        if let activeFrame, activeFrame != frame { frameChangeCount += 1 }
        if activeFrame == nil, let requestedFrame, requestedFrame != frame { frameChangeCount += 1 }
        activeFrame = frame
    }

    /// 基準の名前(デバッグ表示)
    static func frameName(_ frame: CMAttitudeReferenceFrame?) -> String {
        guard let frame else { return "なし" }
        switch frame {
        case .xTrueNorthZVertical: return "xTrueNorthZVertical"
        case .xMagneticNorthZVertical: return "xMagneticNorthZVertical"
        case .xArbitraryCorrectedZVertical: return "xArbitraryCorrectedZVertical"
        case .xArbitraryZVertical: return "xArbitraryZVertical"
        default: return "不明(\(frame.rawValue))"
        }
    }

    // CLLocationManager のデリゲートは、マネージャーを作ったスレッド(メイン)で呼ばれる
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .denied, .restricted: locationAvailability = .denied
            case .authorizedAlways, .authorizedWhenInUse: if locationAvailability == .denied { locationAvailability = .unknown }
            default: break
            }
            isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
            locationAvailability = .available
            coordinate = location.coordinate
            horizontalAccuracy = location.horizontalAccuracy
            locationTimestamp = location.timestamp
            isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
            if location.verticalAccuracy > 0 {
                gpsAltitude = location.altitude
                verticalAccuracy = location.verticalAccuracy
            }
            onLocation?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated {
            headingAccuracy = newHeading.headingAccuracy
            compassTrueHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : nil
            compassMagneticHeading = newHeading.magneticHeading >= 0 ? newHeading.magneticHeading : nil
            guard newHeading.headingAccuracy >= 0 else { return }
            // 方角の手動補正を足す(デバッグ表示の真北・磁北は、補正する前の値のまま)
            compassHeading = HeadingCorrection.apply(newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            if (error as? CLError)?.code == .denied { locationAvailability = .denied }
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
}

/// カメラの起動にかかった時間の内訳(開発者向けの表示用)
struct CameraStartTiming: Equatable {
    /// 許可の確認(初回は、許可のダイアログに答えるまでの時間を含む)
    var authorization: TimeInterval
    /// デバイスの選択と、セッションの設定。2回目以降は使い回すので 0。
    var configuration: TimeInterval
    /// startRunning() が戻るまで(映像が流れ始めるまで)
    var startRunning: TimeInterval
    /// 設定を使い回したか
    var reusedConfiguration: Bool

    var total: TimeInterval { authorization + configuration + startRunning }

    static func milliseconds(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }

    var text: String {
        "合計 \(Self.milliseconds(total))(許可の確認 \(Self.milliseconds(authorization))、設定 "
            + (reusedConfiguration ? "使い回し" : Self.milliseconds(configuration))
            + "、映像の開始 \(Self.milliseconds(startRunning)))"
    }
}

/// AVCaptureSession を専用のキューで扱う。設定と startRunning() / stopRunning() は時間がかかるので、メインスレッドでは呼ばない。
/// セッションは一度設定したら使い回す(画面を開くたびに作り直さない)。
final class CameraWorker: @unchecked Sendable {
    struct Configuration: Sendable {
        /// 計算に使う長辺の画角(歪みの補正とズームを考えたもの)
        var fieldOfView: Double
        var videoAspect: Double
        var seconds: TimeInterval
        var reused: Bool
        /// デバッグ表示用: activeFormat.videoFieldOfView、補正のあとの画角(補正が効いていなければ nil)、ズーム
        var formatFieldOfView: Double = 60
        var correctedFieldOfView: Double?
        var zoom: Double = 1
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "waypoint.camera", qos: .userInitiated)
    /// 「撮って聞く」のための、映像の1コマの取り出し(写真の撮影ではないので、シャッター音は鳴らない)
    private let grabber = FrameGrabber()
    /// queue の中でだけ読み書きする
    private var configuration: Configuration?

    /// 設定(初回だけ)をして、映像を始める。設定できなければ nil。
    func start() async -> (configuration: Configuration, startSeconds: TimeInterval)? {
        await withCheckedContinuation { continuation in
            queue.async {
                let began = Date()
                guard var configuration = self.configureIfNeeded() else {
                    continuation.resume(returning: nil)
                    return
                }
                configuration.seconds = configuration.reused ? 0 : Date().timeIntervalSince(began)
                let startBegan = Date()
                if !self.session.isRunning { self.session.startRunning() }
                continuation.resume(returning: (configuration, Date().timeIntervalSince(startBegan)))
            }
        }
    }

    /// 今の映像の1コマ(縦向き)。映像が動いていなければ nil。
    func captureFrame() async -> CGImage? {
        await grabber.next(timeout: 1.5)
    }

    /// 閉じる操作を待たせないよう、結果は待たない
    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() -> Configuration? {
        if var configuration {
            configuration.reused = true
            return configuration
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.beginConfiguration()
        // 重ねて見るだけなので、軽い解像度にする
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        session.addInput(input)
        grabber.attach(to: session)
        session.commitConfiguration()
        let format = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        var result = Configuration(fieldOfView: 60, videoAspect: 16.0 / 9.0, seconds: 0, reused: false)
        if format.videoFieldOfView > 0 { result.formatFieldOfView = Double(format.videoFieldOfView) }
        // 歪みの補正が効いていると、映像は補正の前より少し狭く写る
        if device.isGeometricDistortionCorrectionSupported, device.isGeometricDistortionCorrectionEnabled,
           format.geometricDistortionCorrectedVideoFieldOfView > 0 {
            result.correctedFieldOfView = Double(format.geometricDistortionCorrectedVideoFieldOfView)
        }
        result.zoom = Double(device.videoZoomFactor)
        result.fieldOfView = WaypointProjection.effectiveFieldOfView(format: result.formatFieldOfView, distortionCorrected: result.correctedFieldOfView,
                                                                     zoom: result.zoom)
        if dimensions.width > 0, dimensions.height > 0 {
            result.videoAspect = Double(max(dimensions.width, dimensions.height)) / Double(min(dimensions.width, dimensions.height))
        }
        configuration = result
        return result
    }
}

/// 背面カメラの映像。許可がないときや、カメラが使えない環境では、その状態だけを返す(クラッシュさせない)。
/// アプリ全体で1つ(AppEnvironment)を使い回す。
@MainActor
@Observable
final class CameraController {
    enum State: Equatable {
        case idle
        case starting
        case running
        case denied
        case unavailable
    }

    private(set) var state: State = .idle
    /// 映像の長辺の画角(度)と、長辺÷短辺
    private(set) var fieldOfView = 60.0
    private(set) var videoAspect = 16.0 / 9.0
    /// デバッグ表示用(`CameraWorker.Configuration`)
    private(set) var formatFieldOfView = 60.0
    private(set) var correctedFieldOfView: Double?
    private(set) var zoom = 1.0
    /// 直近の起動にかかった時間(開発者向け)
    private(set) var lastTiming: CameraStartTiming?

    @ObservationIgnored private let worker = CameraWorker()
    /// start() と stop() が入れ違いになったときに、古い結果を捨てるための番号
    @ObservationIgnored private var generation = 0

    var session: AVCaptureSession { worker.session }

    func start() async {
        guard state != .starting, state != .running else { return }
        generation += 1
        let current = generation
        state = .starting
        let began = Date()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                if current == generation { state = .denied }
                return
            }
        default:
            state = .denied
            return
        }
        let authorization = Date().timeIntervalSince(began)
        guard current == generation else { return }
        guard let result = await worker.start() else {
            if current == generation { state = .unavailable }
            return
        }
        guard current == generation else {
            // 待っている間に画面が閉じられた
            worker.stop()
            return
        }
        fieldOfView = result.configuration.fieldOfView
        videoAspect = result.configuration.videoAspect
        formatFieldOfView = result.configuration.formatFieldOfView
        correctedFieldOfView = result.configuration.correctedFieldOfView
        zoom = result.configuration.zoom
        lastTiming = CameraStartTiming(authorization: authorization, configuration: result.configuration.seconds,
                                       startRunning: result.startSeconds, reusedConfiguration: result.configuration.reused)
        state = .running
    }

    func stop() {
        generation += 1
        worker.stop()
        if state == .running || state == .starting { state = .idle }
    }

    /// 今の映像の1コマ(縦向き、印などの重ね描きを含まない元の映像)。動いていなければ nil。
    func captureFrame() async -> CGImage? {
        guard state == .running else { return nil }
        return await worker.captureFrame()
    }
}

/// 映像のコマを受け取り、頼まれたときだけ1コマを画像にする。ふだんは何もしない(受け取ったコマはすぐ捨てる)。
final class FrameGrabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "waypoint.camera.frames", qos: .userInitiated)
    private let lock = NSLock()
    /// lock の中でだけ読み書きする。頼んだ順の番号 → 待っている呼び出し。
    private var waiting: [Int: CheckedContinuation<CGImage?, Never>] = [:]
    private var nextID = 0
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    /// セッションの設定の中(beginConfiguration と commitConfiguration の間)で呼ぶ
    func attach(to session: AVCaptureSession) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // 画面と同じ縦向きのコマにする
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func next(timeout: TimeInterval) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let id = lock.withLock { () -> Int in
                nextID += 1
                waiting[nextID] = continuation
                return nextID
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                // 時間内にコマが来なければ、nil で返す(ほかの呼び出しには触らない)
                guard let self else { return }
                let expired = self.lock.withLock { self.waiting.removeValue(forKey: id) }
                expired?.resume(returning: nil)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let hasWaiting = lock.withLock { !waiting.isEmpty }
        guard hasWaiting, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let frame = context.createCGImage(image, from: image.extent)
        let pending = lock.withLock { () -> [CheckedContinuation<CGImage?, Never>] in
            let list = Array(waiting.values)
            waiting = [:]
            return list
        }
        for continuation in pending { continuation.resume(returning: frame) }
    }
}

/// カメラの映像を画面いっぱいに表示する
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer?.session = session
        view.previewLayer?.videoGravity = .resizeAspectFill
        Self.keepPortrait(view)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        // 接続はセッションの設定のあとにできるので、更新のたびに確かめる
        Self.keepPortrait(view)
    }

    /// 映像はいつも縦向き(画面が横に回っても回さない。重ねる印の計算は縦向きの前提)
    static func keepPortrait(_ view: PreviewView) {
        guard let connection = view.previewLayer?.connection, connection.videoRotationAngle != 90,
              connection.isVideoRotationAngleSupported(90) else { return }
        connection.videoRotationAngle = 90
    }
}

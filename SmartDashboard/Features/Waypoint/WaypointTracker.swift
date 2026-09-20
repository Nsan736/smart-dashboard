import AVFoundation
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
    /// 端末の上端が向いている方位(真北基準)。コンパス表示に使う。端末を水平に持っていても使える。
    private(set) var compassHeading: Double?
    private(set) var headingAccuracy: Double?
    /// 平滑化した端末の向き。カメラ越しの表示に使う。
    private(set) var attitude: CameraAttitude?
    /// 真北基準の向きが使えず、磁北基準で代用している
    private(set) var usesMagneticNorth = false

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var isRunning = false
    /// 位置が変わったとき(一覧とホームの距離の表示用に保存する)
    @ObservationIgnored var onLocation: (@MainActor (CLLocationCoordinate2D) -> Void)?

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
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        attitude = nil
    }

    private func startMotion() {
        guard !motion.isDeviceMotionActive else { return }
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
        motion.startDeviceMotionUpdates(using: frame, to: .main) { [weak self] data, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let matrix = data?.attitude.rotationMatrix else {
                    if error != nil { self.motionAvailability = .unsupported }
                    return
                }
                self.motionAvailability = .available
                let new = CameraAttitude(m11: matrix.m11, m12: matrix.m12, m13: matrix.m13,
                                         m21: matrix.m21, m22: matrix.m22, m23: matrix.m23,
                                         m31: matrix.m31, m32: matrix.m32, m33: matrix.m33)
                self.attitude = self.attitude?.smoothed(toward: new, weight: Self.smoothingWeight) ?? new
            }
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
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
            locationAvailability = .available
            coordinate = location.coordinate
            horizontalAccuracy = location.horizontalAccuracy
            onLocation?(location.coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated {
            headingAccuracy = newHeading.headingAccuracy
            guard newHeading.headingAccuracy >= 0 else { return }
            compassHeading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
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
        var fieldOfView: Double
        var videoAspect: Double
        var seconds: TimeInterval
        var reused: Bool
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "waypoint.camera", qos: .userInitiated)
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
        session.commitConfiguration()
        let format = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        var result = Configuration(fieldOfView: 60, videoAspect: 16.0 / 9.0, seconds: 0, reused: false)
        if format.videoFieldOfView > 0 { result.fieldOfView = Double(format.videoFieldOfView) }
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
        lastTiming = CameraStartTiming(authorization: authorization, configuration: result.configuration.seconds,
                                       startRunning: result.startSeconds, reusedConfiguration: result.configuration.reused)
        state = .running
    }

    func stop() {
        generation += 1
        worker.stop()
        if state == .running || state == .starting { state = .idle }
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
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

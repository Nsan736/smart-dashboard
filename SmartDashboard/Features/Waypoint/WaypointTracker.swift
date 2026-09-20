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

/// 背面カメラの映像。許可がないときや、カメラが使えない環境では、その状態だけを返す(クラッシュさせない)。
@MainActor
@Observable
final class CameraController {
    enum State: Equatable {
        case idle
        case running
        case denied
        case unavailable
    }

    private(set) var state: State = .idle
    /// 映像の長辺の画角(度)と、長辺÷短辺
    private(set) var fieldOfView = 60.0
    private(set) var videoAspect = 16.0 / 9.0

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "waypoint.camera")
    @ObservationIgnored private var isConfigured = false

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                state = .denied
                return
            }
        default:
            state = .denied
            return
        }
        guard configureIfNeeded() else {
            state = .unavailable
            return
        }
        let session = session
        queue.async { if !session.isRunning { session.startRunning() } }
        state = .running
    }

    func stop() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
        if state == .running { state = .idle }
    }

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.beginConfiguration()
        // 重ねて見るだけなので、軽い解像度にする
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        session.addInput(input)
        session.commitConfiguration()
        let format = device.activeFormat
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        if format.videoFieldOfView > 0 { fieldOfView = Double(format.videoFieldOfView) }
        if dimensions.width > 0, dimensions.height > 0 {
            videoAspect = Double(max(dimensions.width, dimensions.height)) / Double(min(dimensions.width, dimensions.height))
        }
        isConfigured = true
        return true
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

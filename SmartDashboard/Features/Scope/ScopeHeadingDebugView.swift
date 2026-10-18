import CoreMotion
import SwiftUI
import UIKit

/// 方角のデバッグ表示(設定の開発者向け「方角のデバッグ表示」)。スコープのカメラ表示の左上に出す。
/// 計算した方角とコンパス(CLHeading)の方角が30°以上違うときは、赤くする。
struct ScopeHeadingDebugView: View {
    let tracker: WaypointTracker
    /// 表示に使っている姿勢(平滑化のあと)
    let attitude: CameraAttitude
    let viewSize: CGSize

    var body: some View {
        let diagnostics = tracker.diagnostics
        let compass = tracker.compassTrueHeading ?? tracker.compassMagneticHeading
        let reference = HeadingDiagnostics.compassReference(attitude)
        let difference: Double? = {
            guard let compass, let reference else { return nil }
            return HeadingDiagnostics.difference(reference.azimuth, compass)
        }()
        let warns = difference.map { abs($0) >= HeadingDiagnostics.warningDifference } ?? false
        VStack(alignment: .leading, spacing: 2) {
            Text("方角 \(Self.number(attitude.azimuth))°  仰角 \(Self.number(attitude.elevation))°  傾き \(Self.number(attitude.roll))°")
                .font(.caption.weight(.bold).monospacedDigit())
            if let raw = tracker.rawAttitude {
                Text("CoreMotion の生の値 \(Self.number(raw.azimuth))°")
            }
            Text("基準: \(WaypointTracker.frameName(tracker.requestedFrame))"
                 + (tracker.activeFrame != nil && tracker.activeFrame != tracker.requestedFrame
                    ? " → 実際は \(WaypointTracker.frameName(tracker.activeFrame))" : ""))
            Text("開始 \(tracker.motionStartCount)回・基準が変わった \(tracker.frameChangeCount)回")
            Text("情報源: CoreMotion" + (tracker.holdsHeadingWithGyro ? "(ジャイロで保つ)" : "") + "。コンパス表示は CLHeading")
            Text("磁気の較正: \(Self.magneticText(tracker.magneticAccuracy))  CMDeviceMotion.heading "
                 + (tracker.motionHeading.map { "\(Self.number($0))°" } ?? "なし"))
            Text("コンパス 真北 " + (tracker.compassTrueHeading.map { "\(Self.number($0))°" } ?? "なし")
                 + "  磁北 " + (tracker.compassMagneticHeading.map { "\(Self.number($0))°" } ?? "なし")
                 + "  精度 " + (tracker.headingAccuracy.map { $0 >= 0 ? "±\(Int($0.rounded()))°" : "無効" } ?? "なし"))
            if let reference, let difference {
                Text("比べる軸 \(reference.axis): \(Self.number(reference.azimuth))°  コンパスとの差 \(Self.signed(difference))°")
                    .fontWeight(warns ? .bold : .regular)
                if warns {
                    Text("コンパスと\(Int(HeadingDiagnostics.warningDifference))°以上違います")
                        .font(.caption.weight(.bold))
                }
            } else {
                Text("比べる軸: なし(端末が斜めのときは比べない)")
            }
            Text("ジャイロで説明できない回転の累計 \(Self.signed(diagnostics.correction))°  跳び \(diagnostics.jumpCount)回"
                 + (diagnostics.lastJump.map { "(最後 \(Self.signed($0))°)" } ?? ""))
            Text("行列と重力の差 " + (diagnostics.gravityMismatch.map { "\(Self.number($0))°" } ?? "なし"))
            Text("画面 \(viewSize.width > viewSize.height ? "横" : "縦")(\(Int(viewSize.width))×\(Int(viewSize.height)))"
                 + "  シーン \(Self.sceneOrientationText)  持ち方 \(diagnostics.posture?.rawValue ?? "不明")")
            Button("ジャイロの累計を0に戻す") { tracker.resetHeadingDiagnostics() }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(warns ? Color.red.opacity(0.85) : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 340, alignment: .leading)
    }

    static func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func signed(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    static func magneticText(_ accuracy: Int?) -> String {
        guard let accuracy else { return "なし" }
        switch accuracy {
        case -1: return "未較正"
        case 0: return "低"
        case 1: return "中"
        case 2: return "高"
        default: return "不明"
        }
    }

    /// アプリの画面(シーン)の向き
    static var sceneOrientationText: String {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .portrait: return "縦"
        case .portraitUpsideDown: return "逆さ"
        case .landscapeLeft: return "横(左)"
        case .landscapeRight: return "横(右)"
        default: return "不明"
        }
    }
}

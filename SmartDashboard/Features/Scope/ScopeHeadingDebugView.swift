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
    /// 表示している印(遠い順)。近いものの方向と、位置の誤差による方向のずれの目安を出す
    var targets: [ScopeTarget] = []

    /// 表示する1行
    struct Line: Identifiable {
        let id: Int
        let text: String
        let emphasized: Bool
    }

    var body: some View {
        let report = Self.report(tracker: tracker, attitude: attitude, viewSize: viewSize, targets: targets)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(report.lines) { line in
                Text(line.text)
                    .font(line.emphasized ? .caption.weight(.bold).monospacedDigit() : .caption2.monospacedDigit())
            }
            Button("ジャイロの累計を0に戻す") { tracker.resetHeadingDiagnostics() }
                .font(.caption2.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(report.warns ? Color.red.opacity(0.85) : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 340, alignment: .leading)
    }

    /// 表示する行と、コンパスと30°以上違うか
    static func report(tracker: WaypointTracker, attitude: CameraAttitude, viewSize: CGSize,
                       targets: [ScopeTarget] = []) -> (lines: [Line], warns: Bool) {
        var texts: [(String, Bool)] = []
        let diagnostics = tracker.diagnostics

        let heading = "方角 \(number(attitude.azimuth))°  仰角 \(number(attitude.elevation))°  傾き \(number(attitude.roll))°"
        texts.append((heading, true))
        if let raw = tracker.rawAttitude {
            texts.append(("CoreMotion の生の値 \(number(raw.azimuth))°", false))
        }

        var frame = "基準: " + WaypointTracker.frameName(tracker.requestedFrame)
        if let active = tracker.activeFrame, active != tracker.requestedFrame {
            frame += " → 実際は " + WaypointTracker.frameName(active)
        }
        texts.append((frame, false))
        texts.append(("開始 \(tracker.motionStartCount)回・基準が変わった \(tracker.frameChangeCount)回", false))
        let source = tracker.holdsHeadingWithGyro ? "CoreMotion(ジャイロで保つ)" : "CoreMotion"
        texts.append(("情報源: " + source + "。コンパス表示は CLHeading", false))

        let motionHeading = tracker.motionHeading.map { "\(number($0))°" } ?? "なし"
        texts.append(("磁気の較正: " + magneticText(tracker.magneticAccuracy) + "  CMDeviceMotion.heading " + motionHeading, false))

        let trueText = tracker.compassTrueHeading.map { "\(number($0))°" } ?? "なし"
        let magneticHeading = tracker.compassMagneticHeading.map { "\(number($0))°" } ?? "なし"
        let accuracy = accuracyText(tracker.headingAccuracy)
        texts.append(("コンパス 真北 " + trueText + "  磁北 " + magneticHeading + "  精度 " + accuracy, false))

        if let correction = HeadingCorrection.text(HeadingCorrection.current) {
            texts.append(("方角の" + correction + "(上の方角は補正したあと。コンパスとは補正の前で比べる)", false))
        }
        var warns = false
        let compass = tracker.compassTrueHeading ?? tracker.compassMagneticHeading
        // コンパスの値は補正の前なので、補正を戻して比べる
        let uncorrected = attitude.rotatedClockwise(by: -HeadingCorrection.current)
        if let reference = HeadingDiagnostics.compassReference(uncorrected), let compass {
            let difference = HeadingDiagnostics.difference(reference.azimuth, compass)
            warns = abs(difference) >= HeadingDiagnostics.warningDifference
            let line = "比べる軸 " + reference.axis + ": \(number(reference.azimuth))°  コンパスとの差 \(signed(difference))°"
            texts.append((line, warns))
            if warns {
                texts.append(("コンパスと\(Int(HeadingDiagnostics.warningDifference))°以上違います", true))
            }
        } else {
            texts.append(("比べる軸: なし(端末が斜めのとき、コンパスがないときは比べない)", false))
        }

        var correction = "ジャイロで説明できない回転の累計 \(signed(diagnostics.correction))°  跳び \(diagnostics.jumpCount)回"
        if let jump = diagnostics.lastJump { correction += "(最後 \(signed(jump))°)" }
        texts.append((correction, false))
        let gravity = diagnostics.gravityMismatch.map { "\(number($0))°" } ?? "なし"
        texts.append(("行列と重力の差 " + gravity, false))

        let screen = viewSize.width > viewSize.height ? "横" : "縦"
        let posture = diagnostics.posture?.rawValue ?? "不明"
        let orientation = "画面 " + screen + "(\(Int(viewSize.width))×\(Int(viewSize.height)))  シーン " + sceneOrientationText + "  持ち方 " + posture
        texts.append((orientation, false))

        texts += locationLines(tracker: tracker, attitude: attitude, targets: targets)

        let lines = texts.enumerated().map { Line(id: $0.offset, text: $0.element.0, emphasized: $0.element.1) }
        return (lines, warns)
    }

    /// 現在地(精度・何秒前か・おおよそか)と、近い印の方向・距離・位置の誤差による方向のずれの目安(3つまで)
    static func locationLines(tracker: WaypointTracker, attitude: CameraAttitude, targets: [ScopeTarget]) -> [(String, Bool)] {
        var texts: [(String, Bool)] = []
        let accuracy = tracker.horizontalAccuracy
        var location = "現在地 " + (accuracy.map { "±\(Int($0.rounded()))m" } ?? "なし")
        if let time = tracker.locationTimestamp {
            location += "(\(Int(Date().timeIntervalSince(time).rounded()))秒前)"
        }
        location += tracker.isReducedAccuracy ? "  おおよその位置" : "  正確な位置"
        texts.append((location, tracker.isReducedAccuracy))
        for target in targets.suffix(3).reversed() {
            let offset = WaypointMath.difference(from: attitude.azimuth, to: target.bearing)
            let direction = " \(number(target.bearing))°(中央から\(signed(offset))°) "
            var line = target.mark.name + direction
            line += WaypointMath.distanceText(target.distance)
            var emphasized = false
            if let accuracy {
                let uncertainty = ScopeLocationCheck.bearingUncertainty(accuracy: accuracy, distance: target.distance)
                line += "  位置の誤差でのずれ ±\(Int(uncertainty.rounded()))°"
                emphasized = uncertainty >= ScopeLocationCheck.warningDegrees
            }
            texts.append((line, emphasized))
        }
        return texts
    }

    static func number(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func signed(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    static func accuracyText(_ accuracy: Double?) -> String {
        guard let accuracy else { return "なし" }
        return accuracy >= 0 ? "±\(Int(accuracy.rounded()))°" : "無効"
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

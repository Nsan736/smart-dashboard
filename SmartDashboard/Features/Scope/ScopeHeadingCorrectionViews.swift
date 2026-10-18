import SwiftUI

/// 方角の補正を変える部品(スライダー、±1°・±10°、0°に戻す)。設定とカメラ表示の両方で使う
struct HeadingCorrectionControls: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let settings = env.settings
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("方角の補正")
                Spacer()
                Text(String(format: "%+.1f°", settings.headingOffset))
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            Slider(value: Binding(get: { settings.headingOffset }, set: { settings.headingOffset = HeadingCorrection.normalized($0.rounded()) }),
                   in: HeadingCorrection.range, step: 1)
            ViewThatFits {
                HStack(spacing: 6) { buttons }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { stepButtons }
                    resetButton
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        stepButtons
        resetButton
    }

    @ViewBuilder
    private var stepButtons: some View {
        ForEach([-10.0, -1, 1, 10], id: \.self) { step in
            Button(String(format: "%+.0f°", step)) { add(step) }
                .monospacedDigit()
        }
    }

    private var resetButton: some View {
        Button("0°に戻す") { env.settings.headingOffset = 0 }
            .disabled(env.settings.headingOffset == 0)
    }

    private func add(_ step: Double) {
        env.settings.headingOffset = HeadingCorrection.normalized(env.settings.headingOffset + step)
    }
}

/// 設定の「方角の補正」
struct HeadingCorrectionSettingsSection: View {
    var body: some View {
        Section {
            HeadingCorrectionControls()
        } header: {
            Text("方角の補正")
        } footer: {
            Text("iPhone の磁気センサーがずれて、方角がずれたとき(iPhone のコンパスアプリでもずれるとき)の、短期的な対策です。端末が出した方角に、この値を足します(時計回りが+)。スコープのカメラ表示・コンパス表示・経路の案内のカメラ表示、センサー画面の方位、スクリプト型の小ツールの方位、地図の現在地の矢印に効きます。地図を進行方向に回す表示は、地図(MapKit)が自分で方角を求めるので効きません。根本的には、iPhone を8の字に動かすか、再起動すると直ることがあります。スコープのカメラ表示のメニューの「方角を補正」で、画面の中央に合わせた目印から補正することもできます。")
        }
    }
}

/// スコープのカメラ表示・コンパス表示の下に出す、方角の補正の操作。カメラ表示では、画面の中央(十字)に合わせた目印に合わせられる
struct ScopeHeadingCorrectionPanel: View {
    @Environment(AppEnvironment.self) private var env
    /// カメラの方角(今の補正を足したもの)。コンパス表示のときは nil(目印に合わせる操作は出さない)
    let azimuth: Double?
    let landmarks: [HeadingCorrection.Landmark]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("方角を補正").font(.subheadline.weight(.bold))
                Spacer()
                Button("閉じる", action: onClose).font(.subheadline)
            }
            if let azimuth {
                if let landmark = HeadingCorrection.nearest(landmarks, azimuth: azimuth) {
                    let offset = WaypointMath.difference(from: azimuth, to: landmark.bearing)
                    Text("中央の十字に一番近い目印: \(landmark.name)(方角\(Int(landmark.bearing.rounded()))°、中央から\(String(format: "%+.0f", offset))°)")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        env.settings.headingOffset = HeadingCorrection.aligned(offset: env.settings.headingOffset, currentAzimuth: azimuth,
                                                                               targetBearing: landmark.bearing)
                    } label: {
                        Label("この印に合わせる", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("実物の\(landmark.name)を画面の中央の十字に合わせてから押してください。そのずれの分を補正に入れます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("地点・山・オブジェクトなど、方角の分かっている目印の実物を、画面の中央の十字に合わせてください(左右\(Int(HeadingCorrection.alignLimit))°以内の目印を選べます)。")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HeadingCorrectionControls()
        }
        .padding(12)
        .background(.regularMaterial)
    }
}

/// カメラ表示・コンパス表示に小さく出す「補正 +12°」
struct HeadingCorrectionBadge: View {
    let offset: Double

    var body: some View {
        if let text = HeadingCorrection.text(offset) {
            Text(text)
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

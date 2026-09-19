import SwiftUI
import UIKit

struct SensorsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var location = LocationSensors()
    @State private var motion = MotionSensors()
    @State private var noise = NoiseMeter()
    @State private var device = DeviceStatus()
    @State private var noiseEnabled = false
    @State private var isVisible = false

    var body: some View {
        NavigationStack {
            List {
                speedSection
                altitudeSection
                headingSection
                motionSection
                pedometerSection
                noiseSection
                deviceSection
                temperatureSection
                Section {
                } footer: {
                    Text("センサーはこの画面を表示している間だけ動きます。通信は行いません。")
                }
            }
            .navigationTitle("センサー")
        }
        .onAppear { isVisible = true; startAll() }
        .onDisappear { isVisible = false; stopAll() }
        .onChange(of: scenePhase) { _, phase in
            guard isVisible else { return }
            if phase == .active { startAll() } else { stopAll() }
        }
    }

    private func startAll() {
        motion.onPedometerUpdate = { [location] snapshot, date in location.addPedometer(snapshot, at: date) }
        location.start()
        motion.start()
        device.start()
        if noiseEnabled { noise.start() }
        ScreenAwake.set("sensors", env.settings.sensorsKeepAwake)
    }

    private func stopAll() {
        location.stop()
        motion.stop()
        device.stop()
        noise.stop()
        ScreenAwake.set("sensors", false)
    }

    // MARK: - 速度

    private var speedSection: some View {
        Section {
            SpeedReadout(location: location, size: 64)
            if location.availability.unavailableText == nil || location.estimator.distance > 0 {
                HStack {
                    smallMetric("最高", String(format: "%.1f km/h", location.estimator.maxSpeed * 3.6))
                    smallMetric("平均", String(format: "%.1f km/h", location.estimator.averageSpeed * 3.6))
                    smallMetric("距離", String(format: "%.2f km", location.estimator.distance / 1000))
                }
                HStack {
                    Text("この画面を開いてからの値")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("リセット") { location.resetStatistics() }
                        .buttonStyle(.bordered)
                }
            }
        } header: {
            Text("速度")
        } footer: {
            Text("高精度のGPSで測ります。屋内や地下などGPSで動きを検出できないときは、歩行ペースから推定します。画面を離れると測位を止めます。")
        }
    }

    // MARK: - 高度・気圧

    private var altitudeSection: some View {
        Section("高度・気圧") {
            if let text = motion.altimeterAvailability.unavailableText {
                LabeledContent("気圧・相対高度", value: text)
            } else {
                HStack {
                    BigValue(value: motion.pressureHPa.map { String(format: "%.1f", $0) } ?? "-", unit: "hPa", size: 40)
                    Spacer()
                }
                LabeledContent("相対高度", value: motion.relativeAltitude.map { String(format: "%+.1f m", $0) } ?? "-")
            }
            LabeledContent("GPS高度", value: location.availability.unavailableText
                ?? location.altitude.map { String(format: "%.0f m", $0) } ?? "-")
        }
    }

    // MARK: - 方位

    private var headingSection: some View {
        Section("方位") {
            if let text = location.availability.unavailableText {
                unavailable(text)
            } else if !location.headingAvailable {
                unavailable("利用不可(この環境では使えません)")
            } else if let heading = location.heading {
                HStack(spacing: 20) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                        .rotationEffect(.degrees(-heading))
                        .animation(.easeOut(duration: 0.2), value: heading)
                    BigValue(value: String(format: "%.0f", heading), unit: "° \(LocationSensors.compassLabel(heading))", size: 48)
                }
            } else {
                Text("測定中").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 加速度・傾き

    private var motionSection: some View {
        Section("加速度・傾き") {
            if let text = motion.motionAvailability.unavailableText {
                unavailable(text)
            } else {
                HStack(spacing: 20) {
                    LevelView(pitch: motion.pitchDegrees ?? 0, roll: motion.rollDegrees ?? 0)
                        .frame(width: 110, height: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        smallMetric("前後", motion.pitchDegrees.map { String(format: "%+.1f°", $0) } ?? "-")
                        smallMetric("左右", motion.rollDegrees.map { String(format: "%+.1f°", $0) } ?? "-")
                        smallMetric("加速度", motion.accelerationG.map { String(format: "%.2f G", $0) } ?? "-")
                    }
                }
            }
        }
    }

    // MARK: - 歩数

    private var pedometerSection: some View {
        Section("今日の歩数") {
            if let text = motion.pedometerAvailability.unavailableText {
                unavailable(text)
            } else {
                HStack {
                    BigValue(value: motion.stepsToday.map(String.init) ?? "-", unit: "歩", size: 44)
                    Spacer()
                    if let distance = motion.walkingDistanceToday {
                        Text(String(format: "%.2f km", distance / 1000))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                HStack {
                    smallMetric("ペース", PedometerSnapshot.paceText(secondsPerMeter: motion.currentPace) ?? "-")
                    smallMetric("歩調", PedometerSnapshot.cadenceText(stepsPerSecond: motion.currentCadence) ?? "-")
                }
                Text("歩数は数秒おきにまとめて更新されるため、数秒の遅れがあります。ペースと歩調は歩いている間だけ表示されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 騒音

    private var noiseSection: some View {
        Section {
            Toggle("マイクで測定する", isOn: $noiseEnabled)
                .onChange(of: noiseEnabled) { _, enabled in
                    if enabled { noise.start() } else { noise.stop() }
                }
            if noiseEnabled {
                if let text = noise.availability.unavailableText {
                    unavailable(text)
                } else if let db = noise.decibels {
                    HStack {
                        BigValue(value: String(format: "%.0f", db), unit: "dB", size: 44)
                        Spacer()
                        Text(NoiseMeter.levelLabel(db)).font(.title3.weight(.semibold))
                    }
                } else {
                    Text("測定中").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("周囲の騒音")
        } footer: {
            Text("校正していない目安の値です。録音データは保存しません。")
        }
    }

    // MARK: - 端末

    private var deviceSection: some View {
        Section("端末") {
            LabeledContent("画面の明るさ", value: String(format: "%.0f%%", device.brightness * 100))
        }
    }

    private var temperatureSection: some View {
        Section {
            if let cached = env.weather.cached {
                LabeledContent("外気温(予報値)", value: String(format: "%.1f°C", cached.value.current.temperature))
                Text("\(cached.value.placeName)・\(Formatters.ageLabel(cached.fetchedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("外気温(予報値)", value: "天気が未取得です")
            }
        } header: {
            Text("気温")
        } footer: {
            Text("iPhoneには周囲の気温を測る公開センサーがないため、天気のキャッシュにある値を表示しています。")
        }
    }

    private func unavailable(_ text: String) -> some View {
        Label(text, systemImage: "nosign").foregroundStyle(.secondary)
    }

    private func smallMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// リアルタイムの速度。GPSの値 → 位置の差分 → 歩行ペース の順に使い、どれも使えなければ停止中(0)か「測位中…」。
/// どの方法で出した値かを必ず表示する。
struct SpeedReadout: View {
    let location: LocationSensors
    var size: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let reading = location.reading(now: context.date)
                if let speed = reading.speed {
                    BigValue(value: String(format: "%.1f", speed * 3.6), unit: "km/h", size: size)
                } else {
                    Text(location.availability.unavailableText ?? (location.isReducedAccuracy ? "測定不可" : "測位中…"))
                        .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Text(SpeedStatusText.method(reading.source, horizontalAccuracy: location.horizontalAccuracy))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(reading.source == .stationary ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SpeedStatusText.gps(lastUpdate: location.lastUpdate, horizontalAccuracy: location.horizontalAccuracy, now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if location.isReducedAccuracy {
                Label("位置の精度が「おおよそ」のため、GPSでは速度を測れません", systemImage: "location.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("設定 → プライバシーとセキュリティ → 位置情報サービス → LiveContainer →「正確な位置情報」をオンにしてください。歩いている間は、歩行ペースから推定した速度を表示します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 速度の状態の文言(Viewの外に置いてテストできるようにする)
enum SpeedStatusText {
    /// どの方法で出した値か
    static func method(_ source: SpeedSource?, horizontalAccuracy: Double?) -> String {
        switch source {
        case .reported?: return "GPSの速度"
        case .derived?: return "位置の差分から計算"
        case .pedometer?: return "歩行ペースから推定(GPSでは動きを検出できないため)"
        case .stationary?:
            if let accuracy = horizontalAccuracy, accuracy >= 0 {
                return String(format: "停止中(精度±%.0fmのため、ゆっくりした移動は検出できません)", accuracy)
            }
            return "停止中(ゆっくりした移動は検出できません)"
        case nil: return "速度を求められません(GPSの測位も、歩数の更新もありません)"
        }
    }

    /// 「GPS: 水平精度 ±5m・最後の測位から2秒」
    static func gps(lastUpdate: Date?, horizontalAccuracy: Double?, now: Date) -> String {
        guard let lastUpdate, let accuracy = horizontalAccuracy else { return "GPS: まだ測位できていません" }
        var parts = [accuracy >= 0 ? String(format: "水平精度 ±%.0fm", accuracy) : "水平精度 不明",
                     "最後の測位から\(max(0, Int(now.timeIntervalSince(lastUpdate))))秒"]
        if accuracy < 0 || accuracy > SpeedEstimator.maxHorizontalAccuracy {
            parts.append("精度が悪いためGPSの計算から除外中")
        }
        return "GPS: " + parts.joined(separator: "・")
    }
}

/// 水準器。平らなら気泡が中央に来る。
struct LevelView: View {
    let pitch: Double
    let roll: Double

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            let maxAngle = 30.0
            let x = max(-1, min(1, -roll / maxAngle)) * (radius - 12)
            let y = max(-1, min(1, pitch / maxAngle)) * (radius - 12)
            let isLevel = abs(pitch) < 1 && abs(roll) < 1
            ZStack {
                Circle().stroke(.secondary, lineWidth: 2)
                Circle().stroke(.secondary.opacity(0.5), lineWidth: 1).frame(width: 28, height: 28)
                Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1)
                Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
                Circle()
                    .fill(isLevel ? Color.green : Color.orange)
                    .frame(width: 22, height: 22)
                    .offset(x: x, y: y)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 画面の明るさ
@MainActor
@Observable
final class DeviceStatus {
    private(set) var brightness: Double = 0

    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        brightness = Double(UIScreen.main.brightness)
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.brightness = Double(UIScreen.main.brightness) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

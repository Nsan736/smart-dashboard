import SwiftUI

enum ScopeSightMode: String {
    case camera
    case compass
}

/// 次の曲がり角の印の色(目的地や地点の色と区別する)
enum ScopeRouteStyle {
    static let turnColor = Color.yellow
    static let destinationColor = Color.red
}

/// カメラ越しの表示と、コンパス表示。地点・周辺・経路の3つで共通。開いている間だけ、カメラ・GPS・モーションを動かす。
struct ScopeSightView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: ScopeSightMode
    @State private var source: ScopeSightSource
    @State private var tracker = WaypointTracker()
    @State private var isVisible = false

    init(mode: ScopeSightMode, source: ScopeSightSource) {
        _mode = State(initialValue: mode)
        _source = State(initialValue: source)
    }

    var body: some View {
        @Bindable var settings = env.settings
        let targets = currentTargets
        let camera = env.camera
        ZStack {
            // 映像を待たずに、画面(印、精度の表示)は先に出す
            if mode == .camera, camera.state != .denied, camera.state != .unavailable {
                cameraLayer(targets)
            } else {
                compassLayer(targets)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if source == .route { guidanceBar }
                statusBar
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if case .places(let selectedID) = source {
                        Picker("表示する地点", selection: Binding(get: { selectedID }, set: { source = .places(selectedID: $0) })) {
                            Text("すべての地点").tag(UUID?.none)
                            ForEach(env.waypoints.waypoints) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                    Toggle("向いている方角を表示", isOn: $settings.waypointShowsHeading)
                } label: {
                    Label("表示の設定", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button {
                    mode = mode == .camera ? .compass : .camera
                } label: {
                    Label(mode == .camera ? "コンパス表示" : "カメラ表示", systemImage: mode == .camera ? "safari" : "camera")
                }
            }
        }
        .onAppear {
            isVisible = true
            tracker.onLocation = { [store = env.waypoints, route = env.route] coordinate in
                store.setOrigin(latitude: coordinate.latitude, longitude: coordinate.longitude)
                // 経路の案内: 次の曲がり角の切り替えと、経路から外れたかの判定
                route.updateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
            startAll()
        }
        .onDisappear {
            isVisible = false
            stopAll()
        }
        .onChange(of: scenePhase) { _, phase in
            guard isVisible else { return }
            if phase == .active { startAll() } else { stopAll() }
        }
        .onChange(of: mode) { _, _ in
            if isVisible { startAll() }
        }
    }

    private var title: String {
        switch source {
        case .places: return mode == .camera ? "カメラで見る" : "コンパス"
        case .nearby: return env.nearby.category?.label ?? "周辺"
        case .route: return "経路の案内"
        }
    }

    /// 表示する印。地点・周辺の施設・経路(次の曲がり角と目的地)のどれでも、同じ形にそろえる。
    private var currentMarks: [ScopeMark] {
        switch source {
        case .places(let selectedID):
            return env.waypoints.waypoints.filter { selectedID == nil || $0.id == selectedID }.map { ScopeMark($0) }
        case .nearby:
            return env.nearby.marks
        case .route:
            guard let navigator = env.route.navigator else { return [] }
            let destination = navigator.plan.destination
            var marks = [ScopeMark(id: "destination", name: destination.name, latitude: destination.latitude, longitude: destination.longitude,
                                   color: ScopeRouteStyle.destinationColor)]
            if let turn = navigator.nextTurn, !navigator.hasArrived {
                marks.append(ScopeMark(id: "turn", name: "次の曲がり角", latitude: turn.latitude, longitude: turn.longitude, color: ScopeRouteStyle.turnColor))
            }
            return marks
        }
    }

    private var currentTargets: [ScopeTarget] {
        guard let coordinate = tracker.coordinate else { return [] }
        return ScopeTarget.make(currentMarks, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// カメラ・GPS・モーションは、この画面を表示している間だけ動かす。表示中は画面を消さない。
    private func startAll() {
        let camera = env.camera
        ScreenAwake.set("scope", true)
        // 位置とモーションは、カメラの準備を待たずに始める(カメラの設定と開始は専用のキューで進む)
        tracker.start(includesMotion: mode == .camera)
        if mode == .camera {
            Task {
                await camera.start()
                // 許可がない、またはこの環境で使えないときは、コンパス表示に切り替える
                if camera.state == .denied || camera.state == .unavailable { mode = .compass }
            }
        } else {
            camera.stop()
        }
    }

    private func stopAll() {
        ScreenAwake.set("scope", false)
        tracker.stop()
        env.camera.stop()
    }

    // MARK: - カメラ越しの表示

    private func cameraLayer(_ targets: [ScopeTarget]) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black
                CameraPreviewView(session: env.camera.session)
                if env.camera.state != .running {
                    VStack {
                        Spacer()
                        Text("カメラを起動中…")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.15), in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
                if size.width > size.height {
                    Text("縦向きで使ってください")
                        .font(.headline)
                        .padding(10)
                        .background(.thinMaterial, in: Capsule())
                } else if let attitude = tracker.attitude {
                    ScopeOverlay(targets: targets, attitude: attitude,
                                 tangents: WaypointProjection.tangents(fieldOfView: env.camera.fieldOfView, videoAspect: env.camera.videoAspect, viewSize: size))
                    if env.settings.waypointShowsHeading {
                        VStack {
                            Text("\(WaypointMath.compassPoint(attitude.azimuth)) \(Int(attitude.azimuth.rounded()))°")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                                .padding(.top, 8)
                            Spacer()
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .horizontal)
    }

    // MARK: - コンパス表示

    private func compassLayer(_ targets: [ScopeTarget]) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                if env.camera.state == .denied {
                    note("カメラが許可されていないため、コンパス表示にしています。設定アプリでカメラを許可すると、カメラ越しに表示できます。")
                } else if env.camera.state == .unavailable {
                    note("この環境ではカメラを使えないため、コンパス表示にしています。")
                }
                if let heading = tracker.compassHeading {
                    if env.settings.waypointShowsHeading {
                        Text("\(WaypointMath.compassPoint(heading)) \(Int(heading.rounded()))°")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                    }
                    ScopeCompassDial(heading: heading, targets: targets)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 360)
                        .padding(.horizontal)
                    ForEach(Array(targets.reversed().prefix(12))) { target in
                        compassRow(target, heading: heading)
                    }
                    if targets.isEmpty {
                        Text(tracker.coordinate == nil ? "現在地を取得中…" : "表示するものがありません").foregroundStyle(.secondary)
                    }
                } else {
                    Text(tracker.locationAvailability.unavailableText.map { "位置情報: \($0)" } ?? "方位を取得中…")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
    }

    private func compassRow(_ target: ScopeTarget, heading: Double) -> some View {
        let turn = WaypointMath.difference(from: heading, to: target.bearing)
        return HStack(spacing: 10) {
            Circle().fill(target.mark.color).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(target.mark.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(WaypointMath.summary(bearing: target.bearing, distance: target.distance))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(abs(turn) < 5 ? "正面" : "\(turn > 0 ? "右" : "左")へ\(Int(abs(turn).rounded()))°")
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.horizontal)
    }

    // MARK: - 経路の案内

    @ViewBuilder
    private var guidanceBar: some View {
        let route = env.route
        VStack(alignment: .leading, spacing: 6) {
            if let navigator = route.navigator {
                Text(navigator.guidanceText)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if navigator.isOffRoute {
                    HStack {
                        Label("経路から外れています", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button(route.isLoading ? "取得中…" : "経路を取り直す") {
                            guard let coordinate = tracker.coordinate else { return }
                            Task { await route.fetch(fromLatitude: coordinate.latitude, longitude: coordinate.longitude) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(route.isLoading || tracker.coordinate == nil)
                    }
                }
            } else {
                Text(route.errorMessage ?? "経路がありません。「経路」の画面で取得してください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - 精度の表示

    private var statusBar: some View {
        let quality = HeadingQuality.make(accuracy: tracker.headingAccuracy)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(quality.text)
                Text(tracker.horizontalAccuracy.map { "位置の精度: ±\(Int($0.rounded()))m" }
                     ?? tracker.locationAvailability.unavailableText.map { "位置情報: \($0)" } ?? "位置を取得中…")
            }
            if quality.needsCalibration {
                Text(HeadingQuality.calibrationHint).foregroundStyle(.orange)
            }
            if tracker.usesMagneticNorth, mode == .camera {
                Text("真北が使えないため、磁北を基準にしています(数度ずれます)")
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }
}

/// カメラの映像の上に、画面内にある印を描く。1枚の Canvas にまとめ、遠いものから描く(近いものが手前)。
/// 画面の外にあるものは何も描かない。
struct ScopeOverlay: View {
    let targets: [ScopeTarget]
    let attitude: CameraAttitude
    let tangents: (horizontal: Double, vertical: Double)

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            for target in targets {
                guard let point = WaypointProjection.point(bearing: target.bearing, attitude: attitude, tangents: tangents, viewSize: size) else { continue }
                Self.drawMark(&context, at: point, target: target)
            }
        }
        .allowsHitTesting(false)
    }

    static func drawMark(_ context: inout GraphicsContext, at point: CGPoint, target: ScopeTarget) {
        let ring = WaypointMarkStyle.ringDiameter
        let line = WaypointMarkStyle.ringLineWidth
        let ringRect = CGRect(x: point.x - ring / 2, y: point.y - ring / 2, width: ring, height: ring)
        // 暗い映像の上でも見えるよう、黒いリングの外と内に、ごく細い白い縁を付ける
        context.fill(Path(ellipseIn: ringRect.insetBy(dx: line, dy: line)), with: .color(Color.white.opacity(0.35)))
        let inner = WaypointMarkStyle.innerDiameter(distance: target.distance)
        let innerRect = CGRect(x: point.x - inner / 2, y: point.y - inner / 2, width: inner, height: inner)
        context.fill(Path(ellipseIn: innerRect), with: .color(target.mark.color))
        context.stroke(Path(ellipseIn: ringRect.insetBy(dx: -0.5, dy: -0.5)), with: .color(Color.white.opacity(0.9)), lineWidth: 1)
        context.stroke(Path(ellipseIn: ringRect.insetBy(dx: line / 2, dy: line / 2)), with: .color(.black), lineWidth: line)
        // 名前と距離(薄い背景を付ける)
        let label = context.resolve(Text("\(target.mark.name)  \(WaypointMath.distanceText(target.distance))")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white))
        let labelSize = label.measure(in: CGSize(width: 220, height: 40))
        let labelRect = CGRect(x: point.x - labelSize.width / 2 - 6, y: point.y + ring / 2 + 4, width: labelSize.width + 12, height: labelSize.height + 4)
        context.fill(Path(roundedRect: labelRect, cornerRadius: 6), with: .color(Color.black.opacity(0.55)))
        context.draw(label, in: labelRect.insetBy(dx: 6, dy: 2))
    }
}

/// 方位の目盛りと、印の方向を示す矢印。端末の上端の向きが、常に上になる。
struct ScopeCompassDial: View {
    let heading: Double
    let targets: [ScopeTarget]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 26
            func position(_ degrees: Double, _ r: CGFloat) -> CGPoint {
                let rad = (degrees - heading) * .pi / 180
                return CGPoint(x: center.x + r * CGFloat(sin(rad)), y: center.y - r * CGFloat(cos(rad)))
            }
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
            // 10度ごとの目盛り(30度ごとは長く)
            var minor = Path()
            var major = Path()
            for degrees in stride(from: 0.0, to: 360, by: 10) {
                let isMajor = Int(degrees) % 30 == 0
                let from = position(degrees, radius - (isMajor ? 12 : 6))
                let to = position(degrees, radius)
                if isMajor {
                    major.move(to: from)
                    major.addLine(to: to)
                } else {
                    minor.move(to: from)
                    minor.addLine(to: to)
                }
            }
            context.stroke(minor, with: .color(Color.secondary.opacity(0.6)), lineWidth: 1)
            context.stroke(major, with: .color(.primary), lineWidth: 1.5)
            for (degrees, name) in [(0.0, "北"), (90.0, "東"), (180.0, "南"), (270.0, "西")] {
                let text = Text(name).font(.system(size: 16, weight: .bold)).foregroundColor(degrees == 0 ? .red : .primary)
                context.draw(text, at: position(degrees, radius - 26))
            }
            // 端末の向き(上が正面)
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x, y: center.y - radius - 20))
            pointer.addLine(to: CGPoint(x: center.x - 8, y: center.y - radius - 4))
            pointer.addLine(to: CGPoint(x: center.x + 8, y: center.y - radius - 4))
            pointer.closeSubpath()
            context.fill(pointer, with: .color(.primary))
            // 印の方向の矢印(遠いものから描く)
            for target in targets {
                let color = target.mark.color
                let tip = position(target.bearing, radius - 40)
                var shaft = Path()
                shaft.move(to: center)
                shaft.addLine(to: tip)
                context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                let rad = (target.bearing - heading) * .pi / 180
                let direction = CGPoint(x: CGFloat(sin(rad)), y: -CGFloat(cos(rad)))
                let normal = CGPoint(x: -direction.y, y: direction.x)
                var head = Path()
                head.move(to: CGPoint(x: tip.x + direction.x * 12, y: tip.y + direction.y * 12))
                head.addLine(to: CGPoint(x: tip.x + normal.x * 7, y: tip.y + normal.y * 7))
                head.addLine(to: CGPoint(x: tip.x - normal.x * 7, y: tip.y - normal.y * 7))
                head.closeSubpath()
                context.fill(head, with: .color(color))
                context.stroke(head, with: .color(.primary), lineWidth: 1)
            }
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(.primary))
        }
    }
}

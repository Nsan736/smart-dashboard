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

/// カメラ越しの表示と、コンパス表示。地点・周辺・経路・電車・景色で共通。開いている間だけ、カメラ・GPS・モーションを動かす。
/// 景色(山・稜線・水面・地名)は、選んだ層を、どの表示にも同じ Canvas で重ねる(設定で、景色の表示のときだけにもできる)。
struct ScopeSightView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: ScopeSightMode
    @State private var source: ScopeSightSource
    @State private var tracker = WaypointTracker()
    @State private var isVisible = false
    /// 電車(source が .trains のときだけ動かす)
    @State private var trainFeed = ScopeTrainFeed(reason: "scope.sight")
    @State private var trainDetail: ScopeTrainDetailSheet.Target?
    /// 「撮って聞く」(止めた映像で Claude に聞く)
    @State private var askSession: ScopeAskSession?
    @State private var isCapturing = false
    @State private var captureError: String?
    /// タップした山
    @State private var mountainDetail: SceneryMountain?

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
                        // 「選んだ1つ」は、非表示の地点も選べる(選んだ地点は一時的に表示する)
                        Picker("表示する地点", selection: Binding(get: { selectedID }, set: { source = .places(selectedID: $0) })) {
                            Text("すべての地点(表示中)").tag(UUID?.none)
                            ForEach(env.waypoints.waypoints) { Text($0.isHidden ? "\($0.name)(非表示)" : $0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                    Toggle("向いている方角を表示", isOn: $settings.waypointShowsHeading)
                    Toggle("高さを反映する", isOn: $settings.scopeUsesHeight)
                    Menu("景色") {
                        SceneryLayerToggles()
                        Toggle("隠れた山も薄く表示", isOn: $settings.sceneryShowsHiddenMountains)
                        if source != .scenery {
                            Toggle("この表示にも重ねる", isOn: Binding(get: { settings.sceneryOverlaysOthers }, set: {
                                settings.sceneryOverlaysOthers = $0
                                if isVisible { startAll() }
                            }))
                        }
                    }
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
            tracker.onLocation = { [store = env.waypoints, route = env.route, elevation = env.elevation, settings = env.settings,
                                    scenery = env.scenery, movement = env.movement] location in
                let coordinate = location.coordinate
                // 自分の高さ: 地面の標高は、100m以上動いたときだけ取り直す
                if settings.scopeHeightSource == .groundPlusHand {
                    elevation.updateGround(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                let gps: Double? = location.verticalAccuracy > 0 ? location.altitude : nil
                let height = elevation.observerHeight(latitude: coordinate.latitude, longitude: coordinate.longitude, gpsAltitude: gps)
                store.setOrigin(latitude: coordinate.latitude, longitude: coordinate.longitude, height: height?.meters)
                // 経路の案内: 次の曲がり角の切り替えと、経路から外れたかの判定
                route.updateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                // 景色: 200m以上動いたか、自分の高さが大きく変わったときだけ計算し直す(位置のデバッグの間は仮想の位置で、下の task が行う)
                if scenery.isActive, !movement.isVirtual {
                    scenery.update(latitude: coordinate.latitude, longitude: coordinate.longitude, observerAltitude: height?.meters)
                }
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
        .onChange(of: showsScenery) { _, _ in
            // 景色の層を切り替えたら、景色の保存と計算を始める・止める
            if isVisible { startAll() }
        }
        .sheet(item: $trainDetail) { target in
            ScopeTrainDetailSheet(target: target)
        }
        .sheet(item: $mountainDetail) { SceneryMountainSheet(mountain: $0) }
        .task(id: isVisible) {
            // 位置のデバッグの間は、仮想の位置で景色を計算する(2秒ごとに見て、200m以上動いたときだけ計算し直す)
            while isVisible, !Task.isCancelled {
                if showsScenery, env.movement.isVirtual, let point = env.movement.currentPoint {
                    env.scenery.update(latitude: point.latitude, longitude: point.longitude, observerAltitude: nil)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .fullScreenCover(item: $askSession) { session in
            ScopeAskView(snapshot: session.snapshot)
        }
        .onChange(of: askSession == nil) { _, closed in
            // 聞いている間は、カメラ・GPS・モーションを止める(閉じたら再開)
            if closed {
                if isVisible { startAll() }
            } else {
                stopAll()
            }
        }
    }

    /// 撮った方向の分類の名前(Claude に送る)
    private var sourceKindName: String {
        switch source {
        case .places: return "登録した地点"
        case .nearby: return "周辺の施設"
        case .route: return "経路の目的地・曲がり角"
        case .trains: return "電車"
        case .scenery: return "山"
        }
    }

    /// 景色を重ねるか(層を1つ以上選んでいて、景色の表示か、ほかの表示にも重ねる設定のとき)
    private var showsScenery: Bool {
        !env.settings.sceneryLayers.isEmpty && (source == .scenery || env.settings.sceneryOverlaysOthers)
    }

    private var sceneryOptions: SceneryDrawOptions {
        SceneryDrawOptions(layers: Set(env.settings.sceneryLayers), showsHiddenMountains: env.settings.sceneryShowsHiddenMountains)
    }

    /// 景色の計算の結果(重ねないときは nil)
    private var sceneryScene: SceneryScene? {
        showsScenery ? env.scenery.scene : nil
    }

    /// 「撮って聞く」: 今の映像の1コマ(画面に見えていた範囲)と、そのときの向き・位置・画面に写る範囲の印を取って、質問の画面を出す
    private func captureForAsk(viewSize: CGSize, attitude: CameraAttitude?, tangents: (horizontal: Double, vertical: Double),
                               targets: [ScopeTarget]) async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        captureError = nil
        guard let frame = await env.camera.captureFrame() else {
            captureError = "映像を取得できませんでした"
            return
        }
        let visible = ScopeAskImage.visibleRect(imageSize: CGSize(width: frame.width, height: frame.height), viewSize: viewSize)
        let image = frame.cropping(to: visible) ?? frame
        var inView: [ScopeAskTarget] = []
        if let attitude {
            let screen = CGRect(origin: .zero, size: viewSize)
            for target in targets {
                guard let point = WaypointProjection.point(bearing: target.bearing, elevation: target.elevationAngle, attitude: attitude,
                                                           tangents: tangents, viewSize: viewSize),
                      screen.contains(point) else { continue }
                inView.append(ScopeAskTarget(name: target.mark.name, kind: sourceKindName, bearing: target.bearing,
                                             distance: target.distance, heightDifference: target.heightDifference))
            }
        }
        let coordinate = tracker.coordinate
        askSession = ScopeAskSession(snapshot: ScopeAskSnapshot(
            image: image, heading: attitude?.azimuth, pitch: attitude?.elevation,
            latitude: coordinate?.latitude, longitude: coordinate?.longitude, placeName: nil,
            targets: inView, takenAt: Date(),
            // 答えの場所が写る範囲の中かを確かめるため(端末の中だけで使う)
            halfFieldOfView: atan(tangents.horizontal) * 180 / .pi))
    }

    /// 電車の位置を計算する基準の現在地(位置のデバッグの間は、仮想の位置)
    private var trainUserPoint: GeoPoint? {
        env.movement.isVirtual ? env.movement.currentPoint : tracker.coordinate.map { GeoPoint($0) }
    }

    private var title: String {
        switch source {
        case .places: return mode == .camera ? "カメラで見る" : "コンパス"
        case .nearby: return env.nearby.category?.label ?? "周辺"
        case .route: return "経路の案内"
        case .trains: return mode == .camera ? "電車をカメラで見る" : "電車のコンパス"
        case .scenery: return mode == .camera ? "景色をカメラで見る" : "景色のコンパス"
        }
    }

    /// 表示する印。地点・周辺の施設・経路(次の曲がり角と目的地)のどれでも、同じ形にそろえる。
    private var currentMarks: [ScopeMark] {
        switch source {
        case .places(let selectedID):
            // すべて: 表示中の地点だけ。選んだ1つ: 非表示の地点でも出す。
            guard let selectedID else { return env.waypoints.visibleWaypoints.map { ScopeMark($0) } }
            return env.waypoints.waypoints.filter { $0.id == selectedID }.map { ScopeMark($0) }
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
        case .trains:
            return trainFeed.marks()
        case .scenery:
            // カメラ表示では山の形の印で描くので、印はコンパス表示のときだけ(優先の高い12山)
            guard mode == .compass, let scene = env.scenery.scene else { return [] }
            return scene.mountains.filter { env.settings.sceneryShowsHiddenMountains || !$0.isHidden }.prefix(12).map { mountain in
                var mark = ScopeMark(id: "mountain.\(mountain.id)", name: mountain.entry.displayName, latitude: mountain.entry.latitude,
                                     longitude: mountain.entry.longitude, color: .brown, altitude: mountain.entry.elevation)
                mark.note = mountain.isHidden ? "手前の地形に隠れて見えない" : SceneryText.elevation(mountain.entry.elevation)
                return mark
            }
        }
    }

    /// 自分の高さ(設定で選んだ方法。地面の標高が取れないときはGPSの高度)
    private var observer: ObserverHeight? {
        guard let coordinate = tracker.coordinate else { return nil }
        return env.elevation.observerHeight(latitude: coordinate.latitude, longitude: coordinate.longitude, gpsAltitude: tracker.gpsAltitude)
    }

    private var currentTargets: [ScopeTarget] {
        if source == .trains {
            // コンパス表示の電車の印は、方角だけを出す(高さは印の文字で出す)。位置のデバッグの間は、仮想の位置から測る。
            guard let point = trainUserPoint else { return [] }
            return ScopeTarget.make(currentMarks, latitude: point.latitude, longitude: point.longitude)
        }
        guard let coordinate = tracker.coordinate else { return [] }
        return ScopeTarget.make(currentMarks, latitude: coordinate.latitude, longitude: coordinate.longitude,
                                observerAltitude: observer?.meters, usesHeight: env.settings.scopeUsesHeight)
    }

    /// カメラ・GPS・モーションは、この画面を表示している間だけ動かす。表示中は画面を消さない。
    private func startAll() {
        let camera = env.camera
        ScreenAwake.set("scope", true)
        // 位置とモーションは、カメラの準備を待たずに始める(カメラの設定と開始は専用のキューで進む)
        tracker.start(includesMotion: mode == .camera)
        if source == .trains, !trainFeed.isRunning {
            // 位置のデバッグの間は、仮想の位置と時刻を進める(移動タブと同じ仕組み)
            if env.movement.isVirtual { env.movement.setVisible(true) }
            trainFeed.start(env: env, user: { [tracker, movement = env.movement] in
                movement.isVirtual ? movement.currentPoint : tracker.coordinate.map { GeoPoint($0) }
            }, observer: { [tracker, elevation = env.elevation, settings = env.settings] in
                // 自分の高さ(地点と同じ決め方)。高さを使わない設定なら、電車も地面の高さに置く
                guard settings.scopeUsesHeight, let coordinate = tracker.coordinate else { return nil }
                return elevation.observerHeight(latitude: coordinate.latitude, longitude: coordinate.longitude, gpsAltitude: tracker.gpsAltitude)?.meters
            })
        }
        if showsScenery {
            env.scenery.setActive(true, reason: "scope.sight")
            // 位置のデバッグの間は、仮想の位置を進める
            if env.movement.isVirtual { env.movement.setVisible(true) }
        } else {
            env.scenery.setActive(false, reason: "scope.sight")
        }
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
        env.scenery.setActive(false, reason: "scope.sight")
        let wasTrains = trainFeed.isRunning
        if wasTrains { trainFeed.stop(env: env) }
        if env.movement.isVirtual, wasTrains || showsScenery { env.movement.setVisible(false) }
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
                    let tangents = WaypointProjection.tangents(fieldOfView: env.camera.fieldOfView, videoAspect: env.camera.videoAspect, viewSize: size)
                    if source == .trains {
                        ScopeTrainOverlay(feed: trainFeed, attitude: attitude, tangents: tangents, scenery: sceneryScene,
                                          sceneryOptions: sceneryOptions, onMountain: { mountainDetail = $0 }) { id in
                            trainDetail = ScopeTrainDetailSheet.Target(selection: .train(id))
                        }
                    } else {
                        ScopeOverlay(targets: targets, attitude: attitude, tangents: tangents, scenery: sceneryScene,
                                     sceneryOptions: sceneryOptions, onMountain: { mountainDetail = $0 })
                    }
                    VStack(alignment: .trailing, spacing: 6) {
                        Spacer()
                        if let captureError {
                            Text(captureError)
                                .font(.caption)
                                .padding(6)
                                .background(.thinMaterial, in: Capsule())
                        }
                        Button {
                            Task { await captureForAsk(viewSize: size, attitude: attitude, tangents: tangents, targets: targets) }
                        } label: {
                            Label(isCapturing ? "取得中…" : "撮って聞く", systemImage: "questionmark.bubble")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isCapturing || env.camera.state != .running)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(12)
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
                    ForEach(Array(targets.reversed().prefix(source == .trains ? 40 : 12))) { target in
                        if source == .trains {
                            Button {
                                trainDetail = ScopeTrainDetailSheet.Target(selection: .train(target.id))
                            } label: {
                                compassRow(target, heading: heading)
                            }
                            .buttonStyle(.plain)
                        } else {
                            compassRow(target, heading: heading)
                        }
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
                Text(WaypointMath.summary(bearing: target.bearing, distance: target.distance)
                     + (target.heightDifference.map { " " + WaypointMath.heightText($0) } ?? "")
                     + (target.mark.note.isEmpty ? "" : " " + target.mark.note))
                    .font(.footnote)
                    .foregroundStyle(target.mark.note.contains("接近中") ? Color.orange : Color.secondary)
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

    /// 電車の表示の状態(対象の路線と本数)
    private var trainStatusText: String {
        let settings = env.settings
        if trainFeed.railwayIDs.isEmpty {
            return settings.scopeTrainTarget == .nearby ? "近くを通る路線で、時刻表を保存しているものがありません" : "登録した路線の時刻表がありません(移動タブで取得)"
        }
        return "\(settings.scopeTrainTarget.label)の列車 \(trainFeed.trains.count)本(時刻表から計算した位置)。地面は自分の高さ−手の高さ"
    }

    /// 景色の状態(山の数、地形のデータの範囲、保存の進み具合)
    private var sceneryStatusText: String {
        let scenery = env.scenery
        guard let scene = scenery.scene else {
            return scenery.isComputing ? "景色: 計算中…" : "景色: 現在地を待っています"
        }
        let hidden = scene.mountains.filter { $0.isHidden }.count
        let visible = scene.mountains.count - hidden
        var parts = ["景色: 山\(visible)(見えない\(hidden))",
                     "地形のデータ\(Int((scene.coverage * 100).rounded()))%"]
        if scenery.isComputing { parts.append("計算中") }
        if scenery.isDownloading { parts.append("保存中 \(scenery.finishedCount)/\(scenery.plannedCount)") }
        var text = parts.joined(separator: "・")
        if let note = scenery.note { text += "。" + note }
        return text
    }

    /// 自分の高さと、その決め方(精度の表示の近くに小さく出す)
    private var observerText: String {
        let settings = env.settings
        guard let observer else { return tracker.coordinate == nil ? "自分の高さ: 測位中" : "自分の高さ: 取得中(地点は地平線の高さに置きます)" }
        var text = observer.text(handHeight: settings.scopeHandHeight, source: settings.scopeHeightSource)
        if observer.method == .gps, let accuracy = tracker.verticalAccuracy { text += " ±\(Int(accuracy.rounded()))m" }
        if !settings.scopeUsesHeight { text += "。高さは反映していません" }
        return text
    }

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
            if case .places = source {
                Text(observerText)
            } else if source == .scenery {
                Text(observerText)
            }
            if source == .trains {
                if env.movement.isVirtual {
                    Text("デバッグ中(仮想の位置と時刻)").foregroundStyle(.red)
                }
                Text(trainStatusText)
            } else if showsScenery, env.movement.isVirtual {
                Text("デバッグ中(景色は仮想の位置で計算)").foregroundStyle(.red)
            }
            if showsScenery {
                Text(sceneryStatusText)
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
    /// 景色(同じ Canvas に、印より先に描く)。重ねないときは nil
    var scenery: SceneryScene? = nil
    var sceneryOptions = SceneryDrawOptions(layers: [], showsHiddenMountains: true)
    /// 山をタップしたとき
    var onMountain: ((SceneryMountain) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            Canvas(rendersAsynchronously: false) { context, size in
                if let scenery {
                    SceneryRenderer.draw(&context, layout: SceneryRenderer.layout(scene: scenery, options: sceneryOptions, attitude: attitude,
                                                                                  tangents: tangents, size: size))
                }
                for target in targets {
                    guard let point = WaypointProjection.point(bearing: target.bearing, elevation: target.elevationAngle, attitude: attitude,
                                                               tangents: tangents, viewSize: size) else { continue }
                    Self.drawMark(&context, at: point, target: target)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard let scenery, let onMountain else { return }
                let layout = SceneryRenderer.layout(scene: scenery, options: sceneryOptions, attitude: attitude, tangents: tangents,
                                                    size: geometry.size)
                if let mountain = SceneryRenderer.hitMountain(value.location, layout: layout) { onMountain(mountain) }
            })
            .allowsHitTesting(scenery != nil && onMountain != nil && sceneryOptions.layers.contains(.mountains))
        }
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
        // 名前と距離・高低差(薄い背景を付ける)
        let label = context.resolve(Text("\(target.mark.name)  \(WaypointMath.distanceText(target.distance, heightDifference: target.heightDifference))")
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
            // 印の方向の矢印(遠いものから描く)。電車は、方向の位置に、進行方向の矢印の入った印を置く。
            for target in targets {
                let color = target.mark.color
                if let travel = target.mark.travelHeading {
                    let spot = position(target.bearing, radius - 40)
                    let rect = CGRect(x: spot.x - 11, y: spot.y - 11, width: 22, height: 22)
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                    context.stroke(Path(ellipseIn: rect), with: .color(.primary), lineWidth: 1.5)
                    let rad = (travel - heading) * .pi / 180
                    let direction = CGPoint(x: CGFloat(sin(rad)), y: -CGFloat(cos(rad)))
                    let normal = CGPoint(x: -direction.y, y: direction.x)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: spot.x + direction.x * 8, y: spot.y + direction.y * 8))
                    arrow.addLine(to: CGPoint(x: spot.x - direction.x * 5 + normal.x * 5, y: spot.y - direction.y * 5 + normal.y * 5))
                    arrow.addLine(to: CGPoint(x: spot.x - direction.x * 5 - normal.x * 5, y: spot.y - direction.y * 5 - normal.y * 5))
                    arrow.closeSubpath()
                    context.fill(arrow, with: .color(.white))
                    continue
                }
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

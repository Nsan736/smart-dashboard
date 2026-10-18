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

/// カメラ越しの表示と、コンパス表示。重ねる表示(`ScopeLayer`: 地点・周辺・オブジェクト・経路・電車・景色・太陽と月)をいくつでも同時に出す。
/// 一覧の画面の「カメラで見る」から開く。開いた画面の表示を、設定の重ねる表示(`AppSettings.scopeLayers`)に入れ、上部の「表示」で変えられる。
/// 開いている間だけ、カメラ・GPS・モーションを動かす。
struct ScopeSightView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: ScopeSightMode
    /// 開いた一覧の画面の表示(題名に使い、開いたときに重ねる表示に入れる)
    private let primaryLayer: ScopeLayer
    /// 地点の「選んだ1つ」(nil なら表示中の地点すべて)
    @State private var selectedPlaceID: UUID?
    @State private var showsLayers = false
    /// 写真からオブジェクトを作る画面(撮って囲んだ写真を集める)と、最近作ったもの
    @State private var showsPhotoComposer = false
    @State private var showsObjectRecents = false
    /// 太陽と月: 1日分の計算、表示する日、選んだ時刻(nil なら今)、日時を変えるパネル
    @State private var skyScene: SkyScene?
    @State private var skyDay = Date()
    @State private var skyTime: Date?
    @State private var showsSkyPanel = false
    @State private var tracker = WaypointTracker()
    @State private var isVisible = false
    /// 電車(電車の表示がオンのときだけ動かす)
    @State private var trainFeed = ScopeTrainFeed(reason: "scope.sight")
    @State private var trainDetail: ScopeTrainDetailSheet.Target?
    /// 「撮って聞く」(止めた映像で Claude に聞く)
    @State private var showsAsk = false
    @State private var showsAskRecents = false
    /// 最近聞いたことの一覧から会話を選んだ(一覧を閉じたあとに、聞く画面を出す)
    @State private var opensAskAfterRecents = false
    /// 方角の補正の操作を出す
    @State private var showsCorrection = false
    @State private var isCapturing = false
    @State private var captureError: String?
    /// タップした山
    @State private var mountainDetail: SceneryMountain?
    /// タップしたオブジェクト
    @State private var objectDetail: ObjectTap?

    struct ObjectTap: Identifiable {
        let id: UUID
    }

    /// 一覧の画面から、その表示で開く
    init(mode: ScopeSightMode, source: ScopeSightSource) {
        _mode = State(initialValue: mode)
        primaryLayer = source.layer
        if case .places(let id) = source { _selectedPlaceID = State(initialValue: id) }
    }

    /// 今の重ねる表示(設定。開いた画面の表示は、開いたときに入れる)
    private var layers: Set<ScopeLayer> { env.settings.scopeLayers }

    private func has(_ layer: ScopeLayer) -> Bool { layers.contains(layer) }

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
                if showsCorrection {
                    ScopeHeadingCorrectionPanel(azimuth: mode == .camera ? tracker.attitude?.azimuth : nil, landmarks: landmarks) {
                        showsCorrection = false
                    }
                }
                if has(.sunMoon), showsSkyPanel {
                    SkyTimePanel(day: $skyDay, time: $skyTime, displayTime: skyDisplayTime, scene: skyScene) { showsSkyPanel = false }
                }
                if has(.route), primaryLayer == .route || env.route.navigator != nil { guidanceBar }
                statusBar
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // 重ねる表示を選ぶ
                Button {
                    showsLayers = true
                } label: {
                    Label("表示", systemImage: "square.3.layers.3d")
                }
                Button {
                    mode = mode == .camera ? .compass : .camera
                } label: {
                    Label(mode == .camera ? "コンパス表示" : "カメラ表示", systemImage: mode == .camera ? "safari" : "camera")
                }
                Menu {
                    if has(.places) {
                        // 「選んだ1つ」は、非表示の地点も選べる(選んだ地点は一時的に表示する)
                        Picker("表示する地点", selection: $selectedPlaceID) {
                            Text("すべての地点(表示中)").tag(UUID?.none)
                            ForEach(env.waypoints.waypoints) { Text($0.isHidden ? "\($0.name)(非表示)" : $0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                    Toggle("向いている方角を表示", isOn: $settings.waypointShowsHeading)
                    Toggle("高さを反映する", isOn: $settings.scopeUsesHeight)
                    Menu("景色") {
                        SceneryLayerToggles()
                        Toggle("隠れた山も薄く表示", isOn: $settings.sceneryShowsHiddenMountains)
                        Picker("山の高さの強調", selection: $settings.sceneryHeightScale) {
                            ForEach(SceneryHeightScale.choices, id: \.self) { Text(SceneryHeightScale.label($0)).tag($0) }
                        }
                    }
                    if has(.sunMoon) {
                        Button {
                            showsSkyPanel.toggle()
                        } label: {
                            Label("太陽と月の日時を変える", systemImage: "clock")
                        }
                    }
                    Button {
                        showsCorrection.toggle()
                    } label: {
                        Label("方角を補正", systemImage: "location.north.line")
                    }
                    Button {
                        showsAskRecents = true
                    } label: {
                        Label("最近聞いたこと(撮って聞く)", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        showsObjectRecents = true
                    } label: {
                        Label("最近作ったもの(オブジェクト)", systemImage: "cube")
                    }
                } label: {
                    Label("その他", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsLayers) { ScopeLayerPickerView() }
        .sheet(isPresented: $showsObjectRecents) { ObjectComposeView() }
        .sheet(isPresented: $showsPhotoComposer) {
            // 撮り足すときは、この画面を閉じてカメラ表示に戻る(集めている写真は残る)
            ObjectComposeView(photos: true) { showsPhotoComposer = false }
        }
        .onChange(of: showsPhotoComposer) { _, shows in
            // 作る画面を出している間は、カメラ・GPS・モーションを止める
            if shows {
                stopAll()
            } else if isVisible {
                startAll()
            }
        }
        .onChange(of: layers) { _, _ in
            // 重ねる表示を変えたら、電車・景色の取得と計算を始める・止める
            if isVisible { startAll() }
        }
        .task(id: skyKey) {
            // 太陽と月の1日分は、日付か場所(約1km)か稜線が変わったときだけ作る(メインスレッドの外で)
            guard has(.sunMoon), let point = userPoint else {
                skyScene = nil
                return
            }
            let skyline = showsScenery ? env.scenery.scene?.skyline : nil
            let day = skyDay
            let scene = await Task.detached(priority: .utility) { () -> SkyScene in
                var horizon: ((Double) -> Double?)?
                if let skyline {
                    horizon = { bearing in skyline.horizonAngle(atBearing: bearing) }
                }
                return SkyScene.make(day: day, latitude: point.latitude, longitude: point.longitude, horizon: horizon)
            }.value
            skyScene = scene
        }
        .onAppear {
            isVisible = true
            // 開いた一覧の画面の表示を、重ねる表示に入れる
            if !env.settings.scopeLayers.contains(primaryLayer) { env.settings.scopeLayers.insert(primaryLayer) }
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
        .onChange(of: env.settings.headingGyroHold) { _, hold in
            tracker.holdsHeadingWithGyro = hold
        }
        .onChange(of: showsScenery) { _, _ in
            // 景色の層を切り替えたら、景色の保存と計算を始める・止める
            if isVisible { startAll() }
        }
        .onChange(of: showsObjects) { _, _ in
            if isVisible { startAll() }
        }
        .sheet(item: $trainDetail) { target in
            ScopeTrainDetailSheet(target: target)
        }
        .sheet(item: $mountainDetail) { SceneryMountainSheet(mountain: $0) }
        .sheet(item: $objectDetail) { ObjectPlacementInfoSheet(placementID: $0.id, user: userPoint) }
        .task(id: isVisible) {
            // 位置のデバッグの間は、仮想の位置で景色を計算する(2秒ごとに見て、200m以上動いたときだけ計算し直す)
            while isVisible, !Task.isCancelled {
                if showsScenery, env.movement.isVirtual, let point = env.movement.currentPoint {
                    env.scenery.update(latitude: point.latitude, longitude: point.longitude, observerAltitude: nil)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .fullScreenCover(isPresented: $showsAsk) {
            ScopeAskView()
        }
        .sheet(isPresented: $showsAskRecents, onDismiss: {
            if opensAskAfterRecents {
                opensAskAfterRecents = false
                showsAsk = true
            }
        }) {
            ScopeAskRecentsView { opensAskAfterRecents = true }
        }
        .onChange(of: showsAsk) { _, shows in
            // 聞いている間は、カメラ・GPS・モーションを止める(閉じたら再開。答えは閉じても待ち続ける)
            if shows {
                stopAll()
            } else if env.objectCompose.opensPhotoComposer {
                // 撮って囲んだ写真を「オブジェクトを作る」にしたとき
                env.objectCompose.opensPhotoComposer = false
                showsPhotoComposer = true
            } else if isVisible {
                startAll()
            }
        }
    }

    /// 印の ID → その印の表示(「撮って聞く」で送る印の種類と、コンパス表示で電車の行を見分けるのに使う)
    private var markLayers: [String: ScopeLayer] {
        var result: [String: ScopeLayer] = [:]
        for entry in layeredMarks { result[entry.mark.id] = entry.layer }
        return result
    }

    /// オブジェクトを重ねるか(オブジェクトの表示がオンで、置いたものがあるとき)
    private var showsObjects: Bool {
        has(.objects) && !env.objects.visiblePlacements.isEmpty
    }

    /// 現在地(位置のデバッグの間は、仮想の位置)
    private var userPoint: GeoPoint? {
        env.movement.isVirtual ? env.movement.currentPoint : tracker.coordinate.map { GeoPoint($0) }
    }

    /// 太陽と月の1日分を作り直す目印(日付・約1kmの場所・稜線の計算の時刻)
    private var skyKey: String {
        guard has(.sunMoon), let point = userPoint else { return "off" }
        let day = Int(SkyEvents.startOfDay(skyDay).timeIntervalSince1970)
        let skyline = showsScenery ? env.scenery.scene?.computedAt.timeIntervalSince1970 ?? 0 : 0
        return "\(day)|\((point.latitude * 100).rounded())|\((point.longitude * 100).rounded())|\(Int(skyline))"
    }

    /// 太陽と月を描く時刻(時刻を選んでいなければ今。今日以外の日は、その日の今の時刻)
    private var skyDisplayTime: Date {
        if let skyTime { return skyTime }
        let now = Date()
        if Calendar.japan.isDate(skyDay, inSameDayAs: now) { return now }
        return SkyEvents.startOfDay(skyDay).addingTimeInterval(now.timeIntervalSince(SkyEvents.startOfDay(now)))
    }

    /// カメラ表示に重ねる景色とオブジェクト
    private var extras: ScopeExtras {
        var extras = ScopeExtras(scenery: sceneryScene, sceneryOptions: sceneryOptions)
        if has(.sunMoon), let skyScene { extras.sky = SkyRenderer.DrawInput(scene: skyScene, time: skyDisplayTime) }
        extras.onMountain = { mountainDetail = $0 }
        if showsObjects, let user = userPoint {
            // 位置のデバッグの間は、仮想の位置の地面 + 手の高さから見る
            let altitude = env.movement.isVirtual || !env.settings.scopeUsesHeight ? nil : observer?.meters
            extras.objects = ObjectDrawInput(items: env.objects.drawItems(), user: user, observerAltitude: altitude,
                                             handHeight: env.settings.scopeHandHeight)
            extras.onObject = { objectDetail = ObjectTap(id: $0) }
        }
        return extras
    }

    /// 景色を重ねるか(景色の表示がオンで、景色の中の層を1つ以上選んでいるとき)
    private var showsScenery: Bool {
        has(.scenery) && !env.settings.sceneryLayers.isEmpty
    }

    private var sceneryOptions: SceneryDrawOptions {
        SceneryDrawOptions(layers: Set(env.settings.sceneryLayers), showsHiddenMountains: env.settings.sceneryShowsHiddenMountains,
                           heightScale: env.settings.sceneryHeightScale)
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
        let kinds = markLayers
        if let attitude {
            let screen = CGRect(origin: .zero, size: viewSize)
            for target in targets {
                guard let point = WaypointProjection.point(bearing: target.bearing, elevation: target.elevationAngle, attitude: attitude,
                                                           tangents: tangents, viewSize: viewSize),
                      screen.contains(point) else { continue }
                inView.append(ScopeAskTarget(name: target.mark.name, kind: (kinds[target.id] ?? .places).kindName, bearing: target.bearing,
                                             distance: target.distance, heightDifference: target.heightDifference))
            }
        }
        let coordinate = tracker.coordinate
        env.scopeAsk.begin(ScopeAskSnapshot(
            image: image, heading: attitude?.azimuth, pitch: attitude?.elevation,
            latitude: coordinate?.latitude, longitude: coordinate?.longitude, placeName: nil,
            targets: inView, takenAt: Date(),
            // 答えの場所が写る範囲の中かを確かめるため(端末の中だけで使う)
            halfFieldOfView: atan(tangents.horizontal) * 180 / .pi))
        showsAsk = true
    }

    /// 方角のデバッグ表示: 画角の内訳と縦の目盛り、山の頂の仰角と画面での高さ(地平線から何 pt 上か)
    private func debugLines(attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> [String] {
        let camera = env.camera
        let perDegree = WaypointProjection.pointsPerDegree(tangents: tangents, viewSize: size)
        let corrected = camera.correctedFieldOfView.map { String(format: "%.1f°", $0) } ?? "なし"
        var lines = [
            String(format: "画角: 形式 %.1f°・歪み補正後 ", camera.formatFieldOfView) + corrected
                + String(format: "・ズーム %.2f → 計算 %.1f°(長辺)", camera.zoom, camera.fieldOfView),
            String(format: "映像 %.2f:1・画面 %.0f×%.0f・1°= 横 %.1fpt / 縦 %.1fpt", camera.videoAspect, size.width, size.height,
                   perDegree.horizontal, perDegree.vertical),
        ]
        guard showsScenery, let scene = env.scenery.scene else { return lines }
        let visible = scene.mountains.filter { !$0.isHidden }
        let scale = env.settings.sceneryHeightScale
        // 富士山(なければ、一番目立つ山)
        for mountain in [visible.first { $0.entry.name == "富士山" }, visible.first].compactMap({ $0 }).prefix(1) {
            var line = mountain.entry.shortName + String(format: " 仰角 %.2f°・方角 %.1f°・%@", mountain.angle, mountain.bearing,
                                                         SceneryText.distance(mountain.distance))
            if let top = WaypointProjection.point(bearing: mountain.bearing, elevation: mountain.angle * scale, attitude: attitude,
                                                  tangents: tangents, viewSize: size),
               let base = WaypointProjection.point(bearing: mountain.bearing, elevation: 0, attitude: attitude, tangents: tangents, viewSize: size) {
                line += String(format: "・画面で地平線から %.1fpt 上", base.y - top.y)
            } else {
                line += "・画面の外"
            }
            lines.append(line)
        }
        return lines
    }

    /// 方角の補正で合わせる目印(表示している印、景色の山、置いたオブジェクト)
    private var landmarks: [HeadingCorrection.Landmark] {
        var result = currentTargets.map { HeadingCorrection.Landmark(name: $0.mark.name, bearing: $0.bearing) }
        if showsScenery, let scene = env.scenery.scene {
            result += scene.mountains.filter { !$0.isHidden }.prefix(30).map {
                HeadingCorrection.Landmark(name: $0.entry.displayName, bearing: $0.bearing)
            }
        }
        if showsObjects, let user = userPoint {
            result += env.objects.visiblePlacements.map { placement in
                HeadingCorrection.Landmark(name: placement.name,
                                           bearing: WaypointMath.bearing(fromLatitude: user.latitude, longitude: user.longitude,
                                                                         toLatitude: placement.latitude, longitude: placement.longitude))
            }
        }
        return result
    }

    /// 電車の位置を計算する基準の現在地(位置のデバッグの間は、仮想の位置)
    private var trainUserPoint: GeoPoint? {
        env.movement.isVirtual ? env.movement.currentPoint : tracker.coordinate.map { GeoPoint($0) }
    }

    private var title: String {
        switch primaryLayer {
        case .places: return mode == .camera ? "カメラで見る" : "コンパス"
        case .nearby: return env.nearby.category?.label ?? "周辺"
        case .route: return "経路の案内"
        case .trains: return mode == .camera ? "電車をカメラで見る" : "電車のコンパス"
        case .scenery: return mode == .camera ? "景色をカメラで見る" : "景色のコンパス"
        case .objects: return mode == .camera ? "オブジェクトをカメラで見る" : "オブジェクトのコンパス"
        case .sunMoon: return mode == .camera ? "太陽と月をカメラで見る" : "太陽と月のコンパス"
        }
    }

    /// 表示する印(重ねる表示ごと)。地点・周辺の施設・経路(次の曲がり角と目的地)は、どれも同じ形にそろえる。
    /// 電車・景色の山・オブジェクトは、カメラ表示ではそれぞれの描き方で描くので、印はコンパス表示のときだけ
    private var layeredMarks: [(layer: ScopeLayer, mark: ScopeMark)] {
        var result: [(layer: ScopeLayer, mark: ScopeMark)] = []
        for layer in ScopeLayer.sorted(layers) {
            result += marks(for: layer).map { (layer: layer, mark: $0) }
        }
        return result
    }

    private func marks(for layer: ScopeLayer) -> [ScopeMark] {
        switch layer {
        case .places:
            // すべて: 表示中の地点だけ。選んだ1つ: 非表示の地点でも出す。
            guard let selectedPlaceID else { return env.waypoints.visibleWaypoints.map { ScopeMark($0) } }
            return env.waypoints.waypoints.filter { $0.id == selectedPlaceID }.map { ScopeMark($0) }
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
            guard mode == .compass, showsScenery, let scene = env.scenery.scene else { return [] }
            return scene.mountains.filter { env.settings.sceneryShowsHiddenMountains || !$0.isHidden }.prefix(12).map { mountain in
                var mark = ScopeMark(id: "mountain.\(mountain.id)", name: mountain.entry.displayName, latitude: mountain.entry.latitude,
                                     longitude: mountain.entry.longitude, color: .brown, altitude: mountain.entry.elevation)
                mark.note = mountain.isHidden ? "手前の地形に隠れて見えない" : SceneryText.elevation(mountain.entry.elevation)
                return mark
            }
        case .objects:
            // カメラ表示では立体で描くので、印はコンパス表示のときだけ
            guard mode == .compass else { return [] }
            return env.objects.drawItems().map { item in
                let placement = item.placement
                let ground = placement.groundElevation
                return ScopeMark(id: "object.\(placement.id.uuidString)", name: placement.name, latitude: placement.latitude,
                                 longitude: placement.longitude, color: ObjectColor.color(item.object.shapes.first?.color ?? ObjectShape.defaultColor),
                                 altitude: ground.map { $0 + placement.heightAboveGround + item.height * placement.scale / 2 })
            }
        case .sunMoon:
            // 太陽と月は、カメラ表示で専用の描き方で描く(地上の地点ではないので、印にしない)
            return []
        }
    }

    /// 自分の高さ(設定で選んだ方法。地面の標高が取れないときはGPSの高度)
    private var observer: ObserverHeight? {
        guard let coordinate = tracker.coordinate else { return nil }
        return env.elevation.observerHeight(latitude: coordinate.latitude, longitude: coordinate.longitude, gpsAltitude: tracker.gpsAltitude)
    }

    /// 印の対象(遠い順)。カメラ表示では電車を含めない(電車は車両の箱で描く)
    private var currentTargets: [ScopeTarget] {
        let entries = layeredMarks
        var result: [ScopeTarget] = []
        let others = entries.filter { $0.layer != .trains }.map { $0.mark }
        if let coordinate = tracker.coordinate, !others.isEmpty {
            result += ScopeTarget.make(others, latitude: coordinate.latitude, longitude: coordinate.longitude,
                                       observerAltitude: observer?.meters, usesHeight: env.settings.scopeUsesHeight)
        }
        // コンパス表示の電車の印は、方角だけを出す(高さは印の文字で出す)。位置のデバッグの間は、仮想の位置から測る
        if mode == .compass, let point = trainUserPoint {
            let trains = entries.filter { $0.layer == .trains }.map { $0.mark }
            if !trains.isEmpty { result += ScopeTarget.make(trains, latitude: point.latitude, longitude: point.longitude) }
        }
        return result.sorted { $0.distance > $1.distance }
    }

    /// カメラ・GPS・モーションは、この画面を表示している間だけ動かす。表示中は画面を消さない。
    private func startAll() {
        let camera = env.camera
        ScreenAwake.set("scope", true)
        tracker.holdsHeadingWithGyro = env.settings.headingGyroHold
        // 位置とモーションは、カメラの準備を待たずに始める(カメラの設定と開始は専用のキューで進む)
        tracker.start(includesMotion: mode == .camera)
        if has(.trains), !trainFeed.isRunning {
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
        if !has(.trains), trainFeed.isRunning {
            trainFeed.stop(env: env)
        }
        if showsObjects, env.movement.isVirtual { env.movement.setVisible(true) }
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
        if env.movement.isVirtual, wasTrains || showsScenery || showsObjects { env.movement.setVisible(false) }
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
                    if has(.trains) {
                        // 電車(と景色・オブジェクト)を下に、印を上に重ねる。タップは電車 → オブジェクト → 山
                        ScopeTrainOverlay(feed: trainFeed, attitude: attitude, tangents: tangents, extras: extras) { id in
                            trainDetail = ScopeTrainDetailSheet.Target(selection: .train(id))
                        }
                        ScopeOverlay(targets: targets, attitude: attitude, tangents: tangents)
                    } else {
                        ScopeOverlay(targets: targets, attitude: attitude, tangents: tangents, extras: extras)
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
                    if showsCorrection, !env.settings.headingDebugEnabled {
                        // 方角の補正: 目印を合わせる、画面の中央の十字
                        Image(systemName: "plus")
                            .font(.system(size: 44, weight: .thin))
                            .foregroundStyle(.yellow)
                            .shadow(color: .black, radius: 1)
                            .allowsHitTesting(false)
                    }
                    // 今オンになっている表示(タップでその表示だけをオフ)
                    VStack {
                        HStack {
                            ScopeActiveLayerIcons(layers: ScopeLayer.sorted(layers)) { layer in _ = env.settings.scopeLayers.remove(layer) }
                            Spacer(minLength: 0)
                        }
                        Spacer()
                    }
                    .padding(8)
                    VStack(alignment: .trailing, spacing: 6) {
                        if env.objectCompose.isCollectingPhotos, !showsAsk, !showsPhotoComposer {
                            // オブジェクトの写真を撮り足している間(撮って聞くで撮り、囲んで「オブジェクトを作る」)
                            ObjectPhotoCollectingBanner(count: env.objectCompose.photos.count) {
                                showsPhotoComposer = true
                            } onCancel: {
                                env.objectCompose.isCollectingPhotos = false
                            }
                        }
                        if !showsAsk, env.scopeAsk.isThinking || env.scopeAsk.hasUnseenAnswer {
                            ClaudeWorkBanner(isRunning: env.scopeAsk.isThinking, hasResult: env.scopeAsk.hasUnseenAnswer,
                                             runningText: "撮って聞く: 答えを待っています…", doneText: "撮って聞く: 答えが届きました(確認する)") {
                                showsAsk = true
                            }
                        }
                        HeadingCorrectionBadge(offset: env.settings.headingOffset)
                        if has(.sunMoon), skyTime != nil || !Calendar.japan.isDate(skyDay, inSameDayAs: Date()) {
                            Button {
                                showsSkyPanel = true
                            } label: {
                                Text("\(SkyText.dateTime(skyDisplayTime)) の空")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(8)
                    if env.settings.headingDebugEnabled {
                        // 東西南北の印と水平線を、地点と同じ投影でそのまま描く(実際の方角と重なるかを見る)
                        ScopeCompassRoseOverlay(attitude: attitude, tangents: tangents)
                        VStack {
                            HStack {
                                ScopeHeadingDebugView(tracker: tracker, attitude: attitude, viewSize: size, targets: targets,
                                                      extraLines: debugLines(attitude: attitude, tangents: tangents, size: size))
                                Spacer(minLength: 0)
                            }
                            Spacer()
                        }
                        .padding(.top, 50)
                        .padding(.horizontal, 8)
                    }
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
                    HeadingCorrectionBadge(offset: env.settings.headingOffset)
                    if env.settings.waypointShowsHeading {
                        Text("\(WaypointMath.compassPoint(heading)) \(Int(heading.rounded()))°")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                    }
                    ScopeCompassDial(heading: heading, targets: targets)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 360)
                        .padding(.horizontal)
                    let kinds = markLayers
                    ForEach(Array(targets.reversed().prefix(has(.trains) ? 40 : 12))) { target in
                        if kinds[target.id] == .trains {
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

    /// 太陽と月の1行(日の出・日の入り、月の満ち欠け)
    private func skySummary(_ scene: SkyScene) -> String {
        var parts: [String] = []
        if let rise = scene.sunriseText() { parts.append(rise) }
        if let set = scene.sunsetText() { parts.append(set) }
        parts.append("月 \(Int((Astronomy.moonPhase(skyDisplayTime).illumination * 100).rounded()))%")
        if !scene.hasTerrain { parts.append("稜線なし(地平線での時刻)") }
        return "太陽と月: " + parts.joined(separator: "・")
    }

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
            if has(.places) || has(.scenery) {
                Text(observerText)
            }
            if has(.sunMoon), let skyScene {
                Text(skySummary(skyScene))
            }
            if has(.trains) {
                if env.movement.isVirtual {
                    Text("デバッグ中(仮想の位置と時刻)").foregroundStyle(.red)
                }
                Text(trainStatusText)
            } else if (showsScenery || showsObjects), env.movement.isVirtual {
                Text("デバッグ中(景色とオブジェクトは仮想の位置から)").foregroundStyle(.red)
            }
            if showsObjects {
                Text("オブジェクト \(env.objects.visiblePlacements.count)個(タップで情報)")
            }
            if showsScenery {
                Text(sceneryStatusText)
            }
            if tracker.usesMagneticNorth, mode == .camera {
                Text("真北が使えないため、磁北を基準にしています(数度ずれます)")
            }
            if let warning = ScopeLocationCheck.warning(accuracy: tracker.horizontalAccuracy, isReduced: tracker.isReducedAccuracy,
                                                         nearest: currentTargets.last?.distance) {
                Text(warning).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
    /// 景色とオブジェクト(同じ Canvas に、印より先に描く)
    var extras = ScopeExtras()

    var body: some View {
        GeometryReader { geometry in
            Canvas(rendersAsynchronously: false) { context, size in
                extras.draw(&context, attitude: attitude, tangents: tangents, size: size)
                for target in targets {
                    guard let point = WaypointProjection.point(bearing: target.bearing, elevation: target.elevationAngle, attitude: attitude,
                                                               tangents: tangents, viewSize: size) else { continue }
                    Self.drawMark(&context, at: point, target: target)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                extras.tap(value.location, attitude: attitude, tangents: tangents, size: geometry.size)
            })
            .allowsHitTesting(extras.isTappable)
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

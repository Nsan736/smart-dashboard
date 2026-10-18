import SwiftUI

enum SceneryAttribution {
    static var text: String {
        let catalog = MountainCatalog.bundled
        let version = catalog.version.isEmpty ? "" : "(\(catalog.version)版)"
        return "景色: 国土地理院の地理院タイル(標高タイル)、国土地理院ベクトルタイル提供実験(水部・注記)、「日本の主な山岳標高」\(version)を加工して作成。"
            + "稜線・見えるかどうか・水面の方角は、標高タイルから計算した目安です。"
    }
}

/// 層の切り替え(設定に保存し、景色の計算をやり直す)
struct SceneryLayerToggles: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ForEach(SceneryLayer.allCases) { layer in
            Toggle(isOn: Binding(
                get: { env.settings.sceneryLayers.contains(layer) },
                set: { on in
                    var layers = env.settings.sceneryLayers.filter { $0 != layer }
                    if on { layers.append(layer) }
                    env.settings.sceneryLayers = SceneryLayer.allCases.filter { layers.contains($0) }
                    env.scenery.settingsChanged()
                }
            )) {
                Label(layer.label, systemImage: layer.symbol)
            }
        }
    }
}

/// スコープの「景色」: 層の切り替え、範囲、計算の状態、見える山と水面の一覧。カメラ表示はここから開く。
struct SceneryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var located: (latitude: Double, longitude: Double)?
    @State private var locationError: String?
    @State private var detail: SceneryMountain?
    @State private var confirmDelete = false
    /// 150km 以上に広げる前の確認
    @State private var pendingRadius: Int?

    var body: some View {
        @Bindable var settings = env.settings
        let scenery = env.scenery
        List {
            Section {
                NavigationLink {
                    ScopeSightView(mode: .camera, source: .scenery)
                } label: {
                    Label("カメラで見る", systemImage: "camera.viewfinder")
                }
                NavigationLink {
                    ScopeSightView(mode: .compass, source: .scenery)
                } label: {
                    Label("コンパスで見る", systemImage: "safari")
                }
            }
            Section {
                SceneryLayerToggles()
                Toggle("地点・周辺・経路・電車にも重ねる", isOn: $settings.sceneryOverlaysOthers)
            } header: {
                Text("表示する層")
            } footer: {
                Text("選んだ層は、景色のカメラ表示のほか、地点・周辺・経路・電車のカメラ表示にも重ねます(切り替えでオフにできます)。")
            }
            Section {
                Picker("範囲", selection: Binding(get: { settings.sceneryRadiusKm }, set: { new in
                    // 150km 以上に広げるときは、保存するデータ量の目安を出して確かめる
                    if new >= SceneryRadius.confirmFrom, new > settings.sceneryRadiusKm {
                        pendingRadius = new
                    } else {
                        settings.sceneryRadiusKm = new
                        scenery.settingsChanged()
                    }
                })) {
                    ForEach(SceneryRadius.choices, id: \.self) { km in
                        Text(estimateText(km).map { "\(km)km(\($0))" } ?? "\(km)km").tag(km)
                    }
                }
                LabeledContent("いま保存してある量", value: ByteCountFormatter.string(fromByteCount: scenery.storedBytes, countStyle: .file))
                Toggle("隠れた山も薄く表示する", isOn: $settings.sceneryShowsHiddenMountains)
            } header: {
                Text("山と稜線")
            } footer: {
                Text("山は国土地理院の「日本の主な山岳標高」の\(scenery.catalog.entries.count)山から、範囲の中のものを出します(広い範囲では、高い山・近い山を優先して文字を出します)。稜線は、範囲の中の標高タイルから0.5°ごとに計算します。遠い所ほど粗いタイル(100kmまで約250m、200kmまで約500m、それより遠くは約1km)を使い、山頂の高さは山の一覧の標高で補います。かっこの中は、今いる場所でその範囲に保存するデータ量の目安です(保存済みの分は取り直しません)。海・湖・川と地名は100kmまでです。")
            }
            statusSection(scenery)
            if let scene = scenery.scene {
                mountainSection(scene)
                if !scene.water.isEmpty {
                    Section("見える水面") {
                        ForEach(Array(scene.water.enumerated()), id: \.offset) { item in
                            let band = item.element
                            HStack {
                                Image(systemName: "water.waves").foregroundStyle(SceneryRenderer.waterColor)
                                Text(band.name)
                                Spacer()
                                Text("\(WaypointMath.compassPoint(band.centerBearing)) \(SceneryText.distance(band.distance))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            Section {
                Text(SceneryAttribution.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("国土地理院 日本の主な山岳標高", destination: URL(string: "https://www.gsi.go.jp/kihonjohochousa/kihonjohochousa41139.html")!)
                    .font(.footnote)
                Link("地理院タイル・ベクトルタイル", destination: URL(string: "https://maps.gsi.go.jp/development/ichiran.html")!)
                    .font(.footnote)
            } header: {
                Text("出典")
            }
        }
        .sheet(item: $detail) { SceneryMountainSheet(mountain: $0) }
        .alert("範囲を\(pendingRadius ?? 0)kmに広げますか", isPresented: Binding(get: { pendingRadius != nil }, set: { if !$0 { pendingRadius = nil } })) {
            Button("広げる") {
                if let radius = pendingRadius {
                    settings.sceneryRadiusKm = radius
                    scenery.settingsChanged()
                }
                pendingRadius = nil
            }
            Button("やめる", role: .cancel) { pendingRadius = nil }
        } message: {
            Text("この場所で、地形のデータを合わせて\(pendingRadius.flatMap(estimateText) ?? "数MB")ほど保存します(いま保存してある量: \(ByteCountFormatter.string(fromByteCount: scenery.storedBytes, countStyle: .file)))。保存は Wi-Fi など従量制でない回線のときだけ行い、地図タイルと合わせた保存の上限を超えたら止めます。")
        }
        .confirmationDialog("景色のデータを削除しますか", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await scenery.removeAll() } }
        } message: {
            Text("保存した標高タイルと水部のデータを削除します。次に Wi-Fi などで景色を開いたときに、取り直します。")
        }
        .task { await locate() }
        .onAppear { scenery.setActive(true, reason: "scope.list") }
        .onDisappear { scenery.setActive(false, reason: "scope.list") }
        .refreshable { await locate() }
    }

    @ViewBuilder
    private func statusSection(_ scenery: SceneryStore) -> some View {
        Section {
            if env.movement.isVirtual {
                Text("デバッグ中: 仮想の位置で計算しています").foregroundStyle(.red)
            }
            if let locationError {
                Text(locationError).foregroundStyle(.orange)
            } else if located == nil {
                Text("現在地を取得中…").foregroundStyle(.secondary)
            }
            if scenery.isComputing {
                Label("計算中…", systemImage: "hourglass")
            } else if let scene = scenery.scene {
                LabeledContent("地形のデータ", value: "\(Int((scene.coverage * 100).rounded()))%の方角で範囲まで")
                LabeledContent("自分の目の高さ", value: "標高 \(Int(scene.eye.rounded()))m")
            }
            if scenery.isDownloading {
                LabeledContent("地形を保存中", value: "\(scenery.finishedCount) / \(scenery.plannedCount)")
            } else if scenery.waitingCount > 0 {
                LabeledContent("まだ保存していないタイル", value: "\(scenery.waitingCount)枚")
            }
            if let note = scenery.note {
                Text(note).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("保存した景色のデータ", value: ByteCountFormatter.string(fromByteCount: scenery.storedBytes, countStyle: .file))
            Button("景色のデータを削除", role: .destructive) { confirmDelete = true }
                .disabled(scenery.storedBytes == 0)
        } header: {
            Text("状態")
        } footer: {
            Text("地形は Wi-Fi など従量制でない回線のときだけ、この画面とカメラ表示を開いている間に保存します(地図タイルと合わせて、地図の設定の保存の上限まで)。モバイル通信では、保存済みの範囲だけで計算します。")
        }
    }

    @ViewBuilder
    private func mountainSection(_ scene: SceneryScene) -> some View {
        let list = scene.mountains.sorted { $0.distance < $1.distance }
        Section {
            if list.isEmpty {
                Text("範囲の中に山はありません(範囲を広げると増えます)").foregroundStyle(.secondary)
            }
            ForEach(list.prefix(40)) { mountain in
                Button {
                    detail = mountain
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mountain.2.fill").foregroundStyle(mountain.isHidden ? Color.secondary : Color.brown)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mountain.entry.displayName).foregroundStyle(Color.primary)
                            Text("\(SceneryText.elevation(mountain.entry.elevation))・\(WaypointMath.compassPoint(mountain.bearing)) \(SceneryText.distance(mountain.distance))"
                                 + (mountain.isHidden ? "・手前の地形に隠れて見えない" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("範囲の山(\(list.count)、近い順)")
        }
    }

    /// その範囲に保存するデータ量の目安(今いる場所。分からなければ nil)
    private func estimateText(_ km: Int) -> String? {
        guard let point = located.map({ (latitude: $0.latitude, longitude: $0.longitude) }) ?? env.scenery.lastLocation else { return nil }
        let bytes = SceneryTileStore.estimatedBytes(latitude: point.latitude, longitude: point.longitude, radius: Double(km) * 1000)
        return "約" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func locate() async {
        if env.movement.isVirtual, let point = env.movement.currentPoint {
            located = (point.latitude, point.longitude)
            env.scenery.update(latitude: point.latitude, longitude: point.longitude, observerAltitude: nil)
            return
        }
        do {
            let location = try await env.location.currentLocation()
            let coordinate = location.coordinate
            located = (coordinate.latitude, coordinate.longitude)
            locationError = nil
            let gps: Double? = location.verticalAccuracy > 0 ? location.altitude : nil
            let height = env.elevation.observerHeight(latitude: coordinate.latitude, longitude: coordinate.longitude, gpsAltitude: gps)
            env.scenery.update(latitude: coordinate.latitude, longitude: coordinate.longitude, observerAltitude: height?.meters)
        } catch {
            locationError = (error as? LocalizedError)?.errorDescription ?? "現在地を取得できませんでした"
        }
    }
}

/// 山の詳細。地点に登録できる(標高は山岳標高の値を手入力として入れるので、標高APIは呼ばない)
struct SceneryMountainSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let mountain: SceneryMountain
    @State private var registered = false

    var body: some View {
        let entry = mountain.entry
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.displayName).font(.title2.weight(.bold))
                        Text(SceneryText.elevation(entry.elevation)).font(.title.weight(.semibold)).monospacedDigit()
                    }
                    LabeledContent("距離", value: SceneryText.distance(mountain.distance))
                    LabeledContent("方角", value: "\(WaypointMath.compassPoint(mountain.bearing)) \(Int(mountain.bearing.rounded()))°")
                    LabeledContent("見上げる角度", value: String(format: "%.1f°", mountain.angle))
                    LabeledContent("見えるか", value: visibilityText)
                    if !entry.prefecture.isEmpty { LabeledContent("所在地", value: entry.prefecture) }
                }
                Section {
                    Button {
                        register()
                    } label: {
                        Label(registered || isRegistered ? "地点に登録済み" : "地点に登録", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(registered || isRegistered)
                } footer: {
                    Text("標高は「日本の主な山岳標高」の値を入れます。")
                }
                Section {
                    Text(SceneryAttribution.text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("山")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var visibilityText: String {
        switch mountain.visibility {
        case .visible: return "見える(地形から計算した目安)"
        case .hidden: return "手前の地形に隠れて見えない(目安)"
        case .unknown: return "地形のデータがなく分からない"
        }
    }

    /// 同じ名前で、100m以内の地点があれば登録済み
    private var isRegistered: Bool {
        env.waypoints.waypoints.contains {
            $0.name == mountain.entry.displayName
                && WaypointMath.distance(fromLatitude: $0.latitude, longitude: $0.longitude,
                                         toLatitude: mountain.entry.latitude, longitude: mountain.entry.longitude) < 100
        }
    }

    private func register() {
        let entry = mountain.entry
        let store = env.waypoints
        let memo = "国土地理院「日本の主な山岳標高」" + (env.scenery.catalog.version.isEmpty ? "" : "(\(env.scenery.catalog.version)版)")
        store.add(Waypoint(name: entry.displayName, latitude: entry.latitude, longitude: entry.longitude,
                           colorIndex: store.waypoints.count % WaypointPalette.colors.count, memo: memo,
                           groundElevation: entry.elevation, elevationState: .manual))
        registered = true
    }
}

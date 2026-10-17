import CoreLocation
import SwiftUI

/// スコープの「地点」。登録した地点の一覧と登録。
struct WaypointListView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding private var section: ScopeSection
    @State private var editing: Waypoint?
    @State private var isAddingNew = false
    @State private var pendingDelete: Waypoint?
    @State private var isLocating = false
    @State private var message: String?
    @State private var editMode: EditMode = .inactive
    @AppStorage("waypoint.listFilter") private var filterRaw = WaypointListFilter.all.rawValue

    init(section: Binding<ScopeSection>) {
        _section = section
    }

    var body: some View {
        let store = env.waypoints
        Group {
            List {
                Section {
                    NavigationLink {
                        ScopeSightView(mode: .camera, source: .places(selectedID: nil))
                    } label: {
                        Label("カメラで見る", systemImage: "camera.viewfinder")
                    }
                    NavigationLink {
                        ScopeSightView(mode: .compass, source: .places(selectedID: nil))
                    } label: {
                        Label("コンパスで見る", systemImage: "safari")
                    }
                } footer: {
                    Text("カメラ・GPS・方位のセンサーは、表示している間だけ動かします。表示中の地点だけを出します。自分の高さを「地面の標高+手の高さ」にしているときは、100m以上動いたときだけ標高を取得します(1回約70バイト)。")
                }
                .disabled(store.waypoints.isEmpty)

                Section {
                    Button {
                        Task { await saveHere() }
                    } label: {
                        Label(isLocating ? "現在地を取得中…" : "ここを保存(現在地)", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(isLocating)
                    NavigationLink {
                        WaypointMapPicker()
                    } label: {
                        Label("地図を長押しして登録", systemImage: "map")
                    }
                    Button {
                        isAddingNew = true
                    } label: {
                        Label("緯度経度を入力して登録", systemImage: "number")
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("登録")
                }

                Section {
                    if store.waypoints.isEmpty {
                        Text("まだ登録がありません").foregroundStyle(.secondary)
                    } else {
                        // 表示・非表示の一括切り替えと、絞り込み
                        Picker("一覧に出す地点", selection: $filterRaw) {
                            ForEach(WaypointListFilter.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Button {
                                store.setAllHidden(false)
                            } label: {
                                Label("すべて表示", systemImage: "eye")
                            }
                            .disabled(!store.waypoints.contains { $0.isHidden })
                            Spacer(minLength: 8)
                            Button {
                                store.setAllHidden(true)
                            } label: {
                                Label("すべて非表示", systemImage: "eye.slash")
                            }
                            .disabled(store.waypoints.allSatisfy(\.isHidden))
                        }
                        .buttonStyle(.borderless)
                    }
                    let shown = WaypointListFilter.apply(store.waypoints, filter: filter)
                    if !store.waypoints.isEmpty, shown.isEmpty {
                        Text("表示中の地点はありません(「すべて」で非表示の地点も出ます)").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { waypoint in
                        row(waypoint)
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    .moveDisabled(filter != .all)
                } header: {
                    Text("登録した地点")
                } footer: {
                    if let origin = store.origin {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text("距離と方角は、\(Formatters.ageLabel(origin.time, now: context.date))の現在地からの値です。")
                        }
                    } else {
                        Text("現在地が分かると、距離と方角を表示します。")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editMode == .active ? "完了" : "並べ替え") {
                        editMode = editMode == .active ? .inactive : .active
                    }
                    .disabled(store.waypoints.count < 2)
                }
            }
            .sheet(item: $editing) { waypoint in
                WaypointEditor(waypoint: waypoint, isNew: false) { store.update($0) }
            }
            .sheet(isPresented: $isAddingNew) {
                WaypointEditor(waypoint: Waypoint(name: "", latitude: 0, longitude: 0, colorIndex: store.waypoints.count % WaypointPalette.colors.count),
                               isNew: true) { store.add($0) }
            }
            .confirmationDialog("この地点を削除しますか", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { waypoint in
                Button("削除", role: .destructive) { store.delete(id: waypoint.id) }
            } message: { waypoint in
                Text(waypoint.name)
            }
            .task {
                await refreshOrigin()
                // 標高が未設定の地点(以前の版で保存した地点など)は、Wi-Fi接続中に自動で取得する
                await env.elevation.fillMissing()
            }
        }
    }

    private var filter: WaypointListFilter {
        WaypointListFilter(rawValue: filterRaw) ?? .all
    }

    private func row(_ waypoint: Waypoint) -> some View {
        let store = env.waypoints
        return HStack(spacing: 10) {
            Circle().fill(WaypointPalette.color(waypoint.colorIndex)).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(waypoint.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if waypoint.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                    if waypoint.isHidden { Text("非表示").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                }
                if let origin = store.origin {
                    let summary = WaypointMath.summary(
                        bearing: WaypointMath.bearing(fromLatitude: origin.latitude, longitude: origin.longitude,
                                                      toLatitude: waypoint.latitude, longitude: waypoint.longitude),
                        distance: WaypointMath.distance(fromLatitude: origin.latitude, longitude: origin.longitude,
                                                        toLatitude: waypoint.latitude, longitude: waypoint.longitude))
                    let difference = WaypointHeightText.difference(waypoint: waypoint, observerHeight: origin.height)
                    Text(difference.map { "\(summary) \($0)" } ?? summary)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Text(WaypointHeightText.summary(waypoint, isFetching: env.elevation.fetching.contains(waypoint.id)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !waypoint.memo.isEmpty {
                    Text(waypoint.memo).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(waypoint.isHidden ? 0.45 : 1)
            Spacer(minLength: 4)
            if editMode != .active {
                Button {
                    store.setHidden(id: waypoint.id, !waypoint.isHidden)
                } label: {
                    Image(systemName: waypoint.isHidden ? "eye.slash" : "eye")
                        .foregroundStyle(waypoint.isHidden ? Color.secondary : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(waypoint.isHidden ? "表示する" : "非表示にする")
                Button {
                    env.route.setDestination(ScopeDestination(name: waypoint.name, latitude: waypoint.latitude, longitude: waypoint.longitude))
                    section = .route
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("ここへの経路")
                Button {
                    store.togglePin(id: waypoint.id)
                } label: {
                    Image(systemName: waypoint.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(waypoint.isPinned ? "ピン留めを外す" : "ホームにピン留め")
                Button {
                    editing = waypoint
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("編集")
                Button(role: .destructive) {
                    pendingDelete = waypoint
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("削除")
            }
        }
    }

    /// 一覧の距離の表示用に、現在地を1回だけ取得する(取得したら測位は止まる)
    private func refreshOrigin() async {
        guard !env.waypoints.waypoints.isEmpty, let location = try? await env.location.currentLocation() else { return }
        let coordinate = location.coordinate
        if env.settings.scopeHeightSource == .groundPlusHand {
            env.elevation.updateGround(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        let gps: Double? = location.verticalAccuracy > 0 ? location.altitude : nil
        let height = env.elevation.observerHeight(latitude: coordinate.latitude, longitude: coordinate.longitude, gpsAltitude: gps)
        env.waypoints.setOrigin(latitude: coordinate.latitude, longitude: coordinate.longitude, height: height?.meters)
    }

    private func saveHere() async {
        isLocating = true
        defer { isLocating = false }
        do {
            let location = try await env.location.currentLocation()
            let store = env.waypoints
            store.setOrigin(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            let waypoint = Waypoint(name: "地点 \(store.waypoints.count + 1)", latitude: location.coordinate.latitude,
                                    longitude: location.coordinate.longitude,
                                    colorIndex: store.waypoints.count % WaypointPalette.colors.count)
            store.add(waypoint)
            message = "現在地を保存しました(位置の精度 ±\(Int(location.horizontalAccuracy.rounded()))m)。名前や位置は編集で直せます。"
            editing = waypoint
        } catch {
            message = error.localizedDescription
        }
    }
}

/// 地点の高さの表示
enum WaypointHeightText {
    /// 「標高 18m + 地面から250m = 268m」「標高 未設定」
    static func summary(_ waypoint: Waypoint, isFetching: Bool = false) -> String {
        guard let elevation = waypoint.groundElevation else {
            if isFetching { return "標高: 取得中" }
            switch waypoint.elevationState {
            case .noData: return "標高: 未設定(この場所の標高のデータはありません。編集で入力できます)"
            default: return "標高: 未設定(Wi-Fi接続中に自動で取得します)"
            }
        }
        var text = "標高 \(meters(elevation))"
        if waypoint.heightAboveGround != 0 {
            text += " + 地面から\(meters(waypoint.heightAboveGround)) = \(meters(elevation + waypoint.heightAboveGround))"
        }
        if waypoint.elevationState == .manual { text += "(手入力)" }
        return text
    }

    /// 自分との高低差「↑120m」。どちらかが分からなければ nil。
    static func difference(waypoint: Waypoint, observerHeight: Double?) -> String? {
        guard let altitude = waypoint.altitude, let observerHeight else { return nil }
        return WaypointMath.heightText(altitude - observerHeight)
    }

    static func meters(_ value: Double) -> String {
        abs(value) >= 100 ? "\(Int(value.rounded()))m" : String(format: "%.1fm", value)
    }

    /// 入力欄の文字を数にする(全角の数字・マイナスも受ける)。空なら nil。
    static func parse(_ text: String) -> Double? {
        var cleaned = ""
        for character in text.trimmingCharacters(in: .whitespaces) {
            switch character {
            case "０"..."９": if let value = character.wholeNumberValue { cleaned.append(String(value)) }
            case "．": cleaned.append(".")
            case "−", "－", "ー": cleaned.append("-")
            default: cleaned.append(character)
            }
        }
        return Double(cleaned)
    }
}

/// 名前・色・メモ・座標・高さの編集
struct WaypointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var env
    @State var waypoint: Waypoint
    let isNew: Bool
    let onSave: (Waypoint) -> Void
    @State private var coordinateText = ""
    @State private var didLoad = false
    @State private var elevationText = ""
    @State private var heightText = ""
    @State private var isFetchingElevation = false
    @State private var elevationMessage: String?

    var body: some View {
        let parsed = WaypointCoordinateParser.parse(coordinateText)
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("名前", text: $waypoint.name)
                }
                Section {
                    HStack {
                        TextField("35.68, 139.76", text: $coordinateText)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("貼り付け") {
                            if let text = UIPasteboard.general.string { coordinateText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .buttonStyle(.borderless)
                    }
                    if let parsed {
                        Text(String(format: "緯度 %.6f、経度 %.6f", parsed.latitude, parsed.longitude)).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("「緯度, 経度」の形で入力してください(地図アプリからコピーした座標を貼り付けられます)")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("緯度, 経度")
                }
                Section("色") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 10)], spacing: 10) {
                        ForEach(WaypointPalette.colors.indices, id: \.self) { index in
                            Circle()
                                .fill(WaypointPalette.colors[index])
                                .frame(width: 34, height: 34)
                                .overlay { Circle().strokeBorder(Color.primary, lineWidth: waypoint.colorIndex == index ? 3 : 0) }
                                .onTapGesture { waypoint.colorIndex = index }
                                .accessibilityLabel(WaypointPalette.names[index])
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    HStack {
                        Text("標高")
                        TextField("未設定", text: Binding(get: { elevationText }, set: { text in
                            // 手で入力したら「手入力」にする(再取得で入れた値は「取得」のまま)
                            elevationText = text
                            waypoint.elevationState = WaypointHeightText.parse(text) == nil ? .unset : .manual
                        }))
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing)
                        Text("m").foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await refetchElevation(parsed) }
                    } label: {
                        Label(isFetchingElevation ? "取得中…" : "標高を取得し直す(国土地理院)", systemImage: "arrow.clockwise")
                    }
                    .disabled(parsed == nil || isFetchingElevation)
                    if let elevationMessage {
                        Text(elevationMessage).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("地面からの高さ")
                        TextField("0", text: $heightText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                        Text("m").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("高さ")
                } footer: {
                    Text("地点の高さ = 標高 + 地面からの高さ(タワーの展望台なら、地面から250mなど)。カメラ表示で、印の上下の位置と高低差に使います。標高は登録したときに国土地理院の標高APIで自動で取得します(海上など、データがない場所は未設定)。")
                }
                Section("メモ") {
                    TextField("メモ", text: $waypoint.memo, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .keyboardDismissable()
            .navigationTitle(isNew ? "地点を登録" : "地点を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let parsed else { return }
                        var result = waypoint
                        result.latitude = parsed.latitude
                        result.longitude = parsed.longitude
                        let elevation = WaypointHeightText.parse(elevationText)
                        result.groundElevation = elevation
                        if elevation == nil, result.elevationState != .noData { result.elevationState = .unset }
                        result.heightAboveGround = WaypointHeightText.parse(heightText) ?? 0
                        if result.name.trimmingCharacters(in: .whitespaces).isEmpty { result.name = "名前のない地点" }
                        onSave(result)
                        dismiss()
                    }
                    .disabled(parsed == nil)
                }
            }
            .onAppear {
                guard !didLoad else { return }
                didLoad = true
                // 座標が決まっている(現在地、地図の長押し、編集)ときは、欄に入れておく
                if waypoint.latitude != 0 || waypoint.longitude != 0 {
                    coordinateText = String(format: "%.6f, %.6f", waypoint.latitude, waypoint.longitude)
                }
                elevationText = waypoint.groundElevation.map { String(format: "%.1f", $0) } ?? ""
                heightText = waypoint.heightAboveGround == 0 ? "" : String(format: "%.1f", waypoint.heightAboveGround)
                if waypoint.elevationState == .noData { elevationMessage = "この場所の標高のデータはありません(海上など)。手で入力できます。" }
            }
        }
    }
}

extension WaypointEditor {
    /// 入力欄の座標で、標高を取得し直す
    private func refetchElevation(_ coordinate: (latitude: Double, longitude: Double)?) async {
        guard let coordinate else { return }
        isFetchingElevation = true
        defer { isFetchingElevation = false }
        switch await env.elevation.lookup(latitude: coordinate.latitude, longitude: coordinate.longitude) {
        case .value(let value):
            elevationText = String(format: "%.1f", value)
            waypoint.elevationState = .fetched
            elevationMessage = nil
        case .noData:
            elevationText = ""
            waypoint.elevationState = .noData
            elevationMessage = "この場所の標高のデータはありません(海上など)。手で入力できます。"
        case .failed(let text):
            elevationMessage = text
        }
    }
}

/// 地図を長押しした位置を登録する。地図は既存の仕組み(Wi-Fiでは Apple Maps、モバイル通信では保存済みの地理院タイル)。
struct WaypointMapPicker: View {
    @Environment(AppEnvironment.self) private var env
    @State private var picked: Waypoint?

    var body: some View {
        let store = env.waypoints
        let center = store.origin.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        MapContainerView(center: center, spanMeters: 3000, isInteractive: true, showsUserLocation: true,
                         markers: store.visibleWaypoints.map {
                             MapMarker(id: $0.id.uuidString, title: $0.name,
                                       coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), style: .place)
                         },
                         onLongPress: { coordinate in
                             picked = Waypoint(name: "", latitude: coordinate.latitude, longitude: coordinate.longitude,
                                               colorIndex: store.waypoints.count % WaypointPalette.colors.count)
                         })
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                Text("登録したい位置を長押ししてください")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
            }
            .navigationTitle("地図から登録")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $picked) { waypoint in
                WaypointEditor(waypoint: waypoint, isNew: true) { store.add($0) }
            }
    }
}

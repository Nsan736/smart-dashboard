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
                    Text("カメラ・GPS・方位のセンサーは、表示している間だけ動かします。通信はしません。")
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
                    }
                    ForEach(store.waypoints) { waypoint in
                        row(waypoint)
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
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
            .task { await refreshOrigin() }
        }
    }

    private func row(_ waypoint: Waypoint) -> some View {
        let store = env.waypoints
        return HStack(spacing: 10) {
            Circle().fill(WaypointPalette.color(waypoint.colorIndex)).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(waypoint.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if waypoint.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                }
                if let origin = store.origin {
                    Text(WaypointMath.summary(
                        bearing: WaypointMath.bearing(fromLatitude: origin.latitude, longitude: origin.longitude,
                                                      toLatitude: waypoint.latitude, longitude: waypoint.longitude),
                        distance: WaypointMath.distance(fromLatitude: origin.latitude, longitude: origin.longitude,
                                                        toLatitude: waypoint.latitude, longitude: waypoint.longitude)))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                if !waypoint.memo.isEmpty {
                    Text(waypoint.memo).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if editMode != .active {
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
        env.waypoints.setOrigin(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
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

/// 名前・色・メモ・座標の編集
struct WaypointEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var waypoint: Waypoint
    let isNew: Bool
    let onSave: (Waypoint) -> Void
    @State private var coordinateText = ""
    @State private var didLoad = false

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
            }
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
                         markers: store.waypoints.map {
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

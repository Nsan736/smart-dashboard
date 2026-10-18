import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/// 地図に描く、置いたオブジェクトの足元の輪郭(閉じた線)
enum ObjectMapShapes {
    static func footprintLine(_ placement: ObjectPlacement, object: ScopeObject) -> MapLine? {
        let hull = ObjectGeometry.footprint(of: object, heading: placement.heading, scale: placement.scale)
        guard hull.count >= 3 else { return nil }
        let origin = GeoPoint(placement.latitude, placement.longitude)
        var coordinates = hull.map { GeoMath.offset(origin, east: $0.x, north: $0.y).coordinate }
        coordinates.append(coordinates[0])
        let color = ObjectColor.uiColor(object.shapes.first?.color ?? ObjectShape.defaultColor)
        return MapLine(id: "object.\(placement.id.uuidString)", coordinates: coordinates, color: color,
                       casingColor: .white, isEmphasized: false, isDimmed: placement.isHidden)
    }
}

/// スコープの「オブジェクト」: 作ったオブジェクトと、地図に置いたもの。カメラ表示はここから開く。
struct ObjectListView: View {
    private struct PlaceRequest: Identifiable {
        let id = UUID()
        var coordinate: CLLocationCoordinate2D
    }

    private struct EditRequest: Identifiable {
        let id = UUID()
        var object: ScopeObject?
    }

    @Environment(AppEnvironment.self) private var env
    @State private var located: GeoPoint?
    @State private var placeRequest: PlaceRequest?
    @State private var editRequest: EditRequest?
    @State private var placementToEdit: ObjectPlacement?
    @State private var showsImport = false
    @State private var showsCompose = false
    @State private var objectToDelete: ScopeObject?

    var body: some View {
        @Bindable var settings = env.settings
        let store = env.objects
        let compose = env.objectCompose
        List {
            if compose.isRunning || compose.unseenID != nil {
                // 文章から作っている間と、できたあと(タップで作る画面に戻る)
                Section {
                    ClaudeWorkBanner(isRunning: compose.isRunning, hasResult: compose.unseenID != nil,
                                     runningText: "オブジェクトを作成中…(\(compose.progress.stage))",
                                     doneText: "オブジェクトができました(確認する)") {
                        if let id = compose.unseenID { compose.open(id) }
                        showsCompose = true
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            Section {
                NavigationLink {
                    ScopeSightView(mode: .camera, source: .objects)
                } label: {
                    Label("カメラで見る", systemImage: "camera.viewfinder")
                }
                NavigationLink {
                    ScopeSightView(mode: .compass, source: .objects)
                } label: {
                    Label("コンパスで見る", systemImage: "safari")
                }
                Toggle("地点・周辺・経路・電車・景色にも重ねる", isOn: $settings.objectsOverlayOthers)
            }
            Section {
                MapContainerView(center: located?.coordinate ?? store.placements.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                                 spanMeters: 800, isInteractive: true, showsUserLocation: true,
                                 lines: footprints,
                                 markers: store.placements.map {
                                     MapMarker(id: $0.id.uuidString, title: $0.name,
                                               coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), style: .place)
                                 },
                                 onSelectMarker: { id in placementToEdit = store.placements.first { $0.id.uuidString == id } },
                                 onLongPress: { coordinate in
                                     guard !store.objects.isEmpty else { return }
                                     placeRequest = PlaceRequest(coordinate: coordinate)
                                 },
                                 memoryKey: "scope.objects")
                    .frame(height: 260)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("地図")
            } footer: {
                Text(store.objects.isEmpty ? "まずオブジェクトを作ってください。" : "地図を長押しすると、その場所にオブジェクトを置けます。置いたものは、上から見た輪郭で表示します。")
            }
            Section("置いたもの(\(store.placements.count))") {
                if store.placements.isEmpty {
                    Text("まだ置いていません").foregroundStyle(.secondary)
                }
                ForEach(store.placements) { placement in
                    HStack(spacing: 10) {
                        Button {
                            store.setHidden(placement.id, hidden: !placement.isHidden)
                        } label: {
                            Image(systemName: placement.isHidden ? "eye.slash" : "eye")
                                .foregroundStyle(placement.isHidden ? Color.secondary : Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                        Button {
                            placementToEdit = placement
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(placement.name).foregroundStyle(placement.isHidden ? Color.secondary : Color.primary)
                                Text(placementSummary(placement)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(store.objects) { object in
                    HStack {
                        Button {
                            editRequest = EditRequest(object: object)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(object.name).foregroundStyle(Color.primary)
                                let extent = ObjectGeometry.extent(of: object)
                                Text("形\(object.shapes.count)個・" + String(format: "%.1f×%.1f×%.1fm", extent.width, extent.depth, extent.height))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Menu {
                            Button { editRequest = EditRequest(object: object) } label: { Label("編集", systemImage: "pencil") }
                            Button { store.duplicate(object.id) } label: { Label("複製", systemImage: "plus.square.on.square") }
                            ShareLink(item: ObjectCodec.encode(object), subject: Text(object.name)) {
                                Label("書き出す(共有)", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) { objectToDelete = object } label: { Label("削除", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                Button { editRequest = EditRequest(object: nil) } label: { Label("新しく作る", systemImage: "plus") }
                Button { showsImport = true } label: { Label("読み込む(JSON)", systemImage: "square.and.arrow.down") }
                if env.claude.hasKey {
                    Button { showsCompose = true } label: { Label("文章から作る(Claude)", systemImage: "text.bubble") }
                }
            } header: {
                Text("オブジェクト(\(store.objects.count))")
            } footer: {
                Text("箱・円柱・円錐・球・角錐・板を組み合わせて作ります。JSON で書き出し・読み込みができます。")
            }
        }
        .sheet(item: $editRequest) { ObjectEditorView(object: $0.object) }
        .sheet(item: $placeRequest) { request in
            ObjectPlacePicker(coordinate: request.coordinate) { placement in placementToEdit = placement }
        }
        .sheet(item: $placementToEdit) { ObjectPlacementEditor(placement: $0) }
        .sheet(isPresented: $showsImport) { ObjectImportView() }
        .sheet(isPresented: $showsCompose) { ObjectComposeView() }
        .confirmationDialog("このオブジェクトを削除しますか", isPresented: Binding(get: { objectToDelete != nil }, set: { if !$0 { objectToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("削除(置いたものも消えます)", role: .destructive) {
                if let object = objectToDelete { store.deleteObject(object.id) }
                objectToDelete = nil
            }
        }
        .task {
            await locate()
            await store.fillMissingElevations()
        }
    }

    private var footprints: [MapLine] {
        env.objects.placements.compactMap { placement in
            env.objects.object(id: placement.objectID).flatMap { ObjectMapShapes.footprintLine(placement, object: $0) }
        }
    }

    private func placementSummary(_ placement: ObjectPlacement) -> String {
        var parts: [String] = []
        if let located {
            let distance = WaypointMath.distance(fromLatitude: located.latitude, longitude: located.longitude,
                                                 toLatitude: placement.latitude, longitude: placement.longitude)
            let bearing = WaypointMath.bearing(fromLatitude: located.latitude, longitude: located.longitude,
                                               toLatitude: placement.latitude, longitude: placement.longitude)
            parts.append("\(WaypointMath.compassPoint(bearing)) \(SceneryText.distance(distance))")
        }
        parts.append("向き\(Int(placement.heading.rounded()))°")
        if placement.scale != 1 { parts.append(String(format: "×%.1f", placement.scale)) }
        if placement.isHidden { parts.append("非表示") }
        return parts.joined(separator: "・")
    }

    private func locate() async {
        if env.movement.isVirtual, let point = env.movement.currentPoint {
            located = point
            return
        }
        if let location = try? await env.location.currentLocation() {
            located = GeoPoint(location.coordinate)
        }
    }
}

/// 地図で長押しした場所に置くオブジェクトを選ぶ
struct ObjectPlacePicker: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let coordinate: CLLocationCoordinate2D
    let onPlaced: (ObjectPlacement) -> Void

    var body: some View {
        NavigationStack {
            List(env.objects.objects) { object in
                Button {
                    if let placement = env.objects.place(objectID: object.id, latitude: coordinate.latitude, longitude: coordinate.longitude) {
                        dismiss()
                        // 閉じてから、置いたものの編集を開く
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onPlaced(placement) }
                    }
                } label: {
                    Label(object.name, systemImage: object.shapes.first?.kind.symbol ?? "cube")
                }
            }
            .navigationTitle("置くオブジェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 置いたものの編集: 位置(地図をタップして移す)、向き、地面からの高さ、倍率、表示・非表示
struct ObjectPlacementEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ObjectPlacement
    @State private var confirmDelete = false

    init(placement: ObjectPlacement) {
        _draft = State(initialValue: placement)
    }

    var body: some View {
        let object = env.objects.object(id: draft.objectID)
        let current = env.objects.placements.first { $0.id == draft.id }
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: Binding(get: { draft.name }, set: { draft.name = String($0.prefix(40)) }))
                    MapContainerView(center: CLLocationCoordinate2D(latitude: draft.latitude, longitude: draft.longitude), spanMeters: 400,
                                     pin: CLLocationCoordinate2D(latitude: draft.latitude, longitude: draft.longitude), isInteractive: true,
                                     showsUserLocation: true,
                                     lines: object.flatMap { ObjectMapShapes.footprintLine(draft, object: $0) }.map { [$0] } ?? [],
                                     onTapCoordinate: { coordinate in
                                         draft.latitude = coordinate.latitude
                                         draft.longitude = coordinate.longitude
                                     })
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("地図をタップすると、その場所に移します。")
                }
                Section {
                    NumberScrubField(label: "向き", value: $draft.heading, step: 1, range: 0...359.9, unit: "°") {}
                    Slider(value: $draft.heading, in: 0...359.9)
                    NumberScrubField(label: "地面から", value: $draft.heightAboveGround, step: 0.5, range: -200...3000, unit: "m") {}
                    NumberScrubField(label: "倍率", value: $draft.scale, step: 0.1, range: ObjectPlacement.scaleRange, unit: "倍") {}
                    Toggle("表示する", isOn: Binding(get: { !draft.isHidden }, set: { draft.isHidden = !$0 }))
                } footer: {
                    Text("向きは、オブジェクトの正面が向く方角(北が0°、時計回り)です。")
                }
                Section {
                    if let current, env.objects.fetching.contains(current.id) {
                        Label("地面の標高を取得中…", systemImage: "hourglass")
                    } else if let ground = current?.groundElevation {
                        LabeledContent("地面の標高", value: "\(Int(ground.rounded()))m")
                    } else {
                        LabeledContent("地面の標高", value: current?.elevationState == .noData ? "データなし" : "未取得")
                        Button("標高を取得") { Task { await env.objects.fetchElevation(for: draft.id) } }
                    }
                    if let object {
                        let extent = ObjectGeometry.extent(of: object)
                        LabeledContent("大きさ", value: String(format: "%.1f×%.1f×%.1fm", extent.width * draft.scale, extent.depth * draft.scale,
                                                             extent.height * draft.scale))
                    }
                } footer: {
                    Text("地面の標高は、地点と同じ国土地理院の標高APIで取ります。")
                }
                Section {
                    Button("削除", role: .destructive) { confirmDelete = true }
                }
            }
            .keyboardDismissable()
            .navigationTitle("置いたもの")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        env.objects.update(draft)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("置いたものを削除しますか", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    env.objects.deletePlacement(draft.id)
                    dismiss()
                }
            }
        }
    }
}

/// JSON から読み込む(貼り付け・「ファイル」)。保存する前にプレビューする
struct ObjectImportView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var json: String
    @State private var isImporting = false
    @State private var message: String?

    init(json: String = "") {
        _json = State(initialValue: json)
    }

    var body: some View {
        let result = json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ObjectCodec.parse(json)
        NavigationStack {
            Form {
                Section {
                    Button("クリップボードから貼り付ける") {
                        if let text = UIPasteboard.general.string { json = text } else { message = "クリップボードに文字がありません" }
                    }
                    Button("「ファイル」から読み込む") { isImporting = true }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
                if let result {
                    switch result {
                    case .success(let object):
                        ObjectConfirmSection(object: object)
                    case .failure(let issues):
                        Section("形式の誤り(\(issues.count)件)") {
                            ForEach(issues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(issue.message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Section("JSON(直接編集できます)") {
                    TextEditor(text: $json)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .keyboardDismissable()
            .navigationTitle("オブジェクトを読み込む")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard case .success(let object)? = result else { return }
                        env.objects.save(object)
                        dismiss()
                    }
                    .disabled({ if case .success? = result { return false } else { return true } }())
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .plainText]) { outcome in
                guard case .success(let url) = outcome else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), data.count <= ObjectCodec.maxBytes, let text = String(data: data, encoding: .utf8) {
                    json = text
                    message = nil
                } else {
                    message = "読み込めませんでした(UTF-8のテキストで、400KBまで)"
                }
            }
        }
    }
}

/// 保存する前の確認(プレビューと形の数・大きさ)
struct ObjectConfirmSection: View {
    let object: ScopeObject

    var body: some View {
        let extent = ObjectGeometry.extent(of: object)
        Section {
            ObjectPreviewView(object: object)
                .frame(height: 220)
                .listRowInsets(EdgeInsets())
            LabeledContent("名前", value: object.name)
            LabeledContent("形", value: "\(object.shapes.count)個")
            LabeledContent("大きさ", value: String(format: "%.1f×%.1f×%.1fm", extent.width, extent.depth, extent.height))
        } header: {
            Text("内容の確認(指で回す・拡大できます)")
        }
    }
}

/// カメラ表示でタップしたオブジェクトの情報
struct ObjectPlacementInfoSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let placementID: UUID
    let user: GeoPoint?

    var body: some View {
        NavigationStack {
            List {
                if let placement = env.objects.placements.first(where: { $0.id == placementID }) {
                    let object = env.objects.object(id: placement.objectID)
                    Section {
                        Text(placement.name).font(.title2.weight(.bold))
                        if let user {
                            let distance = WaypointMath.distance(fromLatitude: user.latitude, longitude: user.longitude,
                                                                 toLatitude: placement.latitude, longitude: placement.longitude)
                            let bearing = WaypointMath.bearing(fromLatitude: user.latitude, longitude: user.longitude,
                                                               toLatitude: placement.latitude, longitude: placement.longitude)
                            LabeledContent("距離", value: SceneryText.distance(distance))
                            LabeledContent("方角", value: "\(WaypointMath.compassPoint(bearing)) \(Int(bearing.rounded()))°")
                        }
                        if let object {
                            let extent = ObjectGeometry.extent(of: object)
                            LabeledContent("大きさ", value: String(format: "幅%.1f×奥行き%.1f×高さ%.1fm", extent.width * placement.scale,
                                                                 extent.depth * placement.scale, extent.height * placement.scale))
                        }
                        LabeledContent("地面から", value: String(format: "%.1fm", placement.heightAboveGround))
                        LabeledContent("向き", value: "\(Int(placement.heading.rounded()))°")
                        if let ground = placement.groundElevation { LabeledContent("地面の標高", value: "\(Int(ground.rounded()))m") }
                    }
                } else {
                    Text("見つかりません").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("オブジェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

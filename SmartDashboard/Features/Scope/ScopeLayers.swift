import SwiftUI

/// スコープのカメラ表示・コンパス表示に重ねる表示(v0.9.29)。いくつでも同時にオンにできる
enum ScopeLayer: String, CaseIterable, Codable, Identifiable {
    case places
    case nearby
    case objects
    case route
    case trains
    case scenery
    /// 太陽と月(v0.9.30)
    case sunMoon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .places: return "地点"
        case .nearby: return "周辺"
        case .objects: return "オブジェクト"
        case .route: return "経路"
        case .trains: return "電車"
        case .scenery: return "景色"
        case .sunMoon: return "太陽と月"
        }
    }

    var symbol: String {
        switch self {
        case .places: return "mappin.and.ellipse"
        case .nearby: return "building.2"
        case .objects: return "cube"
        case .route: return "figure.walk"
        case .trains: return "tram"
        case .scenery: return "mountain.2"
        case .sunMoon: return "sun.and.horizon"
        }
    }

    /// 「撮って聞く」で Claude に送る、印の種類の名前
    var kindName: String {
        switch self {
        case .places: return "登録した地点"
        case .nearby: return "周辺の施設"
        case .objects: return "置いたオブジェクト"
        case .route: return "経路の目的地・曲がり角"
        case .trains: return "電車"
        case .scenery: return "山"
        case .sunMoon: return "太陽・月"
        }
    }

    var group: ScopeLayerGroup {
        switch self {
        case .places, .nearby, .objects: return .marks
        case .route, .trains: return .movement
        case .scenery, .sunMoon: return .sky
        }
    }

    /// 並べる順(グループの順)
    static func sorted(_ layers: Set<ScopeLayer>) -> [ScopeLayer] {
        allCases.filter { layers.contains($0) }
    }
}

/// 「表示」の画面のグループ
enum ScopeLayerGroup: String, CaseIterable, Identifiable {
    case marks
    case movement
    case sky

    var id: String { rawValue }

    var label: String {
        switch self {
        case .marks: return "印"
        case .movement: return "移動"
        case .sky: return "空と景色"
        }
    }

    var layers: [ScopeLayer] { ScopeLayer.allCases.filter { $0.group == self } }
}

/// よく使う組み合わせ
struct ScopeLayerPreset: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var symbol: String
    var layers: Set<ScopeLayer>
    /// 景色の中の層(nil なら、今の選択のまま)
    var sceneryLayers: [SceneryLayer]?

    static let all: [ScopeLayerPreset] = [
        ScopeLayerPreset(name: "歩く", symbol: "figure.walk", layers: [.places, .route]),
        ScopeLayerPreset(name: "電車", symbol: "tram", layers: [.trains, .places]),
        ScopeLayerPreset(name: "景色", symbol: "mountain.2", layers: [.scenery], sceneryLayers: [.mountains, .skyline]),
        ScopeLayerPreset(name: "周辺の施設", symbol: "building.2", layers: [.nearby, .places]),
        ScopeLayerPreset(name: "空", symbol: "sun.and.horizon", layers: [.scenery, .sunMoon], sceneryLayers: [.mountains, .skyline]),
    ]
}

/// 以前の版(v0.9.28 まで)の状態から、重ねる表示を決める。上部で選んでいた画面の表示と、「ほかの表示にも重ねる」をオンにしていた景色・オブジェクト
enum ScopeLayerMigration {
    static func initial(section: String?, sceneryOverlaysOthers: Bool, objectsOverlayOthers: Bool, hasSceneryLayers: Bool) -> Set<ScopeLayer> {
        var result: Set<ScopeLayer> = []
        let selected = section.flatMap(ScopeLayer.init(rawValue:)) ?? .places
        result.insert(selected)
        if hasSceneryLayers, sceneryOverlaysOthers || selected == .scenery { result.insert(.scenery) }
        if objectsOverlayOthers { result.insert(.objects) }
        return result
    }

    static func decode(_ raw: [String]) -> Set<ScopeLayer> {
        Set(raw.compactMap(ScopeLayer.init(rawValue:)))
    }
}

/// 「表示」の画面: 重ねる表示のオンとオフ、景色の中の層、おすすめ
struct ScopeLayerPickerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = env.settings
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ScopeLayerPreset.all) { preset in
                                Button {
                                    settings.scopeLayers = preset.layers
                                    if let scenery = preset.sceneryLayers, scenery != settings.sceneryLayers {
                                        settings.sceneryLayers = scenery
                                        env.scenery.settingsChanged()
                                    }
                                } label: {
                                    Label(preset.name, systemImage: preset.symbol)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(settings.scopeLayers == preset.layers ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill),
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 0))
                } header: {
                    Text("おすすめ")
                } footer: {
                    Text("歩く=地点・経路、電車=電車・地点、景色=山・稜線、周辺の施設=周辺・地点、空=景色・太陽と月")
                }
                ForEach(ScopeLayerGroup.allCases) { group in
                    Section(group.label) {
                        ForEach(group.layers) { layer in
                            Toggle(isOn: Binding(get: { settings.scopeLayers.contains(layer) }, set: { on in
                                if on { settings.scopeLayers.insert(layer) } else { settings.scopeLayers.remove(layer) }
                            })) {
                                Label(layer.label, systemImage: layer.symbol)
                            }
                            if layer == .scenery, settings.scopeLayers.contains(.scenery) {
                                SceneryLayerToggles()
                                    .padding(.leading, 24)
                            }
                        }
                    }
                }
            }
            .navigationTitle("表示")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// カメラ表示の上部に並べる、オンになっている表示の小さなアイコン。タップでその表示だけをオフにする
struct ScopeActiveLayerIcons: View {
    let layers: [ScopeLayer]
    let onRemove: (ScopeLayer) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(layers) { layer in
                Button {
                    onRemove(layer)
                } label: {
                    Image(systemName: layer.symbol)
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(layer.label)をオフにする")
            }
        }
    }
}

/// スコープの「管理」: 地点・周辺・経路・電車・景色・オブジェクトの一覧と設定、方角の補正、最近作ったもの・最近聞いたこと
struct ScopeManageView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(ScopeLayer.allCases) { layer in
                    NavigationLink {
                        if layer == .sunMoon {
                            SkyDetailView()
                        } else {
                            ScopeManageDetail(layer: layer)
                        }
                    } label: {
                        Label(layer.label, systemImage: layer.symbol)
                    }
                }
            } header: {
                Text("一覧と設定")
            } footer: {
                Text("地点の登録、周辺の施設の検索、経路の取得、電車の対象、景色の範囲、オブジェクトを作る・置く(文章・写真から作るを含む)、太陽と月の出入りとダイヤモンド富士の予報は、ここから開きます。")
            }
            Section {
                NavigationLink {
                    Form { HeadingCorrectionSettingsSection() }
                        .navigationTitle("方角の補正")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    LabeledContent {
                        Text(HeadingCorrection.text(env.settings.headingOffset) ?? "なし")
                    } label: {
                        Label("方角の補正", systemImage: "location.north.line")
                    }
                }
                NavigationLink {
                    ObjectComposeEntryView()
                } label: {
                    Label("文章から作ったオブジェクト", systemImage: "text.bubble")
                }
                NavigationLink {
                    ScopeAskRecentsList()
                } label: {
                    Label("最近聞いたこと(撮って聞く)", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationTitle("管理")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 管理の中の、表示ごとの一覧と設定の画面(以前の上部の切り替えで開いていた画面)
struct ScopeManageDetail: View {
    let layer: ScopeLayer
    @State private var section: ScopeSection

    init(layer: ScopeLayer) {
        self.layer = layer
        _section = State(initialValue: ScopeSection(rawValue: layer.rawValue) ?? .places)
    }

    var body: some View {
        Group {
            // 以前の画面は、ほかの画面へ切り替える Binding を受け取るので、その画面の中だけで切り替える
            switch section {
            case .places: WaypointListView(section: $section)
            case .nearby: NearbyView(section: $section)
            case .route: RouteView(section: $section)
            case .trains: ScopeTrainsView()
            case .scenery: SceneryView()
            case .objects: ObjectListView()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(section.label)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 管理から開く、オブジェクトを文章から作る画面(最近作ったものを含む)
struct ObjectComposeEntryView: View {
    @State private var showsCompose = false

    var body: some View {
        List {
            Button {
                showsCompose = true
            } label: {
                Label("文章から作る(Claude)・最近作ったもの", systemImage: "text.bubble")
            }
        }
        .navigationTitle("文章から作る")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsCompose) { ObjectComposeView() }
    }
}

/// 管理から開く、最近聞いたこと(会話を開くと、その場で聞く画面を出す)
struct ScopeAskRecentsList: View {
    @State private var showsRecents = true
    @State private var opensAsk = false
    @State private var showsAsk = false

    var body: some View {
        List {
            Button("最近聞いたことを開く") { showsRecents = true }
        }
        .navigationTitle("最近聞いたこと")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsRecents, onDismiss: {
            if opensAsk {
                opensAsk = false
                showsAsk = true
            }
        }) {
            ScopeAskRecentsView { opensAsk = true }
        }
        .fullScreenCover(isPresented: $showsAsk) { ScopeAskView() }
    }
}

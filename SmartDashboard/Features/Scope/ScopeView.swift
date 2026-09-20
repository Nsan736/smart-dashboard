import CoreLocation
import SwiftUI

/// スコープのタブ。上部で「地点/周辺/経路」を切り替える。カメラ表示とコンパス表示は3つで共通(ScopeSightView)。
struct ScopeView: View {
    @AppStorage("scope.section") private var sectionRaw = ScopeSection.places.rawValue

    var body: some View {
        let section = Binding<ScopeSection>(
            get: { ScopeSection(rawValue: sectionRaw) ?? .places },
            set: { sectionRaw = $0.rawValue })
        NavigationStack {
            VStack(spacing: 0) {
                Picker("表示", selection: section) {
                    ForEach(ScopeSection.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                switch section.wrappedValue {
                case .places: WaypointListView(section: section)
                case .nearby: NearbyView(section: section)
                case .route: RouteView(section: section)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("スコープ")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 周辺

/// 周辺の施設。MapKit で探す(APIキーは使わない)。
struct NearbyView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var section: ScopeSection
    @State private var origin: CLLocationCoordinate2D?
    @State private var isLocating = false
    @State private var locationError: String?
    @State private var selected: NearbyPlace?

    var body: some View {
        @Bindable var settings = env.settings
        let store = env.nearby
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(settings.nearbyCategories) { category in
                            Button {
                                Task { await search(category, force: false) }
                            } label: {
                                Label(category.label, systemImage: category.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(store.category == category ? Color.white : Color.primary)
                                    .background(store.category == category ? category.color : Color(.tertiarySystemFill), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 0))
                Picker("探す範囲", selection: $settings.nearbyRadius) {
                    ForEach(NearbyRadius.choices, id: \.self) { Text(WaypointMath.distanceText(Double($0))).tag($0) }
                }
                NavigationLink("カテゴリの並び順") { NearbyCategoryOrderEditor() }
            } footer: {
                Text("カテゴリを選ぶと、現在地の周辺を探します。検索は iOS の地図(MapKit)が行うため、このアプリでは受信量を計測できません。同じ場所・同じカテゴリの結果は5分間使い回します。")
            }

            if let category = store.category {
                Section {
                    if isLocating || store.isLoading {
                        HStack {
                            ProgressView()
                            Text(isLocating ? "現在地を取得中…" : "探しています…").foregroundStyle(.secondary)
                        }
                    }
                    if let message = locationError ?? store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    }
                    if !store.places.isEmpty {
                        NavigationLink {
                            ScopeSightView(mode: .camera, source: .nearby)
                        } label: {
                            Label("カメラで見る", systemImage: "camera.viewfinder")
                        }
                        NavigationLink {
                            ScopeSightView(mode: .compass, source: .nearby)
                        } label: {
                            Label("コンパスで見る", systemImage: "safari")
                        }
                        MapContainerView(center: origin, spanMeters: Double(settings.nearbyRadius) * 2.4, isInteractive: true, showsUserLocation: true,
                                         markers: store.places.map {
                                             MapMarker(id: $0.id, title: $0.name,
                                                       coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), style: .place)
                                         },
                                         onSelectMarker: { id in selected = store.places.first { $0.id == id } })
                            .frame(height: 230)
                            .listRowInsets(EdgeInsets())
                    } else if !isLocating, !store.isLoading, store.errorMessage == nil, locationError == nil {
                        Text("\(WaypointMath.distanceText(Double(settings.nearbyRadius)))以内には見つかりませんでした").foregroundStyle(.secondary)
                    }
                    ForEach(store.places) { place in
                        Button {
                            selected = place
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: category.symbol).foregroundStyle(category.color).frame(width: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(place.name).font(.headline).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                                    Text(WaypointMath.summary(bearing: place.bearing, distance: place.distance))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("\(category.label)(近い順)")
                } footer: {
                    if let searchedAt = store.searchedAt {
                        HStack {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text("\(Formatters.ageLabel(searchedAt, now: context.date))の検索結果")
                            }
                            Spacer()
                            Button("探し直す") { Task { await search(category, force: true) } }
                                .font(.footnote)
                        }
                    }
                }
            }
        }
        .onChange(of: settings.nearbyRadius) { _, _ in
            if let category = store.category { Task { await search(category, force: false) } }
        }
        .sheet(item: $selected) { place in
            NearbyPlaceSheet(place: place, section: $section)
        }
    }

    /// 現在地を1回だけ取得して探す。結果は数分使い回し、100m以上動いたときだけ探し直す。
    private func search(_ category: NearbyCategory, force: Bool) async {
        isLocating = true
        locationError = nil
        defer { isLocating = false }
        do {
            let location = try await env.location.currentLocation()
            origin = location.coordinate
            env.waypoints.setOrigin(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            isLocating = false
            await env.nearby.search(category, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                    radius: env.settings.nearbyRadius, force: force)
        } catch {
            locationError = error.localizedDescription
        }
    }
}

/// 施設の詳細と、「地点に保存」「ここへの経路」
struct NearbyPlaceSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let place: NearbyPlace
    @Binding var section: ScopeSection
    @State private var didSave = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(place.category.label, systemImage: place.category.symbol).font(.caption).foregroundStyle(place.category.color)
                        Text(place.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        Text(WaypointMath.summary(bearing: place.bearing, distance: place.distance)).font(.headline).monospacedDigit()
                    }
                    if let address = place.address, !address.isEmpty {
                        LabeledContent("住所") { Text(address).multilineTextAlignment(.trailing).textSelection(.enabled) }
                    }
                    if let phone = place.phone, !phone.isEmpty, let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                        LabeledContent("電話") { Link(phone, destination: url) }
                    }
                    if let url = place.url {
                        LabeledContent("Webサイト") { Link(url.host ?? "開く", destination: url).lineLimit(1) }
                    }
                } footer: {
                    Text("施設の情報は、iOS の地図(MapKit)の検索結果です。")
                }
                Section {
                    Button {
                        env.waypoints.add(Waypoint(name: place.name, latitude: place.latitude, longitude: place.longitude,
                                                   colorIndex: env.waypoints.waypoints.count % WaypointPalette.colors.count, memo: place.address ?? ""))
                        didSave = true
                    } label: {
                        Label(didSave ? "地点に保存しました" : "地点に保存", systemImage: didSave ? "checkmark" : "mappin.and.ellipse")
                    }
                    .disabled(didSave)
                    Button {
                        env.route.setDestination(ScopeDestination(name: place.name, latitude: place.latitude, longitude: place.longitude))
                        section = .route
                        dismiss()
                    } label: {
                        Label("ここへの経路", systemImage: "arrow.triangle.turn.up.right.diamond")
                    }
                }
            }
            .navigationTitle("施設の詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// よく使うカテゴリを前に並べる
struct NearbyCategoryOrderEditor: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                ForEach(env.settings.nearbyCategories) { category in
                    Label(category.label, systemImage: category.symbol)
                }
                .onMove { source, destination in
                    var order = env.settings.nearbyCategories
                    order.move(fromOffsets: source, toOffset: destination)
                    env.settings.nearbyCategories = order
                }
            } footer: {
                Text("右端のつまみをドラッグして並べ替えます。")
            }
            Section {
                Button("初期の並びに戻す", role: .destructive) { env.settings.nearbyCategories = NearbyCategory.allCases }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("カテゴリの並び順")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 経路

/// 現在地から、地点または周辺の施設への徒歩の経路。取得は MapKit(MKDirections)。
struct RouteView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var section: ScopeSection
    @State private var isLocating = false
    @State private var locationError: String?

    var body: some View {
        let route = env.route
        List {
            if let destination = route.destination {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("目的地").font(.caption).foregroundStyle(.secondary)
                        Text(destination.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        if let plan = route.plan {
                            BigValue(value: plan.summaryText, size: 28)
                        }
                    }
                    if isLocating || route.isLoading {
                        HStack {
                            ProgressView()
                            Text(isLocating ? "現在地を取得中…" : "経路を取得中…").foregroundStyle(.secondary)
                        }
                    }
                    if let message = locationError ?? route.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                    }
                    if route.plan != nil {
                        NavigationLink {
                            RouteGuidanceView()
                        } label: {
                            Label("地図で案内を始める", systemImage: "location.north.line.fill")
                                .font(.headline)
                        }
                    }
                    Button {
                        Task { await fetch() }
                    } label: {
                        Label(route.plan == nil ? "経路を取得" : "現在地から取り直す", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLocating || route.isLoading)
                    Button("案内をやめる", role: .destructive) { route.setDestination(nil) }
                } footer: {
                    Text("徒歩の経路です。取得は iOS の地図(MapKit)が行うため、このアプリでは受信量を計測できません。案内中(地図の案内の画面と、そこから開くカメラ表示)だけ、高精度のGPSを使い、画面を消しません。")
                }
                if let plan = route.plan {
                    Section {
                        MapContainerView(center: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude),
                                         spanMeters: 1500, isInteractive: true, showsUserLocation: true,
                                         lines: [MapLine(id: "route", coordinates: plan.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                                                         color: .systemBlue, casingColor: .white, isEmphasized: false)],
                                         markers: [MapMarker(id: "destination", title: destination.name,
                                                             coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude), style: .place)],
                                         fitKey: "route-\(plan.fetchedAt.timeIntervalSince1970)")
                            .frame(height: 260)
                            .listRowInsets(EdgeInsets())
                    }
                    Section("曲がり角") {
                        ForEach(plan.turns) { turn in
                            HStack(alignment: .firstTextBaseline) {
                                Text(turn.instructions.isEmpty ? "出発" : turn.instructions).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Text(WaypointMath.distanceText(turn.distance)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .fontWeight(route.navigator?.nextTurn?.id == turn.id ? .bold : .regular)
                        }
                    }
                }
            } else {
                Section {
                    Text("「地点」か「周辺」で行き先を選び、「ここへの経路」を押してください。").foregroundStyle(.secondary)
                }
                if !env.waypoints.waypoints.isEmpty {
                    Section("登録した地点から選ぶ") {
                        ForEach(env.waypoints.waypoints) { waypoint in
                            Button {
                                route.setDestination(ScopeDestination(name: waypoint.name, latitude: waypoint.latitude, longitude: waypoint.longitude))
                            } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(WaypointPalette.color(waypoint.colorIndex)).frame(width: 14, height: 14)
                                    Text(waypoint.name).foregroundStyle(Color.primary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: route.destination) {
            // 行き先を選んだら、すぐに取得する
            if route.destination != nil, route.plan == nil { await fetch() }
        }
    }

    private func fetch() async {
        isLocating = true
        locationError = nil
        defer { isLocating = false }
        do {
            let location = try await env.location.currentLocation()
            env.waypoints.setOrigin(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            isLocating = false
            await env.route.fetch(fromLatitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        } catch {
            locationError = error.localizedDescription
        }
    }
}

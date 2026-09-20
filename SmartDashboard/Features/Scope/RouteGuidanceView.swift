import CoreLocation
import SwiftUI

/// 地図に描く経路の線と印(View の外に置いてテストできるようにする)
enum RouteMapContent {
    /// 通り過ぎた部分と、これからの部分。現在地がまだ分からなければ、全体を「これから」として返す。
    static func paths(_ navigator: RouteNavigator) -> (passed: [RoutePoint], remaining: [RoutePoint]) {
        guard let progress = navigator.progress else { return ([], navigator.plan.points) }
        return (progress.passed, progress.remaining)
    }

    /// 上部の案内の2行目。「その次：左折する」。なければ nil。
    static func afterNextText(_ navigator: RouteNavigator) -> String? {
        guard !navigator.hasArrived, navigator.nextTurn != nil, let turn = navigator.turnAfterNext else { return nil }
        let instruction = turn.instructions.isEmpty ? "次の曲がり角" : turn.instructions
        return "その次：\(instruction)"
    }
}

/// 地図での経路の案内。地図は現在地に追従し、進行方向を上にして回転する(北を上にも切り替えられる)。
/// 表示している間だけ、高精度のGPSを使い、画面を消さない。
struct RouteGuidanceView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scope.route.headingUp") private var headingUp = true
    @State private var tracker = WaypointTracker()
    @State private var isFollowing = true
    @State private var trackingKey = 0
    @State private var isVisible = false
    @State private var confirmStop = false

    var body: some View {
        let route = env.route
        ZStack(alignment: .bottomTrailing) {
            map
            VStack(spacing: 10) {
                if !isFollowing {
                    Button {
                        isFollowing = true
                        trackingKey += 1
                    } label: {
                        Label("現在地に戻る", systemImage: "location.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                Button {
                    headingUp.toggle()
                    isFollowing = true
                    trackingKey += 1
                } label: {
                    Label(headingUp ? "進行方向が上" : "北が上", systemImage: headingUp ? "location.north.line.fill" : "safari")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(10)
        }
        .safeAreaInset(edge: .top) { guidanceBanner }
        .safeAreaInset(edge: .bottom) { remainingBar }
        .navigationTitle("経路の案内")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    ScopeSightView(mode: .camera, source: .route)
                } label: {
                    Label("カメラ表示", systemImage: "camera.viewfinder")
                }
                Button(role: .destructive) {
                    confirmStop = true
                } label: {
                    Label("案内をやめる", systemImage: "xmark.circle")
                }
            }
        }
        .confirmationDialog("案内をやめますか", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("案内をやめる", role: .destructive) {
                route.setDestination(nil)
                dismiss()
            }
        }
        .onAppear {
            isVisible = true
            start()
        }
        .onDisappear {
            isVisible = false
            stop()
        }
        .onChange(of: scenePhase) { _, phase in
            guard isVisible else { return }
            if phase == .active { start() } else { stop() }
        }
    }

    /// 高精度のGPSは、この画面(と、ここから開くカメラ表示)を表示している間だけ。表示中は画面を消さない。
    private func start() {
        ScreenAwake.set("route", true)
        tracker.onLocation = { [store = env.waypoints, route = env.route] coordinate in
            store.setOrigin(latitude: coordinate.latitude, longitude: coordinate.longitude)
            route.updateLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        tracker.start(includesMotion: false)
    }

    private func stop() {
        ScreenAwake.set("route", false)
        tracker.stop()
    }

    // MARK: - 地図

    @ViewBuilder
    private var map: some View {
        if let navigator = env.route.navigator {
            let destination = navigator.plan.destination
            let paths = RouteMapContent.paths(navigator)
            // 通り過ぎた部分は薄く、これからの部分は濃く
            let lines = [
                MapLine(id: "route-passed", coordinates: paths.passed.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                        color: .systemGray, casingColor: nil, isEmphasized: false, isDimmed: true),
                MapLine(id: "route-remaining", coordinates: paths.remaining.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                        color: .systemBlue, casingColor: .white, isEmphasized: false),
            ].filter { $0.coordinates.count > 1 }
            let turnMarker = navigator.hasArrived ? nil : navigator.nextTurn.map {
                MapMarker(id: "turn-\($0.id)", title: "次", coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude), style: .turn)
            }
            let markers = [MapMarker(id: "destination", title: destination.name,
                                     coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude), style: .place)]
                + (turnMarker.map { [$0] } ?? [])
            MapContainerView(center: navigator.plan.points.first.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                             spanMeters: 400, isInteractive: true, showsUserLocation: true, lines: lines, markers: markers,
                             tracking: isFollowing ? (headingUp ? .followHeading : .follow) : .none, trackingKey: trackingKey,
                             onTrackingLost: { isFollowing = false })
                .ignoresSafeArea(edges: .horizontal)
        } else {
            ContentUnavailableView("経路がありません", systemImage: "map", description: Text("「経路」の画面で、経路を取得してください。"))
        }
    }

    // MARK: - 上部の案内

    @ViewBuilder
    private var guidanceBanner: some View {
        let route = env.route
        if let navigator = route.navigator {
            VStack(alignment: .leading, spacing: 4) {
                Text(navigator.guidanceText)
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let after = RouteMapContent.afterNextText(navigator) {
                    Text(after)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                if let error = route.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }

    // MARK: - 下部の残り

    @ViewBuilder
    private var remainingBar: some View {
        if let navigator = env.route.navigator {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let remaining = navigator.remaining(now: context.date)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    remainingValue("残り", WaypointMath.distanceText(remaining.distance))
                    remainingValue("時間", RouteText.duration(remaining.time))
                    remainingValue("到着予定", remaining.arrivalText)
                    Spacer(minLength: 0)
                    Text(tracker.horizontalAccuracy.map { "±\(Int($0.rounded()))m" } ?? "測位中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial)
            }
        }
    }

    private func remainingValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

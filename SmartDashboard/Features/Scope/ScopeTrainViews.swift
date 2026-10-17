import SwiftUI
import UIKit

/// カメラ越しに描く電車の、1回の描画の配置(形で描く車両、遠い列車のリング、文字、タップの位置)。
/// 描画とタップの判定で同じものを使う。
enum ScopeTrainRenderer {
    /// 形で描く列車の数の上限(近い順)。これより遠い列車は、リングの印にする(iPhone SE 第2世代で30fpsを保つため)。
    static let maxShapeTrains = 8
    /// この距離より遠い列車は、形ではなくリングの印にする
    static let shapeDistance = 600.0
    /// 先頭の車両の、画面の上での高さがこれより小さければ、リングの印にする
    static let minimumShapeHeight: CGFloat = 5
    /// 車両の箱を描かない、近すぎる奥行き(m)
    static let nearPlane = 1.0

    struct Face {
        var points: [CGPoint]
        var color: Color
        /// 地下の車両(半透明の輪郭線だけで描く)
        var isUnderground = false
    }

    /// 車両の箱を置く高さを決めるための値
    struct Heights {
        /// 自分の目の高さ(m)。分からなければ nil(線路の高さが分かっても、地面の高さに置く)。
        var observerAltitude: Double?
        var handHeight: Double
        var elevated: Double
        var underground: Double

        /// 目の高さを0とした、車両の箱の下の高さ。線路の高さか自分の高さが分からなければ、地面(手の高さだけ下)。
        func base(_ height: TrackHeightModel.Height) -> Double {
            guard let altitude = height.altitude, let observerAltitude else { return -handHeight }
            return altitude - observerAltitude
        }
    }

    /// 半透明の輪郭線だけで描くか(地下の区間。地面の標高が分からなくても、地下と分かっていれば輪郭線にする)
    static func drawsAsOutline(_ height: TrackHeightModel.Height) -> Bool {
        height.section == .underground
    }

    struct Item: Identifiable {
        enum Kind {
            /// 遠い車両から順に並べた面
            case shape(faces: [Face])
            /// リングの印。arrow は画面の上での進行方向(ラジアン、右が0、下が正)。地下なら半透明の破線。
            case ring(center: CGPoint, inner: CGFloat, arrow: Double?, isUnderground: Bool = false)
        }

        var id: String
        var distance: Double
        var kind: Kind
        var color: Color
        var isDelayed: Bool
        var outline: Color
        var outlineWidth: CGFloat
        /// 文字を置く位置(この点の上に文字の下端)
        var labelAnchor: CGPoint
        /// タップの判定に使う位置
        var hitPoint: CGPoint
        var caption: String
    }

    /// 基準の座標系(x=北、y=西、z=上)のベクトルを画面の位置へ。カメラの後ろ側(奥行きが近すぎる)なら nil。
    /// 画面の外でも位置を返す(はみ出す部分は Canvas が切り取る)。
    static func project(_ v: Vector3, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> CGPoint? {
        let depth = Vector3.dot(v, attitude.forward)
        guard depth > nearPlane else { return nil }
        let nx = Vector3.dot(v, attitude.right) / depth / max(tangents.horizontal, 0.0001)
        let ny = Vector3.dot(v, attitude.up) / depth / max(tangents.vertical, 0.0001)
        return CGPoint(x: size.width / 2 * (1 + nx), y: size.height / 2 * (1 - ny))
    }

    /// 現在地から見た点(緯度経度と、目の高さからの上下)を、基準の座標系のベクトルにする
    static func vector(_ point: GeoPoint, up: Double, user: GeoPoint) -> Vector3 {
        let local = GeoMath.local(point, origin: user)
        return Vector3(x: local.y, y: -local.x, z: up)
    }

    static func shades(_ base: UIColor) -> (side: Color, top: Color, end: Color, headSide: Color) {
        func mix(_ color: UIColor, with other: UIColor, _ amount: CGFloat) -> Color {
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return Color(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount)
        }
        return (Color(uiColor: base), mix(base, with: .white, 0.35), mix(base, with: .black, 0.3), mix(base, with: .white, 0.25))
    }

    /// 遠い列車から順に並べた配置
    static func layout(trains: [ScopeTrain], rides: [String: RideLine], user: GeoPoint, heights: Heights, attitude: CameraAttitude,
                       tangents: (horizontal: Double, vertical: Double), size: CGSize, now: Date) -> [Item] {
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
        let nearestIDs = Set(trains.sorted { $0.distance < $1.distance }.prefix(maxShapeTrains).map(\.id))
        var items: [Item] = []
        for train in trains.sorted(by: { $0.distance > $1.distance }) {
            guard let ride = rides[train.railwayID] else { continue }
            let path = ride.path
            let headAlong = min(max(train.headAlong(at: now), 0), path.length)
            let head = path.point(atAlong: headAlong) ?? train.head
            let distance = GeoMath.distance(user, head)
            let lineColor = UIColor(hex: train.colorHex) ?? .systemGray
            let delayed = train.delay.tone == .delayed
            let outline = delayed ? TrainColors.color(.delayed) : Color.black.opacity(0.65)
            let outlineWidth: CGFloat = delayed ? 2 : 1
            let drop = WaypointElevation.curvatureDrop(distance: distance)
            let caption = train.caption

            var shapeItem: Item?
            if nearestIDs.contains(train.id), distance <= shapeDistance {
                let palette = shades(lineColor)
                var faces: [(depth: Double, face: Face)] = []
                var headTop: CGPoint?
                var headHeight: CGFloat = 0
                var headCenter: CGPoint?
                let centers = ScopeTrainGeometry.carCenters(headAlong: headAlong, forward: train.forward, cars: train.cars, pathLength: path.length)
                for (index, along) in centers.enumerated() {
                    guard let center = path.point(atAlong: along), let bearing = path.bearing(atAlong: along, forward: train.forward) else { continue }
                    let carDrop = WaypointElevation.curvatureDrop(distance: GeoMath.distance(user, center))
                    // 車両ごとに、その位置の線路の高さに置く(高架・地上・地下)
                    let track = ride.trackHeight(atAlong: along, elevated: heights.elevated, underground: heights.underground)
                    let isUnderground = drawsAsOutline(track)
                    let corners = ScopeTrainGeometry.corners(center: center, bearing: bearing, base: heights.base(track) - carDrop, user: user)
                    let projected = corners.map { project($0, attitude: attitude, tangents: tangents, size: size) }
                    // 自分の後ろ側に回り込む車両は描かない
                    guard projected.allSatisfy({ $0 != nil }) else { continue }
                    let points = projected.compactMap { $0 }
                    let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                    if index == 0 {
                        headTop = points.min { $0.y < $1.y }
                        headHeight = bounds.height
                        headCenter = CGPoint(x: bounds.midX, y: bounds.midY)
                    }
                    guard bounds.intersects(screen) else { continue }
                    let isHead = index == 0
                    let depth = GeoMath.distance(user, center)
                    for face in ScopeTrainGeometry.visibleFaces(corners) {
                        let color: Color
                        switch face {
                        case .top: color = palette.top
                        case .front, .back: color = palette.end
                        case .left, .right: color = isHead ? palette.headSide : palette.side
                        }
                        faces.append((depth, Face(points: face.indices.map { points[$0] }, color: color, isUnderground: isUnderground)))
                    }
                }
                if let headTop, let headCenter, headHeight >= minimumShapeHeight, !faces.isEmpty {
                    // 遠い車両の面から描く
                    let ordered = faces.sorted { $0.depth > $1.depth }.map { $0.face }
                    shapeItem = Item(id: train.id, distance: distance, kind: .shape(faces: ordered), color: palette.side, isDelayed: delayed, outline: outline,
                                     outlineWidth: outlineWidth, labelAnchor: CGPoint(x: headTop.x, y: headTop.y - 4), hitPoint: headCenter,
                                     caption: caption)
                }
            }
            if let shapeItem {
                items.append(shapeItem)
                continue
            }
            // 遠い列車は、進行方向の矢印が入ったリングの印(地点の印と同じ大きさの規則)
            let headTrack = ride.trackHeight(atAlong: headAlong, elevated: heights.elevated, underground: heights.underground)
            let middle = heights.base(headTrack) + ScopeTrainGeometry.carHeight / 2 - drop
            guard let center = project(vector(head, up: middle, user: user), attitude: attitude, tangents: tangents, size: size),
                  CGRect(origin: .zero, size: size).contains(center) else { continue }
            var arrow: Double?
            if let heading = train.heading {
                let rad = heading * .pi / 180
                let aheadPoint = GeoMath.offset(head, east: sin(rad) * 40, north: cos(rad) * 40)
                if let ahead = project(vector(aheadPoint, up: middle, user: user), attitude: attitude, tangents: tangents, size: size) {
                    let dx = ahead.x - center.x
                    let dy = ahead.y - center.y
                    if dx * dx + dy * dy > 0.25 { arrow = atan2(Double(dy), Double(dx)) }
                }
            }
            let ring = WaypointMarkStyle.ringDiameter
            items.append(Item(id: train.id, distance: distance,
                              kind: .ring(center: center, inner: WaypointMarkStyle.innerDiameter(distance: distance), arrow: arrow,
                                          isUnderground: drawsAsOutline(headTrack)),
                              color: Color(uiColor: lineColor), isDelayed: delayed, outline: outline, outlineWidth: outlineWidth,
                              labelAnchor: CGPoint(x: center.x, y: center.y + ring / 2 + 4 + 16), hitPoint: center, caption: caption))
        }
        return items
    }

    static func draw(_ context: inout GraphicsContext, items: [Item]) {
        for item in items {
            switch item.kind {
            case .shape(let faces):
                for face in faces {
                    var path = Path()
                    path.addLines(face.points)
                    path.closeSubpath()
                    if face.isUnderground {
                        // 地下の車両は、塗らずに半透明の破線の輪郭だけ(地面の下にいることが分かるように)
                        context.stroke(path, with: .color(face.color.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    } else {
                        context.fill(path, with: .color(face.color))
                        context.stroke(path, with: .color(item.outline), lineWidth: item.outlineWidth)
                    }
                }
            case .ring(let center, let inner, let arrow, let isUnderground):
                if isUnderground {
                    context.opacity = 0.55
                }
                let ring = WaypointMarkStyle.ringDiameter
                let line = WaypointMarkStyle.ringLineWidth
                let ringRect = CGRect(x: center.x - ring / 2, y: center.y - ring / 2, width: ring, height: ring)
                context.fill(Path(ellipseIn: ringRect.insetBy(dx: line, dy: line)), with: .color(Color.white.opacity(0.35)))
                let innerSize = max(inner, 14)
                context.fill(Path(ellipseIn: CGRect(x: center.x - innerSize / 2, y: center.y - innerSize / 2, width: innerSize, height: innerSize)),
                             with: .color(item.color))
                context.stroke(Path(ellipseIn: ringRect.insetBy(dx: -0.5, dy: -0.5)), with: .color(Color.white.opacity(0.9)), lineWidth: 1)
                // リングは黒(遅れがあれば遅れの色)
                context.stroke(Path(ellipseIn: ringRect.insetBy(dx: line / 2, dy: line / 2)), with: .color(item.isDelayed ? item.outline : .black),
                               lineWidth: line)
                if let arrow {
                    // 進行方向の矢印(リングの中)
                    let length = ring / 2 - line - 3
                    let direction = CGPoint(x: cos(arrow), y: sin(arrow))
                    let normal = CGPoint(x: -direction.y, y: direction.x)
                    var head = Path()
                    head.move(to: CGPoint(x: center.x + direction.x * length, y: center.y + direction.y * length))
                    head.addLine(to: CGPoint(x: center.x - direction.x * length * 0.5 + normal.x * length * 0.6,
                                             y: center.y - direction.y * length * 0.5 + normal.y * length * 0.6))
                    head.addLine(to: CGPoint(x: center.x - direction.x * length * 0.2, y: center.y - direction.y * length * 0.2))
                    head.addLine(to: CGPoint(x: center.x - direction.x * length * 0.5 - normal.x * length * 0.6,
                                             y: center.y - direction.y * length * 0.5 - normal.y * length * 0.6))
                    head.closeSubpath()
                    context.fill(head, with: .color(.white))
                    context.stroke(head, with: .color(.black), lineWidth: 1)
                }
                context.opacity = 1
            }
            let label = context.resolve(Text(item.caption).font(.system(size: 11, weight: .semibold)).foregroundColor(.white))
            let labelSize = label.measure(in: CGSize(width: 240, height: 40))
            let rect = CGRect(x: item.labelAnchor.x - labelSize.width / 2 - 5, y: item.labelAnchor.y - labelSize.height - 4,
                              width: labelSize.width + 10, height: labelSize.height + 4)
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(Color.black.opacity(0.55)))
            context.draw(label, in: rect.insetBy(dx: 5, dy: 2))
        }
    }

    /// タップした位置に一番近い列車(44pt以内)。近い列車が手前なので、同じくらいなら近いほう。
    static func hit(_ point: CGPoint, items: [Item]) -> String? {
        let candidates = items.map { item -> (id: String, gap: CGFloat, distance: Double) in
            (item.id, hypot(item.hitPoint.x - point.x, item.hitPoint.y - point.y), item.distance)
        }
        .filter { $0.gap <= 44 }
        return candidates.min { abs($0.gap - $1.gap) > 8 ? $0.gap < $1.gap : $0.distance < $1.distance }?.id
    }
}

/// カメラの映像の上に電車を描く(1枚の Canvas。遠い列車から描くので、近い列車が手前)。タップで列車の詳細。
struct ScopeTrainOverlay: View {
    @Environment(AppEnvironment.self) private var env
    let feed: ScopeTrainFeed
    let attitude: CameraAttitude
    let tangents: (horizontal: Double, vertical: Double)
    let onSelect: (String) -> Void

    var body: some View {
        let user = feed.userPoint
        let settings = env.settings
        let heights = ScopeTrainRenderer.Heights(observerAltitude: feed.observerAltitude, handHeight: settings.scopeHandHeight,
                                                 elevated: settings.scopeElevatedHeight, underground: settings.scopeUndergroundDepth)
        GeometryReader { geometry in
            Canvas(rendersAsynchronously: false) { context, size in
                guard let user else { return }
                let items = ScopeTrainRenderer.layout(trains: feed.trains, rides: feed.rides, user: user, heights: heights, attitude: attitude,
                                                      tangents: tangents, size: size, now: env.movement.currentTime())
                ScopeTrainRenderer.draw(&context, items: items)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard let user else { return }
                let items = ScopeTrainRenderer.layout(trains: feed.trains, rides: feed.rides, user: user, heights: heights, attitude: attitude,
                                                      tangents: tangents, size: geometry.size, now: env.movement.currentTime())
                if let id = ScopeTrainRenderer.hit(value.location, items: items) { onSelect(id) }
            })
        }
    }
}

/// 列車の詳細(移動タブと同じ: 停車駅と到着予定、遅れ)
struct ScopeTrainDetailSheet: View {
    struct Target: Identifiable, Equatable {
        var selection: TrainLiveSelection
        var id: String {
            switch selection {
            case .train(let id): return "train:" + id
            case .station(let id): return "station:" + id
            case .line(let id): return "line:" + id
            }
        }
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let target: Target

    var body: some View {
        NavigationStack {
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = env.movement.currentTime(real: context.date)
                    TrainSelectionCard(board: TrainLiveBoard(env: env, now: now, filter: .all, directionNames: [:]), selection: target.selection) {
                        dismiss()
                    }
                }
                .padding()
            }
            .navigationTitle("列車の詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// スコープの「電車」。対象の路線の列車を、近い順に一覧と地図で出し、カメラ表示・コンパス表示を開く。
struct ScopeTrainsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var feed = ScopeTrainFeed(reason: "scope.list")
    @State private var located: GeoPoint?
    @State private var locatedAltitude: Double?
    @State private var selection: TrainLiveSelection?
    @State private var detail: ScopeTrainDetailSheet.Target?

    static let radiusChoices: [Double] = [1, 2, 3, 5, 10]

    var body: some View {
        @Bindable var settings = env.settings
        List {
            if env.movement.isVirtual {
                Section {
                    Label("デバッグ中(仮想の位置と時刻で表示しています)", systemImage: "ladybug.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            Section {
                NavigationLink {
                    ScopeSightView(mode: .camera, source: .trains)
                } label: {
                    Label("カメラで見る", systemImage: "camera.viewfinder")
                }
                NavigationLink {
                    ScopeSightView(mode: .compass, source: .trains)
                } label: {
                    Label("コンパスで見る", systemImage: "safari")
                }
            } footer: {
                Text("列車の位置は、移動タブと同じく、保存した時刻表から計算して遅れで補正したものです(実際の在線位置ではありません)。新しい通信はなく、遅れの取得も移動タブと同じ規則です。電車の形は、各社の公式サイトで調べた両数で、線路の高さ(高架・地上・地下)に置きます。地下の区間の車両は、破線の輪郭だけで描きます。
\(ODPTAttributionView.heightAttribution)")
            }
            Section {
                Picker("対象の路線", selection: $settings.scopeTrainTarget) {
                    ForEach(ScopeTrainTarget.allCases) { Text($0.label).tag($0) }
                }
                if settings.scopeTrainTarget == .nearby {
                    Picker("距離", selection: $settings.scopeTrainRadiusKm) {
                        ForEach(Self.radiusChoices, id: \.self) { Text("\(Int($0))km以内").tag($0) }
                    }
                }
                Stepper(value: $settings.scopeTrainMaxCount, in: 5...40, step: 5) {
                    Text("表示する列車: 近い順に\(settings.scopeTrainMaxCount)本まで")
                }
            } header: {
                Text("表示する列車")
            } footer: {
                Text(settings.scopeTrainTarget == .nearby
                     ? "現在地から\(Int(settings.scopeTrainRadiusKm))km以内を通る路線のうち、列車ごとの時刻表を保存している路線だけが対象です。"
                     : "移動タブで登録した路線のうち、列車ごとの時刻表を保存している路線が対象です。")
            }
            Section {
                // 移動タブの地図をそのまま使い、スコープで選んだ列車だけを出す
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TrainLiveMapView(board: TrainLiveBoard(env: env, now: env.movement.currentTime(real: context.date), filter: .all, directionNames: [:])
                                        .restricted(to: Set(feed.trains.map(\.id))),
                                     selectedRailwayID: TrainRailwaySelection.all, selection: $selection, memoryKey: "scope.trains")
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            Section {
                if feed.trains.isEmpty {
                    Text(emptyText).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(feed.trains) { train in
                    Button {
                        detail = ScopeTrainDetailSheet.Target(selection: .train(train.id))
                    } label: {
                        ScopeTrainRow(train: train)
                    }
                }
            } header: {
                Text("近い順")
            }
        }
        .onAppear {
            // 位置のデバッグの間は、仮想の位置と時刻を進める(移動タブと同じ仕組み)
            if env.movement.isVirtual { env.movement.setVisible(true) }
            feed.start(env: env, user: { [movement = env.movement] in
                movement.isVirtual ? movement.currentPoint : located
            }, observer: { [elevation = env.elevation, settings = env.settings] in
                guard settings.scopeUsesHeight, let located else { return nil }
                return elevation.observerHeight(latitude: located.latitude, longitude: located.longitude, gpsAltitude: locatedAltitude)?.meters
            })
        }
        .onDisappear {
            feed.stop(env: env)
            if env.movement.isVirtual { env.movement.setVisible(false) }
        }
        .task {
            // 一覧と地図の距離のために、現在地を1回だけ取る(取ったら測位は止まる)
            if let location = try? await env.location.currentLocation() {
                located = GeoPoint(location.coordinate)
                locatedAltitude = location.verticalAccuracy > 0 ? location.altitude : nil
                // 高低差のために、地面の標高を取る(100m以内で取った値があれば使う。自動更新の規則に従う)
                if env.settings.scopeUsesHeight, env.settings.scopeHeightSource == .groundPlusHand {
                    env.elevation.updateGround(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                }
                feed.compute(env: env)
            }
        }
        .onChange(of: selection) { _, new in
            guard let new else { return }
            detail = ScopeTrainDetailSheet.Target(selection: new)
            selection = nil
        }
        .sheet(item: $detail) { target in
            ScopeTrainDetailSheet(target: target)
        }
    }

    private var emptyText: String {
        if feed.userPoint == nil { return "現在地を取得中…" }
        if feed.railwayIDs.isEmpty {
            return env.settings.scopeTrainTarget == .nearby
                ? "近くを通る路線で、列車ごとの時刻表を保存しているものがありません。"
                : "登録した路線の列車ごとの時刻表がありません。移動タブで路線を登録して、時刻表を取得してください。"
        }
        return "今走っている列車はありません。"
    }
}

struct ScopeTrainRow: View {
    let train: ScopeTrain

    var body: some View {
        HStack(spacing: 10) {
            RailwayColorBar(colorHex: train.colorHex, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(train.label).font(.headline).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                Text(train.lineName + (train.kind == .subway ? "・地下鉄" : "") + (train.section == .unknown ? "" : "・" + train.section.label))
                    .font(.caption).foregroundStyle(.secondary)
                Text(train.delay.label).font(.caption).foregroundStyle(TrainColors.color(train.delay.tone))
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(WaypointMath.distanceText(train.distance)).font(.headline).monospacedDigit().foregroundStyle(Color.primary)
                if let height = train.heightCaption {
                    Text(height).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if train.isApproaching {
                    Text("接近中").font(.caption.weight(.bold)).foregroundStyle(.orange)
                }
            }
        }
    }
}

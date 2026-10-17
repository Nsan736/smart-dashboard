import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit

/// 路線の種類(両数の目安と、「地下鉄」の表示に使う)
enum RailwayKind: String, CaseIterable, Identifiable, Codable {
    case subway
    case railway
    case monorail
    case guideway
    case tram

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subway: return "地下鉄"
        case .railway: return "鉄道"
        case .monorail: return "モノレール"
        case .guideway: return "新交通"
        case .tram: return "路面電車"
        }
    }

    /// 両数の目安の初期値
    var defaultCars: Int {
        switch self {
        case .subway, .railway: return 10
        case .monorail: return 4
        case .guideway: return 6
        case .tram: return 1
        }
    }

    /// 地下鉄として扱う事業者(路線名に「線」しかなくても地下鉄と分かるように)
    static let subwayOperators: Set<String> = ["odpt.Operator:TokyoMetro", "odpt.Operator:Toei", "odpt.Operator:YokohamaMunicipal"]

    /// 路線の名前とIDから決める。データには路線の種類がないので、名前で判断する。
    static func classify(railwayID: String, name: String) -> RailwayKind {
        if name.contains("モノレール") || railwayID.contains("Monorail") { return .monorail }
        if name.contains("トラム") || name.contains("荒川線") || name.contains("路面") || railwayID.hasSuffix(".Arakawa") { return .tram }
        if name.contains("ライナー") || name.contains("ゆりかもめ") || name.contains("新交通") || railwayID.contains("Yurikamome")
            || railwayID.hasSuffix(".NipporiToneri") { return .guideway }
        if name.contains("地下鉄") { return .subway }
        if let op = ODPTID.operatorID(of: railwayID), subwayOperators.contains(op) { return .subway }
        return .railway
    }
}

/// スコープの電車の対象の路線
enum ScopeTrainTarget: String, CaseIterable, Identifiable {
    /// 登録した路線(運行情報の路線と、時刻表の駅がある路線)
    case registered
    /// 現在地から一定の距離以内を通る路線(列車ごとの時刻表を保存している路線だけ)
    case nearby

    var id: String { rawValue }

    var label: String {
        switch self {
        case .registered: return "登録した路線"
        case .nearby: return "近くを通る路線"
        }
    }
}

/// スコープに出す列車(1秒ごとに計算した、ある時刻の状態)
struct ScopeTrain: Equatable, Identifiable {
    var id: String
    var railwayID: String
    var lineName: String
    var colorHex: String?
    var number: String
    var trainType: String
    var destination: String
    var delay: DelaySource
    var kind: RailwayKind
    var cars: Int
    /// 路線の線の上の先頭の位置(線の始点からの距離、m)
    var along: Double
    /// 線に沿った速さ(m/秒。線の始点から終点へ向かうときに正)。描くときに、計算した時刻からの分だけ先へ進める。
    var speed: Double
    /// 線の始点から終点へ向かっているか(先頭の向き)
    var forward: Bool
    var head: GeoPoint
    /// 進行方向(度、真北基準)
    var heading: Double?
    /// 現在地から先頭までの距離(m)
    var distance: Double
    var isApproaching: Bool
    var isStopped: Bool
    var computedAt: Date
    /// 先頭のいる区間の種類(高架・地上・地下・不明)
    var section: TrackSection = .unknown
    /// 先頭の線路の高さ(m)。分からなければ nil。
    var trackAltitude: Double? = nil
    /// 区間の種類か地面の標高が分からず、地面の高さに置いている
    var heightIsEstimate = true
    /// 高低差(m、線路の高さ − 自分の目の高さ)。自分の高さか線路の高さが分からなければ nil。
    var heightDifference: Double? = nil
    /// 両数を列車ごとに見分けられず、目安の両数を使っている
    var carsAreEstimate = true

    /// 「急 西馬込行」
    var label: String {
        let badge = TrainBoard.typeBadge(trainType).label
        return (badge.isEmpty ? "" : badge + " ") + (destination.isEmpty ? "行先不明" : destination + "行")
    }

    /// 高さの表示「↑8m」「地下 ↓15m」「地下」。分からなければ nil。
    var heightCaption: String? {
        if let heightDifference {
            return (section == .underground ? "地下 " : "") + WaypointMath.heightText(heightDifference)
        }
        return section == .underground ? "地下" : nil
    }

    /// 「高さは目安」「接近中」「地下鉄」
    var notes: [String] {
        var notes: [String] = []
        if heightIsEstimate { notes.append("高さは目安") }
        if isApproaching { notes.append("接近中") }
        // 地下にいるかが分からない地下鉄の列車には、地下鉄と添える
        if kind == .subway, section == .unknown || heightIsEstimate { notes.append("地下鉄") }
        return notes
    }

    /// 印の近くに出す文字「急 西馬込行 350m ↑8m 接近中」「各停 渋谷行 1.2km 地下 ↓15m」
    var caption: String {
        var text = "\(label) \(WaypointMath.distanceText(distance))"
        if let heightCaption { text += " " + heightCaption }
        if !notes.isEmpty { text += " " + notes.joined(separator: "・") }
        return text
    }

    /// 描く時刻での先頭の位置(計算した時刻からの分だけ、速さで先へ進める。1.5秒より先へは進めない)
    func headAlong(at date: Date) -> Double {
        along + speed * min(1.5, max(0, date.timeIntervalSince(computedAt)))
    }
}

/// 対象の路線と列車の選び方(通信しない)
enum ScopeTrainSelection {
    /// 対象の路線。available: 列車ごとの時刻表を保存している路線と、その線(なければ nil)。
    static func railways(target: ScopeTrainTarget, registered: Set<String>, available: [(id: String, path: GeoPath?)],
                         user: GeoPoint?, radius: Double) -> [String] {
        switch target {
        case .registered:
            return available.map { $0.id }.filter { registered.contains($0) }
        case .nearby:
            guard let user else { return [] }
            return available.compactMap { item in
                guard let path = item.path, let projection = path.project(user), projection.lateral <= radius else { return nil }
                return item.id
            }
        }
    }

    /// 現在地に近い順に、上限の本数まで
    static func nearest(_ trains: [ScopeTrain], limit: Int) -> [ScopeTrain] {
        Array(trains.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.id < $1.id }.prefix(max(0, limit)))
    }

    /// 近づいてくるか: 走っていて、進行方向と、列車から現在地への方向の差が90度より小さい
    static func isApproaching(heading: Double?, train: GeoPoint, user: GeoPoint, isStopped: Bool) -> Bool {
        guard !isStopped, let heading else { return false }
        let toUser = WaypointMath.bearing(fromLatitude: train.latitude, longitude: train.longitude, toLatitude: user.latitude, longitude: user.longitude)
        return abs(WaypointMath.difference(from: heading, to: toUser)) < 90
    }

    /// 前の計算からの速さ(m/秒)。止まっているとき、前の値がないとき、飛びすぎたとき(別の区間に移った)は0。
    static func speed(previousAlong: Double?, previousTime: Date?, along: Double, time: Date, isStopped: Bool) -> Double {
        guard !isStopped, let previousAlong, let previousTime else { return 0 }
        let dt = time.timeIntervalSince(previousTime)
        guard dt > 0.2, dt < 5 else { return 0 }
        let value = (along - previousAlong) / dt
        return abs(value) > 45 ? 0 : value
    }
}

/// 車両の箱の形(カメラ越しに描く)
enum ScopeTrainGeometry {
    static let carLength = 20.0
    static let carWidth = 2.8
    static let carHeight = 3.5

    /// 車両の中心の位置(線に沿った距離)。先頭から後ろへ並べる。線の外に出る車両は入れない。
    static func carCenters(headAlong: Double, forward: Bool, cars: Int, pathLength: Double) -> [Double] {
        (0..<max(1, cars)).compactMap { index in
            let offset = (Double(index) + 0.5) * carLength
            let center = forward ? headAlong - offset : headAlong + offset
            return center >= 0 && center <= pathLength ? center : nil
        }
    }

    /// 箱の8つの角。基準の座標系(x=北、y=西、z=上。現在地の目の高さが原点)。
    /// 0〜3が下の面(後ろ左、後ろ右、前右、前左)、4〜7が上の面(同じ順)。bearing は車両の前の向き。
    static func corners(center: GeoPoint, bearing: Double, base: Double, user: GeoPoint) -> [Vector3] {
        let local = GeoMath.local(center, origin: user)
        let rad = bearing * .pi / 180
        // 東・北の向きでの、前と右の単位ベクトル
        let front = (east: sin(rad), north: cos(rad))
        let right = (east: cos(rad), north: -sin(rad))
        let halfL = carLength / 2
        let halfW = carWidth / 2
        let footprint: [(Double, Double)] = [(-halfL, -halfW), (-halfL, halfW), (halfL, halfW), (halfL, -halfW)]
        var result: [Vector3] = []
        for z in [base, base + carHeight] {
            for (l, w) in footprint {
                let east = local.x + front.east * l + right.east * w
                let north = local.y + front.north * l + right.north * w
                result.append(Vector3(x: north, y: -east, z: z))
            }
        }
        return result
    }

    enum Face: CaseIterable {
        case front, back, right, left, top

        /// 角の番号(外から見て、まわりの順)
        var indices: [Int] {
            switch self {
            case .front: return [3, 2, 6, 7]
            case .back: return [1, 0, 4, 5]
            case .right: return [2, 1, 5, 6]
            case .left: return [0, 3, 7, 4]
            case .top: return [4, 5, 6, 7]
            }
        }
    }

    /// 自分(原点)から見えている面。面の外向きの法線と、面の中心への向きが逆向きなら見える。
    static func visibleFaces(_ corners: [Vector3]) -> [Face] {
        guard corners.count == 8 else { return [] }
        let center = Vector3(x: corners.map(\.x).reduce(0, +) / 8, y: corners.map(\.y).reduce(0, +) / 8, z: corners.map(\.z).reduce(0, +) / 8)
        return Face.allCases.filter { face in
            let points = face.indices.map { corners[$0] }
            let faceCenter = Vector3(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4, z: points.map(\.z).reduce(0, +) / 4)
            let normal = Vector3(x: faceCenter.x - center.x, y: faceCenter.y - center.y, z: faceCenter.z - center.z)
            return Vector3.dot(normal, faceCenter) < 0
        }
    }
}

/// スコープの電車。表示している間だけ、1秒ごとに対象の列車を計算する(通信はしない。遅れの取得は移動タブと同じ規則)。
@MainActor
@Observable
final class ScopeTrainFeed {
    private(set) var trains: [ScopeTrain] = []
    /// 路線ID → 路線の線(車両を線路に沿って並べ、線路の高さを引くのに使う)
    private(set) var rides: [String: RideLine] = [:]
    private(set) var railwayIDs: [String] = []
    private(set) var userPoint: GeoPoint?
    /// 自分の目の高さ(m)。分からなければ nil(高低差を出さず、車両は地面の高さに置く)。
    private(set) var observerAltitude: Double?
    /// 対象の路線はあるが、列車ごとの時刻表がない路線の数
    private(set) var missingSchedules = 0

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var userProvider: (@MainActor () -> GeoPoint?)?
    /// 自分の目の高さ(m)。分からなければ nil(高低差を出さない)。
    @ObservationIgnored private var observerProvider: (@MainActor () -> Double?)?
    /// 遅れの取得を「表示中」にする理由の名前(一覧とカメラ表示で分ける)
    @ObservationIgnored private let reason: String

    var isRunning: Bool { loop != nil }

    init(reason: String = "scope") {
        self.reason = reason
    }

    func start(env: AppEnvironment, user: @escaping @MainActor () -> GeoPoint?, observer: @escaping @MainActor () -> Double? = { nil }) {
        userProvider = user
        observerProvider = observer
        guard loop == nil else { return }
        env.live.setVisible(reason, true)
        loop = Task { [weak self, weak env] in
            if let env {
                await env.trains.loadIfNeeded()
                await env.live.loadIfNeeded()
            }
            while !Task.isCancelled {
                guard let self, let env else { return }
                self.compute(env: env)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop(env: AppEnvironment) {
        loop?.cancel()
        loop = nil
        env.live.setVisible(reason, false)
    }

    func compute(env: AppEnvironment) {
        let settings = env.settings
        let trainsStore = env.trains
        let live = env.live
        let now = env.movement.currentTime()
        let user = userProvider?()
        userPoint = user
        let names = trainsStore.railwayNames
        let available = live.schedules.keys.sorted().map { (id: $0, path: trainsStore.rideLine(for: $0)?.path) }
        let targets = ScopeTrainSelection.railways(target: settings.scopeTrainTarget, registered: trainsStore.registeredRailwayIDs,
                                                   available: available, user: user, radius: settings.scopeTrainRadiusKm * 1000)
        railwayIDs = targets
        missingSchedules = settings.scopeTrainTarget == .registered
            ? trainsStore.registeredRailwayIDs.filter { live.schedules[$0] == nil }.count : 0
        let previous = Dictionary(trains.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var found: [ScopeTrain] = []
        var newRides: [String: RideLine] = [:]
        guard let user else {
            observerAltitude = nil
            trains = []
            return
        }
        // 位置のデバッグの間は、仮想の位置の近くの線路の地面の標高から決める(通信しない)
        let observerAltitude = env.movement.isVirtual
            ? Self.trackGroundAltitude(near: user, rides: targets.compactMap { trainsStore.rideLine(for: $0) }, handHeight: settings.scopeHandHeight)
            : observerProvider?()
        self.observerAltitude = observerAltitude
        for railwayID in targets {
            guard let schedule = live.schedules[railwayID], let ride = trainsStore.rideLine(for: railwayID) else { continue }
            newRides[railwayID] = ride
            let name = names[railwayID] ?? ODPTID.tail(railwayID)
            let line = BoardLine(railwayID: railwayID, name: name, schedule: schedule, shape: trainsStore.shapes[railwayID],
                                 positions: [], ride: ride)
            let kind = RailwayKind.classify(railwayID: railwayID, name: name)
            let carRule = TrainCarResolver.Context(railwayID: railwayID, kind: kind, settings: settings)
            for position in live.positions(for: railwayID, now: now) where !position.isWaitingToDepart {
                guard let fromID = line.stationID(position.fromStation), let toID = line.stationID(position.toStation),
                      let pair = ride.alongPair(fromID, toID) else { continue }
                let along = pair.from + (pair.to - pair.from) * min(1, max(0, position.fraction))
                let forward = pair.to != pair.from ? pair.to > pair.from : (previous[position.id]?.forward ?? true)
                guard let head = ride.path.point(atAlong: along) else { continue }
                let heading = ride.path.bearing(atAlong: along, forward: forward)
                let distance = GeoMath.distance(user, head)
                let cars = TrainCarResolver.cars(for: schedule.trains.first { $0.number == position.number }, schedule: schedule, context: carRule)
                let height = ride.trackHeight(atAlong: along, elevated: settings.scopeElevatedHeight, underground: settings.scopeUndergroundDepth)
                let old = previous[position.id]
                found.append(ScopeTrain(
                    id: position.id, railwayID: railwayID, lineName: name, colorHex: trainsStore.shapes[railwayID]?.colorHex,
                    number: position.number, trainType: position.trainType, destination: position.destination, delay: position.delay,
                    kind: kind, cars: cars.cars, along: along,
                    speed: ScopeTrainSelection.speed(previousAlong: old?.along, previousTime: old?.computedAt, along: along, time: now,
                                                     isStopped: position.isStopped),
                    forward: forward, head: head, heading: heading, distance: distance,
                    isApproaching: ScopeTrainSelection.isApproaching(heading: heading, train: head, user: user, isStopped: position.isStopped),
                    isStopped: position.isStopped, computedAt: now, section: height.section, trackAltitude: height.altitude,
                    // 自分の高さが分からないときも、地面の高さに置くので目安(高さを使わない設定では書かない)
                    heightIsEstimate: height.isEstimate || (observerAltitude == nil && settings.scopeUsesHeight),
                    heightDifference: height.altitude.flatMap { altitude in observerAltitude.map { altitude - $0 } },
                    carsAreEstimate: cars.isEstimate))
            }
        }
        rides = newRides
        trains = ScopeTrainSelection.nearest(found, limit: settings.scopeTrainMaxCount)
    }

    /// 近くの線路(300m以内)の地面の標高 + 手の高さ。仮想の位置で、自分の高さの代わりに使う。
    nonisolated static func trackGroundAltitude(near point: GeoPoint, rides: [RideLine], handHeight: Double) -> Double? {
        var best: (lateral: Double, ground: Double)?
        for ride in rides {
            guard let projection = ride.path.project(point), projection.lateral <= 300,
                  let ground = ride.trackHeight(atAlong: projection.along, elevated: 0, underground: 0).altitude else { continue }
            if best == nil || projection.lateral < best!.lateral { best = (projection.lateral, ground) }
        }
        return best.map { $0.ground + handHeight }
    }

    /// コンパス表示の印(進行方向つき)
    func marks() -> [ScopeMark] {
        trains.map { train in
            var mark = ScopeMark(id: train.id, name: "\(train.lineName) \(train.label)", latitude: train.head.latitude, longitude: train.head.longitude,
                                 color: Color(uiColor: UIColor(hex: train.colorHex) ?? .systemGray))
            mark.travelHeading = train.heading
            mark.note = ([train.heightCaption].compactMap { $0 } + train.notes).joined(separator: "・")
            return mark
        }
    }
}

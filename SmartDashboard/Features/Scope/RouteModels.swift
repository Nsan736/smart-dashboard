import Foundation

/// 緯度経度の1点
struct RoutePoint: Equatable {
    var latitude: Double
    var longitude: Double
}

/// 経路の曲がり角(MKRoute.steps の1つ)。位置は、その案内を行う地点(その区間の最初の点)。
struct RouteTurn: Equatable, Identifiable {
    var id: Int
    var instructions: String
    var latitude: Double
    var longitude: Double
    /// この案内のあとに進む距離(m)
    var distance: Double
}

/// 取得した徒歩の経路
struct RoutePlan: Equatable {
    var destination: ScopeDestination
    /// 経路の線
    var points: [RoutePoint]
    var turns: [RouteTurn]
    /// 全体の距離(m)と所要時間(秒)
    var distance: Double
    var expectedTravelTime: TimeInterval
    var fetchedAt: Date

    var summaryText: String {
        "\(RouteText.duration(expectedTravelTime))・\(WaypointMath.distanceText(distance))"
    }
}

enum RouteText {
    /// 「約12分」「約1時間5分」
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "約\(minutes)分" }
        return minutes % 60 == 0 ? "約\(minutes / 60)時間" : "約\(minutes / 60)時間\(minutes % 60)分"
    }
}

/// 位置と経路の線の距離の計算(近い範囲なので、平面に直して計算する)
enum RouteGeometry {
    /// 緯度経度を、origin を原点にしたメートル単位の平面に直す
    static func meters(_ point: RoutePoint, origin: RoutePoint) -> (x: Double, y: Double) {
        let rad = Double.pi / 180
        let x = (point.longitude - origin.longitude) * rad * WaypointMath.earthRadius * cos(origin.latitude * rad)
        let y = (point.latitude - origin.latitude) * rad * WaypointMath.earthRadius
        return (x, y)
    }

    /// 現在地から、経路の線までの最短距離(m)。線が空なら nil。
    static func distanceToPath(from location: RoutePoint, path: [RoutePoint]) -> Double? {
        guard let first = path.first else { return nil }
        guard path.count > 1 else {
            return WaypointMath.distance(fromLatitude: location.latitude, longitude: location.longitude, toLatitude: first.latitude, longitude: first.longitude)
        }
        var best = Double.infinity
        var previous = meters(first, origin: location)
        for point in path.dropFirst() {
            let current = meters(point, origin: location)
            best = min(best, distanceFromOrigin(toSegment: previous, current))
            previous = current
        }
        return best
    }

    /// 原点から線分 ab までの距離
    private static func distanceFromOrigin(toSegment a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return (a.x * a.x + a.y * a.y).squareRoot() }
        let t = max(0, min(1, (-a.x * dx - a.y * dy) / lengthSquared))
        let px = a.x + t * dx
        let py = a.y + t * dy
        return (px * px + py * py).squareRoot()
    }
}

/// 経路の上での進み具合。地図で、通り過ぎた部分を薄く、これからの部分を濃く描くのに使う。
struct RouteProgress: Equatable {
    /// 通り過ぎた部分の線(出発点 → 現在地に一番近い線上の点)
    var passed: [RoutePoint]
    /// これからの部分の線(現在地に一番近い線上の点 → 目的地)
    var remaining: [RoutePoint]
    /// これからの部分の長さ(m)
    var remainingDistance: Double

    /// 現在地に一番近い線上の点で、経路の線を2つに分ける。線が2点未満なら nil。
    static func make(path: [RoutePoint], latitude: Double, longitude: Double) -> RouteProgress? {
        guard path.count > 1 else { return nil }
        let location = RoutePoint(latitude: latitude, longitude: longitude)
        var bestIndex = 0
        var bestT = 0.0
        var bestDistance = Double.infinity
        for index in 1..<path.count {
            let a = RouteGeometry.meters(path[index - 1], origin: location)
            let b = RouteGeometry.meters(path[index], origin: location)
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, (-a.x * dx - a.y * dy) / lengthSquared)) : 0
            let px = a.x + t * dx
            let py = a.y + t * dy
            let distance = (px * px + py * py).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
                bestT = t
            }
        }
        let a = path[bestIndex - 1]
        let b = path[bestIndex]
        let split = RoutePoint(latitude: a.latitude + (b.latitude - a.latitude) * bestT, longitude: a.longitude + (b.longitude - a.longitude) * bestT)
        let passed = Array(path[0..<bestIndex]) + [split]
        let remaining = [split] + Array(path[bestIndex...])
        return RouteProgress(passed: passed, remaining: remaining, remainingDistance: length(of: remaining))
    }

    static func length(of path: [RoutePoint]) -> Double {
        guard path.count > 1 else { return 0 }
        return (1..<path.count).reduce(0.0) { total, index in
            total + WaypointMath.distance(fromLatitude: path[index - 1].latitude, longitude: path[index - 1].longitude,
                                          toLatitude: path[index].latitude, longitude: path[index].longitude)
        }
    }
}

/// 目的地までの残り(距離、時間、到着予定)
struct RouteRemaining: Equatable {
    var distance: Double
    var time: TimeInterval
    var arrival: Date

    /// 残りの時間は、経路全体の所要時間を、残りの距離の割合で案分する
    static func make(plan: RoutePlan, remainingDistance: Double, now: Date) -> RouteRemaining {
        let ratio = plan.distance > 0 ? min(max(remainingDistance / plan.distance, 0), 1) : 0
        let time = plan.expectedTravelTime * ratio
        return RouteRemaining(distance: remainingDistance, time: time, arrival: now.addingTimeInterval(time))
    }

    static let arrivalFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm"
        return formatter
    }()

    var arrivalText: String { Self.arrivalFormatter.string(from: arrival) + "着" }
}

/// 経路の案内の状態。現在地が変わるたびに update を呼ぶ(純粋なロジックで、測位や通信はしない)。
struct RouteNavigator: Equatable {
    /// 曲がり角にこの距離まで近づいたら、次の曲がり角に切り替える(m)
    static let arrivalDistance = 15.0
    /// 経路の線からこの距離より離れたら、経路から外れたとみなす(m)
    static let offRouteDistance = 50.0
    /// 目的地にこの距離まで近づいたら、到着とみなす(m)
    static let destinationDistance = 15.0

    let plan: RoutePlan
    /// 今向かっている曲がり角の番号(plan.turns の中)。すべて通過したら turns.count。
    private(set) var nextIndex: Int
    private(set) var isOffRoute = false
    private(set) var hasArrived = false
    /// 次の曲がり角(なければ目的地)までの距離(m)
    private(set) var distanceToNext: Double?
    /// 経路の上での進み具合(通り過ぎた部分と、これからの部分)
    private(set) var progress: RouteProgress?

    init(plan: RoutePlan) {
        self.plan = plan
        // 最初の案内は出発点そのもの(「◯◯を北に進む」など)なので、位置が出発点と同じなら飛ばす
        nextIndex = 0
        if let first = plan.turns.first, let start = plan.points.first,
           WaypointMath.distance(fromLatitude: first.latitude, longitude: first.longitude, toLatitude: start.latitude, longitude: start.longitude) < 5 {
            nextIndex = 1
        }
    }

    var nextTurn: RouteTurn? {
        plan.turns.indices.contains(nextIndex) ? plan.turns[nextIndex] : nil
    }

    /// その次の曲がり角
    var turnAfterNext: RouteTurn? {
        plan.turns.indices.contains(nextIndex + 1) ? plan.turns[nextIndex + 1] : nil
    }

    /// 目的地までの残り。現在地がまだ分からなければ、経路の全体。
    func remaining(now: Date) -> RouteRemaining {
        RouteRemaining.make(plan: plan, remainingDistance: progress?.remainingDistance ?? plan.distance, now: now)
    }

    mutating func update(latitude: Double, longitude: Double) {
        let destination = plan.destination
        let toDestination = WaypointMath.distance(fromLatitude: latitude, longitude: longitude,
                                                  toLatitude: destination.latitude, longitude: destination.longitude)
        if toDestination <= Self.destinationDistance { hasArrived = true }
        // 近づいた曲がり角は通過したものとして、次へ進める(続けて近い曲がり角があれば、まとめて進める)
        while let turn = nextTurn,
              WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: turn.latitude, longitude: turn.longitude) <= Self.arrivalDistance {
            nextIndex += 1
        }
        if let turn = nextTurn {
            distanceToNext = WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: turn.latitude, longitude: turn.longitude)
        } else {
            distanceToNext = toDestination
        }
        progress = RouteProgress.make(path: plan.points, latitude: latitude, longitude: longitude)
        let offset = RouteGeometry.distanceToPath(from: RoutePoint(latitude: latitude, longitude: longitude), path: plan.points)
        isOffRoute = !hasArrived && (offset ?? 0) > Self.offRouteDistance
    }

    /// 画面の下に大きく出す案内。「次：あと40mで 右折して◯◯に入る」
    var guidanceText: String {
        if hasArrived { return "目的地(\(plan.destination.name))の近くです" }
        let distance = distanceToNext.map { "あと\(WaypointMath.distanceText($0))" } ?? ""
        if let turn = nextTurn {
            let instruction = turn.instructions.isEmpty ? "次の曲がり角" : turn.instructions
            return "次：\(distance)で \(instruction)"
        }
        return "次：\(distance)で 目的地(\(plan.destination.name))"
    }
}

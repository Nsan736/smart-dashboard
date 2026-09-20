import CoreLocation
import Foundation
import MapKit
import Observation

/// 周辺の施設の検索。通信は iOS(MapKit)が行うので、アプリからは受信量を計測できない。
/// 同じカテゴリ・同じ範囲の結果は数分使い回し、100m以上動いたときだけ探し直す。
@MainActor
@Observable
final class NearbyStore {
    private(set) var category: NearbyCategory?
    private(set) var places: [NearbyPlace] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 検索した位置と時刻
    private(set) var searchedAt: Date?
    /// MapKit に検索を頼んだ回数(今回の起動中)
    private(set) var requestCount = 0

    private struct CacheEntry {
        var latitude: Double
        var longitude: Double
        var radius: Int
        var time: Date
        var places: [NearbyPlace]
    }

    @ObservationIgnored private var cache: [NearbyCategory: CacheEntry] = [:]

    /// カメラ表示とコンパス表示に出す印
    var marks: [ScopeMark] {
        places.map { ScopeMark(id: $0.id, name: $0.name, latitude: $0.latitude, longitude: $0.longitude, color: $0.category.color) }
    }

    func search(_ category: NearbyCategory, latitude: Double, longitude: Double, radius: Int, force: Bool = false) async {
        self.category = category
        errorMessage = nil
        let now = Date()
        if !force, let entry = cache[category],
           NearbyCachePolicy.canReuse(cachedAt: entry.time, cachedLatitude: entry.latitude, cachedLongitude: entry.longitude, cachedRadius: entry.radius,
                                      now: now, latitude: latitude, longitude: longitude, radius: radius) {
            places = entry.places
            searchedAt = entry.time
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = category.query
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: Double(radius) * 2, longitudinalMeters: Double(radius) * 2)
        requestCount += 1
        do {
            let response = try await MKLocalSearch(request: request).start()
            let found = response.mapItems.enumerated().map { index, item -> NearbyPlace in
                let coordinate = item.placemark.coordinate
                return NearbyPlace(
                    id: "\(category.rawValue)-\(index)-\(coordinate.latitude)-\(coordinate.longitude)",
                    name: item.name ?? category.label, latitude: coordinate.latitude, longitude: coordinate.longitude, category: category,
                    address: item.placemark.title, phone: item.phoneNumber, url: item.url,
                    distance: WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: coordinate.latitude, longitude: coordinate.longitude),
                    bearing: WaypointMath.bearing(fromLatitude: latitude, longitude: longitude, toLatitude: coordinate.latitude, longitude: coordinate.longitude))
            }
            // 途中でカテゴリが変わっていたら、表示は更新しない(キャッシュには入れる)
            let arranged = NearbyPlace.arranged(found, radius: Double(radius))
            cache[category] = CacheEntry(latitude: latitude, longitude: longitude, radius: radius, time: now, places: arranged)
            if self.category == category {
                places = arranged
                searchedAt = now
            }
        } catch {
            if self.category == category {
                places = []
                errorMessage = (error as? MKError)?.code == .placemarkNotFound ? nil : "周辺の施設を探せませんでした(オフラインの可能性があります)"
                searchedAt = (error as? MKError)?.code == .placemarkNotFound ? now : nil
            }
        }
    }
}

enum RouteConfig {
    /// 経路を取り直す最短の間隔(連打や、外れた状態での取り直しの繰り返しを防ぐ)
    static let minimumRefetchInterval: TimeInterval = 20
}

/// 徒歩の経路の取得(MKDirections)と、案内の状態。通信は iOS(MapKit)が行う。
@MainActor
@Observable
final class RouteStore {
    private(set) var destination: ScopeDestination?
    private(set) var navigator: RouteNavigator?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var requestCount = 0

    var plan: RoutePlan? { navigator?.plan }

    func setDestination(_ destination: ScopeDestination?) {
        guard destination != self.destination else { return }
        self.destination = destination
        navigator = nil
        errorMessage = nil
    }

    /// 取り直してよいか(前回の取得から、最短の間隔が空いているか)
    nonisolated static func canRefetch(lastFetchedAt: Date?, now: Date) -> Bool {
        guard let lastFetchedAt else { return true }
        return now.timeIntervalSince(lastFetchedAt) >= RouteConfig.minimumRefetchInterval
    }

    func fetch(fromLatitude latitude: Double, longitude: Double) async {
        guard let destination, !isLoading else { return }
        guard Self.canRefetch(lastFetchedAt: plan?.fetchedAt, now: Date()) else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)))
        request.transportType = .walking
        requestCount += 1
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first, destination == self.destination else {
                if response.routes.isEmpty { errorMessage = "経路が見つかりませんでした" }
                return
            }
            navigator = RouteNavigator(plan: Self.plan(from: route, destination: destination, now: Date()))
            navigator?.update(latitude: latitude, longitude: longitude)
        } catch {
            errorMessage = "経路を取得できませんでした(オフライン、または徒歩の経路がない可能性があります)"
        }
    }

    /// 案内中に、現在地が変わるたびに呼ぶ
    func updateLocation(latitude: Double, longitude: Double) {
        navigator?.update(latitude: latitude, longitude: longitude)
    }

    private static func plan(from route: MKRoute, destination: ScopeDestination, now: Date) -> RoutePlan {
        let turns = route.steps.enumerated().compactMap { index, step -> RouteTurn? in
            guard step.polyline.pointCount > 0 else { return nil }
            let start = step.polyline.points()[0].coordinate
            return RouteTurn(id: index, instructions: step.instructions, latitude: start.latitude, longitude: start.longitude, distance: step.distance)
        }
        return RoutePlan(destination: destination, points: coordinates(of: route.polyline).map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) },
                         turns: turns, distance: route.distance, expectedTravelTime: route.expectedTravelTime, fetchedAt: now)
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&result, range: NSRange(location: 0, length: polyline.pointCount))
        return result
    }
}

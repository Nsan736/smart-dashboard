import AudioToolbox
import Foundation
import Observation
import UIKit

enum RouteRailwayResolver {
    /// 路線IDから事業者IDを求める(例: odpt.Railway:Toei.Mita → odpt.Operator:Toei)
    static func operatorID(forRailway railwayID: String) -> String? {
        ODPTID.operatorID(of: railwayID)
    }
}

/// 降りる駅の知らせ(バイブ)
@MainActor
enum JourneyFeedback {
    static func play() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// 行きたい駅までの経路の検索と、選んだ経路の案内(乗車中の判定と連動する)。
/// 検索は保存した時刻表だけで行い、通信しない。足りない路線の時刻表だけは、Wi-Fiなら自動で、モバイル通信ではボタンで取得する。
@MainActor
@Observable
final class JourneyStore {
    enum OriginMode: String, CaseIterable, Identifiable {
        case selectedStation
        case nearestStation

        var id: String { rawValue }

        var label: String {
            switch self {
            case .selectedStation: return "この駅から"
            case .nearestStation: return "最寄り駅から"
            }
        }
    }

    private(set) var destination: StationGroup?
    var originMode: OriginMode = .selectedStation
    private(set) var options: [JourneyOption] = []
    /// 経路の検索に足りない路線(時刻表を保存していない路線)
    private(set) var missingRailways: [RouteRailway] = []
    private(set) var message: String?
    private(set) var isSearching = false
    private(set) var isDownloading = false
    /// 検索した出発の駅
    private(set) var searchedOrigin: StationGroup?
    /// 出発の駅まで歩く距離(現在地から3km以内のときだけ。最初の電車の「間に合う」に使う)
    private(set) var walkDistance: Double?
    private(set) var selected: Journey?
    private(set) var tracking: JourneyTracking.Status = .notRiding
    /// 降りる駅の知らせ
    private(set) var alightNotice: String?

    @ObservationIgnored private let trains: TrainStore
    @ObservationIgnored private let live: TrainLiveStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var alerted: Set<Int> = []
    @ObservationIgnored private var departureCache: [String: [StationDeparture]] = [:]

    /// 現在地から出発の駅まで歩く時間を考える距離の上限
    static let walkConsideredDistance = 3000.0

    init(trains: TrainStore, live: TrainLiveStore, settings: AppSettings, network: NetworkMonitor) {
        self.trains = trains
        self.live = live
        self.settings = settings
        self.network = network
    }

    // MARK: - 駅の時刻表

    /// 駅の時刻表(遅れを反映する前)。運行日と時刻表が変わるまで使い回す。
    func departures(railwayID: String, stationID: String, now: Date) -> [StationDeparture] {
        guard let schedule = live.schedules[railwayID] else { return [] }
        let resolver = settings.dayTypeResolver
        let key = [railwayID, stationID, DayTypeResolver.dayKey(now), String(schedule.downloadedAt.timeIntervalSince1970),
                   resolver.overrideType?.rawValue ?? "-", resolver.overrideDayKey ?? "-", String(resolver.yearEndAsHoliday)]
            .joined(separator: "|")
        if let cached = departureCache[key] { return cached }
        let list = StationDepartures.scheduled(schedule: schedule, stationID: stationID, now: now, resolver: resolver)
        if departureCache.count > 16 { departureCache = [:] }
        departureCache[key] = list
        return list
    }

    // MARK: - 経路の検索

    func setDestination(_ group: StationGroup?) {
        destination = group
        options = []
        message = nil
        missingRailways = []
    }

    /// 経路を探す。stationID は情報を開いている駅、now は今の時刻(仮想の時刻を含む)、userPoint は今の位置。
    func search(from stationID: String, now: Date, userPoint: GeoPoint?) async {
        guard let destination, !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        await trains.ensureDirectory(manual: false)
        guard let directory = trains.directory else {
            message = trains.directoryError ?? "駅の一覧がまだありません。通信できるときにもう一度試してください。"
            return
        }
        let origin: StationGroup?
        switch originMode {
        case .selectedStation:
            origin = directory.group(containing: stationID)
        case .nearestStation:
            guard let userPoint, let nearest = directory.nearest(to: userPoint) else {
                message = "現在地が分からないため、最寄り駅を決められません"
                return
            }
            origin = directory.group(containing: nearest.station.id)
        }
        guard let origin else {
            message = "この駅は駅の一覧にありません"
            return
        }
        searchedOrigin = origin
        guard Set(origin.stationIDs).isDisjoint(with: destination.stationIDs) else {
            options = []
            message = "出発と同じ駅です"
            return
        }
        // 経路に使えるのは、列車ごとの時刻表がある路線だけ(提供されていない路線は、乗り換えの経路にも入れない)
        let allowed = Set(directory.railwayGraph().keys.filter { live.schedules[$0] != nil || trains.capabilities(ofRailway: $0).trainTimetable })
        // 経路に出てくる路線のうち、時刻表を保存していない路線
        let needed = directory.railwaysOnShortestPaths(from: Set(origin.railwayIDs), to: Set(destination.railwayIDs), allowed: allowed)
        guard !needed.isEmpty else {
            options = []
            missingRailways = []
            message = Set(origin.railwayIDs).isDisjoint(with: allowed) || Set(destination.railwayIDs).isDisjoint(with: allowed)
                ? "列車ごとの時刻表が提供されていない路線の駅なので、経路を探せません"
                : "この2つの駅は、使える路線ではつながっていません"
            return
        }
        missingRailways = needed.filter { live.schedules[$0] == nil }.compactMap { id in
            guard let operatorID = RouteRailwayResolver.operatorID(forRailway: id) else { return nil }
            return RouteRailway(operatorID: operatorID, railwayID: id, name: directory.railwayName(of: id))
        }
        // Wi-Fi など従量制でない回線なら、足りない路線の時刻表を自動で取得する
        if !missingRailways.isEmpty, MapMode.canDownloadTiles(network: network.status) {
            await downloadMissingNow()
        }
        // 出発の駅に着ける時刻(急いだ場合)。駅が遠いとき(3km超)は、今の時刻から探す。
        var start = now
        walkDistance = nil
        if let userPoint {
            let distances = origin.stationIDs.compactMap { directory.station($0)?.point }.map { GeoMath.distance(userPoint, $0) }
            if let distance = distances.min(), distance <= Self.walkConsideredDistance {
                walkDistance = distance
                start = now.addingTimeInterval(CatchEstimator.walkSeconds(distance: distance, settings: settings.walkSettings, hurry: true))
            }
        }
        let schedules = Array(live.schedules.values)
        let resolver = settings.dayTypeResolver
        let transferMinutes = settings.transferMinutes
        let walk = settings.walkSettings
        let query = JourneyQuery(origins: Set(origin.stationIDs), destinations: Set(destination.stationIDs), departure: start)
        let found = await Task.detached(priority: .userInitiated) { () -> [JourneyOption] in
            let trips = JourneyPlanner.trips(schedules: schedules, from: start, horizon: query.horizon, resolver: resolver)
            return JourneyPlanner.search(
                trips: trips, query: query, sameStationTransfer: transferMinutes * 60,
                transfers: { id in
                    directory.transferTargets(from: id).map { target in
                        (stationID: target, seconds: directory.transferSeconds(from: id, to: target, transferMinutes: transferMinutes, walk: walk))
                    }
                },
                stationName: { directory.name(of: $0) },
                railwayName: { directory.railwayName(of: $0) })
        }.value
        options = found
        if found.isEmpty {
            message = missingRailways.isEmpty ? "6時間以内に着く経路が見つかりませんでした(終電のあとの可能性があります)"
                : "足りない路線の時刻表を取得すると、経路を探せます"
        } else {
            message = nil
        }
    }

    /// 足りない路線の時刻表を取得する(ボタン)。取得したら、同じ条件で探し直す。
    func downloadMissing(stationID: String, now: Date, userPoint: GeoPoint?) async {
        await downloadMissingNow()
        await search(from: stationID, now: now, userPoint: userPoint)
    }

    private func downloadMissingNow() async {
        guard !missingRailways.isEmpty, !isDownloading else { return }
        isDownloading = true
        defer { isDownloading = false }
        trains.addRouteRailways(missingRailways)
        await trains.ensureShapes(manual: true)
        await live.ensureSchedules(manual: true)
        missingRailways = missingRailways.filter { live.schedules[$0.railwayID] == nil }
    }

    // MARK: - 選んだ経路

    func select(_ journey: Journey?) {
        selected = journey
        alerted = []
        alightNotice = nil
        tracking = .notRiding
    }

    func dismissNotice() {
        alightNotice = nil
    }

    /// 乗車中の判定のたびに呼ぶ。経路の列車に乗っているか(予定どおりか)を判定し、降りる駅の1駅前で知らせる。
    func track(judgement: RideJudgement, nextStationID: String?) {
        guard let selected else { return }
        let status = JourneyTracking.status(journey: selected, judgement: judgement)
        if status != tracking { tracking = status }
        if let leg = JourneyTracking.alightAlert(journey: selected, judgement: judgement, nextStationID: nextStationID, alerted: alerted) {
            alerted.insert(leg)
            alightNotice = JourneyTracking.alertText(journey: selected, leg: leg)
            JourneyFeedback.play()
        }
    }
}

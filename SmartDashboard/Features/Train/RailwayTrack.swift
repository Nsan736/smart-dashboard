import Foundation

/// アプリに同梱した線路の形(Resources/railway_shapes.json)。国土数値情報(鉄道データ)を加工したもの。
/// 路線ID(ODPT)→ 駅の順に並んだ線路の点。作り直すときは手元で `python scripts/update_railway_shapes.py Toei` を実行する。通信では取得しない。
struct RailwayTrackCatalog: Equatable {
    /// 出典(加工したことを含む)
    var source: String
    /// 作成した日
    var fetched: String
    var tracks: [String: [GeoPoint]]

    /// アプリ内に出す出典の表記
    static let attribution = "線路の形: 国土数値情報(鉄道データ)(国土交通省)を加工して作成(CC BY 4.0)"

    init(tracks: [String: [GeoPoint]], source: String = "", fetched: String = "") {
        self.tracks = tracks
        self.source = source
        self.fetched = fetched
    }

    /// 形式: {"source": ..., "fetched": "2026-09-28", "railways": {"odpt.Railway:Toei.Asakusa": {"n02": [...], "points": [[緯度, 経度], ...]}}}
    init(data: Data) throws {
        struct File: Decodable {
            struct Railway: Decodable {
                let points: [[Double]]
            }

            let source: String?
            let fetched: String?
            let railways: [String: Railway]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var tracks: [String: [GeoPoint]] = [:]
        for (id, railway) in file.railways {
            let points = railway.points.compactMap { $0.count >= 2 ? GeoPoint($0[0], $0[1]) : nil }
            if points.count >= 2 { tracks[id] = points }
        }
        self.init(tracks: tracks, source: file.source ?? "", fetched: file.fetched ?? "")
    }

    /// 線路の形。同梱していない路線は nil(駅を結んだ直線を使う)。
    func track(for railwayID: String) -> [GeoPoint]? { tracks[railwayID] }

    static let bundled: RailwayTrackCatalog = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "railway_shapes", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? RailwayTrackCatalog(data: data) else {
            return RailwayTrackCatalog(tracks: [:])
        }
        return catalog
    }()

    private final class BundleToken {}
}

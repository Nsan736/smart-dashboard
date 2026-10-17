import Foundation

/// 線路の区間の種類(国土地理院ベクトルタイルの鉄道中心線の railState から作ったもの)
enum TrackSection: String, Codable, CaseIterable {
    case ground = "g"
    case elevated = "e"
    case underground = "u"
    case unknown = "?"

    var label: String {
        switch self {
        case .ground: return "地上"
        case .elevated: return "高架"
        case .underground: return "地下"
        case .unknown: return "不明"
        }
    }
}

/// 線路に沿った高さのデータ。同梱した線路の形の点の順での、線に沿った距離(step ごと)で引く。
struct TrackProfile: Equatable {
    struct Run: Equatable {
        /// この区間の種類が始まる点の番号
        var start: Int
        var section: TrackSection
    }

    /// 点の間隔(m)
    var step: Double
    /// 線路の下の地面の標高(m)。データがない点(海の上など)は nil。
    var ground: [Double?]
    var runs: [Run]

    /// データのない点の両側を探す範囲(この点数まで。25mごとなら250m)
    static let searchRange = 10

    /// 線に沿った距離 along(同梱した線路の形の向き)での、地面の標高と区間の種類。
    /// 地面の標高は前後の点から補間し、その点にない(海の上など)ときは、近くの点の値を使う。
    func sample(atAlong along: Double) -> (ground: Double?, section: TrackSection) {
        guard !ground.isEmpty, step > 0 else { return (nil, .unknown) }
        let position = min(max(along / step, 0), Double(ground.count - 1))
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, ground.count - 1)
        let t = position - Double(lower)
        var value: Double?
        if let a = ground[lower], let b = ground[upper] {
            value = a + (b - a) * t
        } else {
            for offset in 0...Self.searchRange {
                if let found = ground[safe: lower - offset] ?? ground[safe: upper + offset] {
                    value = found
                    break
                }
            }
        }
        let index = Int(position.rounded())
        let section = runs.last { $0.start <= index }?.section ?? .unknown
        return (value, section)
    }
}

private extension Array where Element == Double? {
    subscript(safe index: Int) -> Double? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 線路の高さ(地面の標高 + 区間の種類ごとの値)。
enum TrackHeightModel {
    struct Height: Equatable {
        /// 線路の高さ(m、平均海面から)。地面の標高が分からなければ nil。
        var altitude: Double?
        var section: TrackSection
        /// 区間の種類か地面の標高が分からず、目安で置いている
        var isEstimate: Bool
    }

    /// 高架は地面 + elevated、地下は地面 − underground、地上は地面。区間の種類が分からないときは地面(目安)。
    static func height(ground: Double?, section: TrackSection, elevated: Double, underground: Double) -> Height {
        guard let ground else { return Height(altitude: nil, section: section, isEstimate: true) }
        switch section {
        case .ground: return Height(altitude: ground, section: section, isEstimate: false)
        case .elevated: return Height(altitude: ground + elevated, section: section, isEstimate: false)
        case .underground: return Height(altitude: ground - underground, section: section, isEstimate: false)
        case .unknown: return Height(altitude: ground, section: section, isEstimate: true)
        }
    }
}

/// アプリに同梱した線路の形(Resources/railway_shapes.json)。国土数値情報(鉄道データ)を加工したもの。
/// 路線ID(ODPT)→ 線路の点。作り直すときは手元で `python scripts/update_railway_shapes.py Toei` を実行する。通信では取得しない。
/// 都営は ODPT の駅の順に並べてある。N02 の駅だけで作った路線(トークンが必要な事業者)は向きが逆のことがあり、RideLine が駅の順に合わせる。
/// v0.9.17 から、線路に沿った高さ(地面の標高と区間の種類、`profiles`)も入っている(`--heights-only` で付ける)。
struct RailwayTrackCatalog: Equatable {
    /// 出典(加工したことを含む)
    var source: String
    /// 作成した日
    var fetched: String
    var tracks: [String: [GeoPoint]]
    var profiles: [String: TrackProfile] = [:]
    /// 高さのデータの出典(加工したことを含む)と作成した日
    var heightSource = ""
    var heightFetched = ""

    /// アプリ内に出す出典の表記
    static let attribution = "線路の形: 国土数値情報(鉄道データ)(国土交通省)を加工して作成(CC BY 4.0)"
    static let heightAttribution = "線路の高さ: 地理院タイル(標高タイル)と、国土地理院ベクトルタイル提供実験(鉄道中心線)を加工して作成"

    init(tracks: [String: [GeoPoint]], source: String = "", fetched: String = "", profiles: [String: TrackProfile] = [:]) {
        self.tracks = tracks
        self.source = source
        self.fetched = fetched
        self.profiles = profiles
    }

    /// 形式: {"source": ..., "fetched": "2026-09-28", "railways": {"odpt.Railway:Toei.Asakusa": {"n02": [...], "points": [[緯度, 経度], ...],
    /// "profile": {"step": 25, "ground": [0.1m 単位の整数 か null, ...], "kinds": [[始まりの番号, "g"|"e"|"u"|"?"], ...]}}}}
    init(data: Data) throws {
        struct File: Decodable {
            struct Railway: Decodable {
                struct Profile: Decodable {
                    struct Run: Decodable {
                        let start: Int
                        let kind: String

                        init(from decoder: Decoder) throws {
                            var c = try decoder.unkeyedContainer()
                            start = try c.decode(Int.self)
                            kind = try c.decode(String.self)
                        }
                    }

                    let step: Double
                    let ground: [Int?]
                    let kinds: [Run]
                }

                let points: [[Double]]
                let profile: Profile?
            }

            let source: String?
            let fetched: String?
            let heightSource: String?
            let heightFetched: String?
            let railways: [String: Railway]
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var tracks: [String: [GeoPoint]] = [:]
        var profiles: [String: TrackProfile] = [:]
        for (id, railway) in file.railways {
            let points = railway.points.compactMap { $0.count >= 2 ? GeoPoint($0[0], $0[1]) : nil }
            guard points.count >= 2 else { continue }
            tracks[id] = points
            if let profile = railway.profile, !profile.ground.isEmpty {
                profiles[id] = TrackProfile(step: profile.step, ground: profile.ground.map { $0.map { Double($0) / 10 } },
                                            runs: profile.kinds.map { TrackProfile.Run(start: $0.start, section: TrackSection(rawValue: $0.kind) ?? .unknown) })
            }
        }
        self.init(tracks: tracks, source: file.source ?? "", fetched: file.fetched ?? "", profiles: profiles)
        heightSource = file.heightSource ?? ""
        heightFetched = file.heightFetched ?? ""
    }

    /// 線路の形。同梱していない路線は nil(駅を結んだ直線を使う)。
    func track(for railwayID: String) -> [GeoPoint]? { tracks[railwayID] }

    /// 線路に沿った高さ。ない路線は nil。
    func profile(for railwayID: String) -> TrackProfile? { profiles[railwayID] }

    static let bundled: RailwayTrackCatalog = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "railway_shapes", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? RailwayTrackCatalog(data: data) else {
            return RailwayTrackCatalog(tracks: [:])
        }
        return catalog
    }()

    private final class BundleToken {}
}

import CoreLocation
import SwiftUI
import UIKit

/// 震度の色。気象庁の震度の配色に合わせる。一覧、ホームのカード、詳細画面で同じ色を使う。
enum SeismicScaleStyle {
    /// 色の成分(0〜1)。SwiftUI の色と、地図の重ね描き(UIKit)の色を、同じ値から作る。
    static func rgb(_ scale: Int) -> (red: Double, green: Double, blue: Double)? {
        switch scale {
        case 10: return (0.95, 0.95, 1.0)
        case 20: return (0.0, 0.67, 1.0)
        case 30: return (0.0, 0.25, 1.0)
        case 40: return (0.98, 0.90, 0.59)
        case 45, 46: return (1.0, 0.90, 0.0)
        case 50: return (1.0, 0.60, 0.0)
        case 55: return (1.0, 0.16, 0.0)
        case 60: return (0.65, 0.0, 0.13)
        case 70: return (0.71, 0.0, 0.41)
        default: return nil
        }
    }

    static func background(_ scale: Int) -> Color {
        guard let rgb = rgb(scale) else { return Color(.systemGray4) }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func uiColor(_ scale: Int) -> UIColor {
        guard let rgb = rgb(scale) else { return .systemGray4 }
        return UIColor(red: CGFloat(rgb.red), green: CGFloat(rgb.green), blue: CGFloat(rgb.blue), alpha: 1)
    }

    static func foreground(_ scale: Int) -> Color {
        switch scale {
        case 30, 55, 60, 70: return .white
        default: return .black
        }
    }
}

/// 「震度3」のような色付きのラベル
struct QuakeScaleBadge: View {
    let scale: Int?
    var prefix = "震度"

    var body: some View {
        Text(scale.map { prefix + SeismicScale.label($0) } ?? "震度不明")
            .font(.subheadline.weight(.bold))
            .foregroundStyle(SeismicScaleStyle.foreground(scale ?? 0))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SeismicScaleStyle.background(scale ?? 0), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.systemGray3), lineWidth: 0.5) }
            .fixedSize()
    }
}

/// 現在地(天気を取得した地点)と震源の関係
enum QuakeRelation {
    /// 「震源は南西 120km」。震源か現在地が分からなければ nil。
    static func text(quake: Quake, latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude, let quakeLatitude = quake.latitude, let quakeLongitude = quake.longitude else { return nil }
        let bearing = WaypointMath.bearing(fromLatitude: latitude, longitude: longitude, toLatitude: quakeLatitude, longitude: quakeLongitude)
        let distance = WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: quakeLatitude, longitude: quakeLongitude)
        return "震源は\(WaypointMath.compassPoint(bearing)) \(distanceText(distance))"
    }

    /// 震源の位置は0.1度刻みなので、km単位に丸める
    static func distanceText(_ meters: Double) -> String {
        meters < 1000 ? "1km未満" : "\(Int((meters / 1000).rounded()))km"
    }
}

/// 地震の詳細。取得済みのデータだけを使い、通信はしない(地図の表示を除く)。
struct QuakeDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let quakeTime: Date

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日(E) H時mm分ごろ"
        return formatter
    }()

    var body: some View {
        // 一覧が更新されたら、同じ地震の新しい内容を表示する
        let quake = env.quakes.cached?.value.quakes.first { $0.time == quakeTime }
        List {
            if let quake {
                summarySection(quake)
                tsunamiSection(quake)
                relationSection(quake)
                mapSection(quake)
                intensitySection(quake)
                sourceSection(quake)
            } else {
                Text("この地震の情報は、一覧から外れました").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("地震の詳細")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summarySection(_ quake: Quake) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.timeFormatter.string(from: quake.time)).font(.subheadline).foregroundStyle(.secondary)
                Text(quake.place ?? "震源を調査中")
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    QuakeScaleBadge(scale: quake.maxScale, prefix: "最大震度")
                    Text(QuakeList.magnitudeText(quake.magnitude)).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(QuakeList.depthText(quake.depth)).font(.subheadline)
                }
                if quake.wasRevised == true {
                    Label("更新あり(震源やマグニチュードなどが、あとの報で修正されました)", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func tsunamiSection(_ quake: Quake) -> some View {
        let domestic = QuakeTsunami.domestic(quake.domesticTsunami)
        let foreign = QuakeTsunami.foreign(quake.foreignTsunami)
        return Section("津波") {
            tsunamiRow("国内", domestic.text, domestic.tone)
            if let foreign { tsunamiRow("海外", foreign.text, foreign.tone) }
        }
    }

    private func tsunamiRow(_ title: String, _ text: String, _ tone: QuakeTsunami.Tone) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(tone == .warning ? .body.weight(.bold) : .body)
                .foregroundStyle(tone == .warning ? Color.red : (tone == .caution ? Color.orange : Color.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func relationSection(_ quake: Quake) -> some View {
        let snapshot = env.weather.cached?.value
        let prefecture = env.currentPrefecture
        Section {
            if let text = QuakeRelation.text(quake: quake, latitude: snapshot?.latitude, longitude: snapshot?.longitude) {
                Text(text).font(.headline)
            } else {
                Text(quake.latitude == nil ? "震源の位置は未発表です" : "現在地が分からないため、距離は出せません").foregroundStyle(.secondary)
            }
            if let prefecture, !prefecture.isEmpty {
                HStack {
                    Text("\(prefecture)の最大震度")
                    Spacer(minLength: 8)
                    if let scale = quake.scale(inPrefecture: prefecture) {
                        QuakeScaleBadge(scale: scale)
                    } else {
                        Text("観測なし").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("現在地との関係")
        } footer: {
            Text("現在地は、天気を取得した地点(\(snapshot?.placeName ?? "未取得"))です。新しく測位はしません。")
        }
    }

    @ViewBuilder
    private func mapSection(_ quake: Quake) -> some View {
        if let latitude = quake.latitude, let longitude = quake.longitude {
            let epicenter = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let snapshot = env.weather.cached?.value
            let here = snapshot?.latitude.flatMap { lat in snapshot?.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } }
            let markers = [MapMarker(id: "epicenter", title: "\(QuakeList.magnitudeText(quake.magnitude)) \(QuakeList.depthText(quake.depth))",
                                     coordinate: epicenter, style: .epicenter)]
                + (here.map { [MapMarker(id: "here", title: "現在地", coordinate: $0, style: .dot)] } ?? [])
            // 観測点ごとの震度。観測点名で位置を対応付け、1枚の重ね描きで描く
            let table = IntensityStationTable.bundled
            let result = QuakeMapDots.make(points: quake.points ?? [], table: table)
            Section {
                MapContainerView(center: epicenter, spanMeters: 400_000, isInteractive: true, markers: markers, intensityDots: result.dots,
                                 fitKey: here == nil ? nil : "quake-\(quake.time.timeIntervalSince1970)")
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
                if !result.dots.isEmpty {
                    // 凡例
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(QuakeMapDots.legendScales(result.dots), id: \.self) { QuakeScaleBadge(scale: $0) }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("赤い×印が震源、青い点が現在地、色の付いた丸が観測点ごとの震度です(震度の大きい点を上に描いています)。")
                    if !result.unmatched.isEmpty {
                        Text("位置が分からない観測点 \(result.unmatched.count)地点は、地図には出していません(下の一覧には出ています)。")
                    }
                    if !table.fetched.isEmpty {
                        Text("観測点の位置: 気象庁の震度観測点の一覧(\(table.fetched)取得)から、名前と位置だけを抜き出して加工したものです。")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func intensitySection(_ quake: Quake) -> some View {
        let groups = QuakeIntensityGroup.make(quake.points ?? [], homePrefecture: env.currentPrefecture)
        Section {
            if groups.isEmpty {
                Text("各地の震度は、まだ発表されていないか、保存されていません").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                DisclosureGroup {
                    ForEach(group.prefectures) { prefecture in
                        DisclosureGroup {
                            ForEach(prefecture.points, id: \.self) { name in
                                Text(name).font(.footnote).foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                Text(prefecture.name).fontWeight(prefecture.isHome ? .bold : .regular)
                                if prefecture.isHome {
                                    Text("現在地").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                                }
                                Spacer(minLength: 8)
                                Text("\(prefecture.points.count)地点").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    HStack {
                        QuakeScaleBadge(scale: group.scale)
                        Text(group.prefectures.prefix(3).map(\.name).joined(separator: "、") + (group.prefectures.count > 3 ? " ほか" : ""))
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(group.pointCount)地点").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("各地の震度")
        }
    }

    private func sourceSection(_ quake: Quake) -> some View {
        Section {
            Link("出典: P2P地震情報 JSON API(気象庁の地震情報を配信)", destination: URL(string: "https://www.p2pquake.net/")!)
            Link("気象庁の地震情報のページを開く", destination: URL(string: "https://www.jma.go.jp/bosai/map.html#contents=earthquake_map")!)
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let reportedAt = quake.reportedAt {
                    Text("もとにした報: \(QuakeList.reportName(quake.reportType))(\(Formatters.dateTime.string(from: reportedAt)) 発表)")
                }
                Text("気象庁のページは、地震情報の一覧を開きます(この地震のページを直接開くための番号が、取得しているデータに含まれないため)。")
            }
        }
    }
}

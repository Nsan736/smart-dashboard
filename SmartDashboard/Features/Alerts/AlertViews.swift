import SwiftUI

/// 警報・注意報の色。気象庁の配色に合わせる(注意報=黄、警報=赤、危険警報=紫、特別警報=黒)。
enum WarningStyle {
    static func background(_ level: WarningLevel) -> Color {
        switch level {
        case .unknown: return Color(.systemGray3)
        case .advisory: return .yellow
        case .warning: return .red
        case .danger: return .purple
        case .special: return .black
        }
    }

    static func foreground(_ level: WarningLevel) -> Color {
        switch level {
        case .unknown, .advisory: return .black
        case .warning, .danger, .special: return .white
        }
    }
}

/// 警報・注意報の1件を、段階の色のラベルで表示する
struct WarningBadge: View {
    let warning: ActiveWarning

    var body: some View {
        Text(warning.name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(WarningStyle.foreground(warning.level))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(WarningStyle.background(warning.level), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                // 黒(特別警報)はダークモードで背景に埋もれるので、縁を付ける
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.systemGray), lineWidth: warning.level == .special ? 1.5 : 0)
            }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 複数のラベルを、幅に合わせて折り返して並べる
struct WarningBadgeFlow: View {
    let warnings: [ActiveWarning]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(warnings) { WarningBadge(warning: $0) }
        }
    }
}

struct WarningHomeCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.warnings
        let snapshot = store.cached?.value
        let severe = (snapshot?.maxLevel ?? .unknown) >= .warning
        HomeCard(title: "警報・注意報", symbol: "exclamationmark.triangle", fetchedAt: store.cached?.fetchedAt) {
            if let snapshot {
                if snapshot.warnings.isEmpty {
                    Text("\(snapshot.area.name)：発表なし")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(snapshot.area.name + (snapshot.area.coversWholeCity ? "(市内のいずれかの区域)" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WarningBadgeFlow(warnings: snapshot.warnings)
                }
            }
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if snapshot == nil {
                Text("未取得です").font(.footnote).foregroundStyle(.secondary)
            }
            Text("出典: 気象庁").font(.caption2).foregroundStyle(.secondary)
        }
        .overlay {
            // 警報以上が出ているときは、カードの縁をその色にして目立たせる
            if severe, let level = snapshot?.maxLevel {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(level == .special ? Color(.label) : WarningStyle.background(level), lineWidth: 3)
            }
        }
    }
}

/// 天気タブに出す、発表中の警報・注意報の一覧
struct WarningSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.warnings
        Section {
            if let snapshot = store.cached?.value {
                if snapshot.warnings.isEmpty {
                    Text("発表中の警報・注意報はありません").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.warnings) { warning in
                        HStack(alignment: .firstTextBaseline) {
                            WarningBadge(warning: warning)
                            Spacer(minLength: 8)
                            Text(([warning.status] + warning.additions).filter { !$0.isEmpty }.joined(separator: "・"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                if snapshot.area.coversWholeCity {
                    Text("気象庁は\(snapshot.area.name)を複数の区域に分けて発表しています。どの区域にいるかは判定できないため、市内のいずれかの区域に出ているものをすべて表示しています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if store.errorMessage == nil {
                Text(store.isLoading ? "取得中…" : "未取得です").foregroundStyle(.secondary)
            }
            DataStatusView(fetchedAt: store.cached?.fetchedAt, note: store.autoRefreshNote, error: store.errorMessage)
        } header: {
            Text("警報・注意報" + (store.cached.map { "(\($0.value.area.name))" } ?? ""))
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let reportedAt = store.cached?.value.reportedAt {
                    Text("気象庁の発表: \(Formatters.dateTime.string(from: reportedAt))")
                }
                Link("出典: 気象庁(気象警報・注意報)", destination: URL(string: "https://www.jma.go.jp/bosai/warning/")!)
                Text("河川の氾濫に関する情報は含みません。公式のAPIではないため、仕様の変更で取得できなくなることがあります。")
            }
            .font(.caption)
        }
    }
}

enum QuakeText {
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    static func scale(_ scale: Int?) -> String {
        scale.map { "最大震度" + SeismicScale.label($0) } ?? "震度不明"
    }
}

struct QuakeRow: View {
    let quake: Quake
    let prefecture: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(quake.place ?? "震源を調査中")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(QuakeText.scale(quake.maxScale))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Self.color(quake.maxScale ?? 0))
            }
            Text("\(QuakeText.timeFormatter.string(from: quake.time))・\(QuakeList.magnitudeText(quake.magnitude))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let prefecture, let scale = quake.scale(inPrefecture: prefecture) {
                Text("\(prefecture)：震度\(SeismicScale.label(scale))")
                    .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func color(_ scale: Int) -> Color {
        if scale >= 45 { return .red }
        if scale >= 30 { return .orange }
        return .primary
    }
}

struct QuakeHomeCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.quakes
        HomeCard(title: "地震", symbol: "waveform.path.ecg", fetchedAt: store.cached?.fetchedAt) {
            if let snapshot = store.cached?.value {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let recent = QuakeList.recent(snapshot.quakes, minimumScale: env.settings.quakeMinimumScale, now: context.date)
                    if recent.isEmpty {
                        Text("直近24時間：なし(震度\(SeismicScale.label(env.settings.quakeMinimumScale))以上)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(recent.prefix(3)) { QuakeRow(quake: $0, prefecture: env.currentPrefecture) }
                        }
                    }
                }
            } else {
                Text(store.errorMessage ?? "未取得です").font(.footnote).foregroundStyle(.secondary)
            }
            Text("出典: P2P地震情報(気象庁の地震情報)").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// 天気タブに出す、最近の地震(最大5件)
struct QuakeSection: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let store = env.quakes
        Section {
            if store.latest.isEmpty, store.errorMessage == nil {
                Text(store.isLoading ? "取得中…" : "未取得です").foregroundStyle(.secondary)
            }
            ForEach(store.latest) { QuakeRow(quake: $0, prefecture: env.currentPrefecture) }
            DataStatusView(fetchedAt: store.cached?.fetchedAt, note: store.autoRefreshNote, error: store.errorMessage)
        } header: {
            Text("最近の地震")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Link("出典: P2P地震情報 JSON API(気象庁の地震情報を配信)", destination: URL(string: "https://www.p2pquake.net/")!)
                Text("地震情報は気象庁の発表にもとづきます。")
            }
            .font(.caption)
        }
    }
}

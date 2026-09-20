import SwiftUI

/// タブの種類。並びは初期の表示順で、先頭の4つがタブバーに並び、残りはiOSの「その他」に入る。
enum AppTab: String, CaseIterable, Identifiable, Codable {
    case home
    case weather
    case waypoint
    case train
    case exchange
    case sensors
    case timer
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "ホーム"
        case .weather: return "天気"
        case .waypoint: return "ウェイポイント"
        case .train: return "電車"
        case .exchange: return "為替"
        case .sensors: return "センサー"
        case .timer: return "タイマー"
        case .settings: return "設定"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .weather: return "cloud.sun"
        case .waypoint: return "mappin.and.ellipse"
        case .train: return "tram"
        case .exchange: return "yensign.circle"
        case .sensors: return "gauge.with.dots.needle.33percent"
        case .timer: return "timer"
        case .settings: return "gearshape"
        }
    }
}

/// タブの並び順
enum TabOrder {
    /// タブバーに並ぶ数。タブが6つ以上あると、iOSは先頭の4つと「その他」を表示する。
    static let barCount = 4

    static let initial: [AppTab] = AppTab.allCases

    /// 保存してあった並びを、今あるタブに合わせる。知らないものと重複は捨て、足りないタブは末尾に足す。
    static func normalized(_ order: [AppTab]) -> [AppTab] {
        var seen = Set<AppTab>()
        var result = order.filter { seen.insert($0).inserted }
        for tab in AppTab.allCases where !seen.contains(tab) { result.append(tab) }
        return result
    }

    /// 保存データ(rawValue の配列)から復元する。保存がなければ初期の並び。
    static func decode(_ stored: [String]?) -> [AppTab] {
        guard let stored else { return initial }
        return normalized(stored.compactMap(AppTab.init(rawValue:)))
    }

    /// タブバーに並ぶタブ
    static func barTabs(_ order: [AppTab]) -> [AppTab] {
        let all = normalized(order)
        return all.count <= barCount + 1 ? all : Array(all.prefix(barCount))
    }

    /// 「その他」に入るタブ
    static func moreTabs(_ order: [AppTab]) -> [AppTab] {
        let all = normalized(order)
        return all.count <= barCount + 1 ? [] : Array(all.dropFirst(barCount))
    }

    static func isInMore(_ tab: AppTab, order: [AppTab]) -> Bool {
        moreTabs(order).contains(tab)
    }
}

/// 設定の「タブの並び順」
struct TabOrderEditor: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmReset = false

    var body: some View {
        let order = env.settings.tabOrder
        List {
            Section {
                ForEach(order) { tab in
                    HStack {
                        Label(tab.title, systemImage: tab.symbol)
                        Spacer(minLength: 8)
                        Text(TabOrder.isInMore(tab, order: order) ? "その他" : "タブバー")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onMove { source, destination in
                    var new = env.settings.tabOrder
                    new.move(fromOffsets: source, toOffset: destination)
                    env.settings.tabOrder = new
                }
            } footer: {
                Text("右端のつまみをドラッグして並べ替えます。先頭の4つがタブバーに並び、残りは「その他」に入ります。設定を「その他」に入れても、「その他」から開けます。")
            }
            Section {
                Button("初期の並びに戻す", role: .destructive) { confirmReset = true }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("タブの並び順")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("タブの並びを初期状態に戻しますか", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("初期の並びに戻す", role: .destructive) { env.settings.tabOrder = TabOrder.initial }
        }
    }
}

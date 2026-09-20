import SwiftUI

struct RootTabView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // 先頭の4つがタブバーに並び、残りはiOSの「その他」に入る。並びは設定で変えられる。
        TabView {
            ForEach(env.settings.tabOrder) { tab in
                content(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
            }
        }
        .background(KeyboardTapDismissInstaller())
    }

    @ViewBuilder
    private func content(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .weather: WeatherView()
        case .waypoint: ScopeView()
        case .train: TrainView()
        case .exchange: ExchangeView()
        case .sensors: SensorsView()
        case .timer: TimerTabView()
        case .settings: SettingsView()
        }
    }
}

/// 未実装の画面に置く仮の表示
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage, description: Text("この画面は今後の段階で実装します"))
                .navigationTitle(title)
        }
    }
}

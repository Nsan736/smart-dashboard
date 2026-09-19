import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("ホーム", systemImage: "square.grid.2x2") }
            WeatherView()
                .tabItem { Label("天気", systemImage: "cloud.sun") }
            ExchangeView()
                .tabItem { Label("為替", systemImage: "yensign.circle") }
            TrainView()
                .tabItem { Label("電車", systemImage: "tram") }
            SensorsView()
                .tabItem { Label("センサー", systemImage: "gauge.with.dots.needle.33percent") }
            TimerTabView()
                .tabItem { Label("タイマー", systemImage: "timer") }
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .background(KeyboardTapDismissInstaller())
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

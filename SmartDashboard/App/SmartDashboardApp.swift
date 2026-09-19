import SwiftUI

@main
struct SmartDashboardApp: App {
    @State private var env = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(env)
                .task { env.network.start() }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else {
                        // フォアグラウンドを離れたら地図の保存を止める
                        env.tiles.evaluate(isForeground: false)
                        return
                    }
                    Task { await env.refreshStaleData() }
                }
                .onChange(of: env.network.status) { _, _ in
                    guard scenePhase == .active else { return }
                    Task { await env.refreshStaleData() }
                }
        }
    }
}

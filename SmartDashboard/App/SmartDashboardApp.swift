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
                // 前回、スクリプト型のツールの実行中に止まっていたら、そのツールは開かずに、どうするかを選んでもらう
                .sheet(item: Binding(get: { env.tools.crashedScript }, set: { if $0 == nil { env.tools.resolveCrashedScript() } })) { record in
                    ScriptCrashRecoveryView(record: record)
                        .environment(env)
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else {
                        // フォアグラウンドを離れたら地図の保存を止める
                        env.tiles.evaluate(isForeground: false)
                        if phase == .background { env.didEnterBackground() }
                        return
                    }
                    env.didBecomeActive()
                    Task { await env.refreshStaleData() }
                }
                .onChange(of: env.network.status) { _, _ in
                    guard scenePhase == .active else { return }
                    Task { await env.refreshStaleData() }
                }
        }
    }
}

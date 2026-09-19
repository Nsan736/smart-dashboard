import CoreLocation
import SwiftUI

/// 雨雲レーダー。天気タブの中から開く。
struct RadarView: View {
    @Environment(AppEnvironment.self) private var env
    var center: CLLocationCoordinate2D?

    var body: some View {
        @Bindable var store = env.radar
        VStack(spacing: 0) {
            MapContainerView(center: center, spanMeters: 200_000, pin: center, isInteractive: true,
                             showsUserLocation: true, radar: store.layer)
            VStack(alignment: .leading, spacing: 10) {
                if let message = store.errorMessage ?? (store.tilesLookBroken ? RadarStore.failureMessage : nil) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button {
                        store.togglePlaying()
                    } label: {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.frames.count < 2)
                    .accessibilityLabel(store.isPlaying ? "停止" : "予測を再生")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(store.selectedFrame.map { RadarStore.label(for: $0, latest: store.frames.first) } ?? "-")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text("受信 \(Formatters.bytes(store.sessionBytes))(この表示での合計)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isLoading { ProgressView() }
                }
                if store.frames.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(store.selectedIndex) },
                            set: { store.selectedIndex = Int($0.rounded()) }
                        ),
                        in: 0...Double(store.frames.count - 1),
                        step: 1
                    )
                    Text("スライダーを動かすか再生すると、表示範囲の予測だけを読み込みます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                RadarLegendView()
                HStack {
                    Text("出典: 気象庁")
                    Link("雨雲の動き(気象庁)", destination: RadarTimeline.pageURL)
                }
                .font(.caption)
            }
            .padding()
        }
        .navigationTitle("雨雲レーダー")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RefreshToolbarButton(isLoading: store.isLoading) { await store.reload() }
            }
        }
        .task { await store.open() }
        .onDisappear { store.close() }
    }
}

struct RadarLegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("降水の強さ (mm/h)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(RadarLegendItem.all) { item in
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color(red: item.red / 255, green: item.green / 255, blue: item.blue / 255))
                            .frame(height: 10)
                        Text(item.label)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.4), lineWidth: 0.5))
        }
    }
}

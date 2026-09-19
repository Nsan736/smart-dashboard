import SwiftUI

/// キャッシュの鮮度、自動更新の状態、エラーをまとめて表示する
struct DataStatusView: View {
    let fetchedAt: Date?
    let note: String?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Label(Formatters.ageLabel(fetchedAt, now: context.date), systemImage: "clock")
            }
            if let note {
                Label(note, systemImage: "wifi.exclamationmark")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

/// 屋外でも読みやすい大きな数値表示
struct BigValue: View {
    let value: String
    var unit: String = ""
    var size: CGFloat = 56

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RefreshToolbarButton: View {
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        if isLoading {
            ProgressView()
        } else {
            Button {
                Task { await action() }
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
        }
    }
}

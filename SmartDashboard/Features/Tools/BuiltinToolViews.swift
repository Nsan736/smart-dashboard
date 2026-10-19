import AVFoundation
import SwiftUI

// MARK: - JSON のリスト型

/// 項目の一覧から選ぶ(ルーレット、くじ引き、順番決め)。JSONのリスト型で使う。
struct ListPickerView: View {
    let mode: CustomTool.ListMode
    let items: [String]
    @State private var result: String?
    @State private var remaining: [String] = []
    @State private var order: [String] = []
    @State private var history: [String] = []

    var body: some View {
        Section {
            switch mode {
            case .roulette:
                RouletteSpinner(items: items) { history.insert($0, at: 0) }
            case .lottery:
                Text(result ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .multilineTextAlignment(.center)
                Button("1つ引く(残り \(remaining.count))") {
                    guard let index = remaining.indices.randomElement() else { return }
                    let picked = remaining.remove(at: index)
                    result = picked
                    history.insert(picked, at: 0)
                }
                .disabled(remaining.isEmpty)
                Button("最初から") {
                    remaining = items
                    result = nil
                    history = []
                }
            case .order:
                ForEach(Array(order.enumerated()), id: \.offset) { index, name in
                    Text("\(index + 1). \(name)")
                }
                Button("並べ替える") { order = items.shuffled() }
                    .disabled(items.isEmpty)
            }
        }
        .onAppear { if remaining.isEmpty { remaining = items } }
        .onChange(of: items) { _, new in
            remaining = new
            order = []
            result = nil
        }
        if !history.isEmpty, mode != .order {
            Section("履歴(新しい順)") {
                ForEach(Array(history.prefix(20).enumerated()), id: \.offset) { _, name in Text(name) }
            }
        }
    }
}

// MARK: - 測る

struct FlashlightToolView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOn = false
    @State private var level = 1.0
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("ライト", isOn: $isOn)
                HStack {
                    Image(systemName: "sun.min")
                    Slider(value: $level, in: 0.1...1)
                    Image(systemName: "sun.max")
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("この画面を離れると、ライトを消します。")
            }
        }
        .onChange(of: isOn) { _, _ in apply() }
        .onChange(of: level) { _, _ in apply() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { isOn = false } }
        .onDisappear {
            isOn = false
            setTorch(on: false)
        }
    }

    private func apply() { setTorch(on: isOn) }

    /// ライトがない環境(シミュレーターなど)では、その旨を表示するだけ
    private func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            if on { message = "この環境ではライトを使えません" }
            return
        }
        do {
            try device.lockForConfiguration()
            if on {
                try device.setTorchModeOn(level: Float(min(max(level, 0.1), 1)))
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            message = nil
        } catch {
            message = "ライトを操作できませんでした"
        }
    }
}

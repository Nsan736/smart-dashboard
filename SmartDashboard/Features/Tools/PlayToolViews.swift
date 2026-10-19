import SwiftUI

// MARK: - ルーレットの円盤

/// 項目を色分けした円盤。描くのは項目が変わったときだけで、回転は描いた結果を回すだけ。
struct RouletteWheelView: View, Equatable {
    let items: [String]

    static func color(_ index: Int, count: Int) -> Color {
        Color(hue: Double(index) / Double(max(count, 1)), saturation: index % 2 == 0 ? 0.55 : 0.4, brightness: 0.95)
    }

    var body: some View {
        Canvas { context, size in
            let count = items.count
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            guard count > 0 else {
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.gray.opacity(0.3)))
                return
            }
            let segment = 360 / Double(count)
            for index in 0..<count {
                // 真上(−90度)から時計回り
                let start = Angle.degrees(-90 + Double(index) * segment)
                let end = Angle.degrees(-90 + Double(index + 1) * segment)
                var path = Path()
                path.move(to: center)
                path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                path.closeSubpath()
                context.fill(path, with: .color(Self.color(index, count: count)))
                context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1)
                guard count <= 24 else { continue }
                // 文字は、扇形の中央に、中心から外へ向けて書く
                let middle = Angle.degrees(-90 + (Double(index) + 0.5) * segment)
                var layer = context
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: middle)
                let label = RouletteWheel.shortName(items[index], units: count <= 8 ? 12 : 8)
                layer.draw(Text(label).font(.system(size: count <= 12 ? 13 : 10, weight: .semibold)).foregroundStyle(Color.black),
                           at: CGPoint(x: radius * 0.6, y: 0), anchor: .center)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 円盤と針。回すと、結果の項目が針の下にくる角度で止まる。
struct RouletteSpinner: View {
    let items: [String]
    let onResult: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0
    @State private var spinning = false
    @State private var result: String?

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                RouletteWheelView(items: items)
                    .equatable()
                    .rotationEffect(.degrees(rotation))
                    .frame(maxWidth: 260)
                    .padding(.top, 10)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.red)
                    .shadow(radius: 1)
            }
            .frame(maxWidth: .infinity)
            Text(spinning ? " " : (result ?? "—"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 40)
            Button(spinning ? "回しています…" : "回す") { spin() }
                .buttonStyle(.borderedProminent)
                .disabled(items.isEmpty || spinning)
        }
        .onChange(of: items) { _, _ in
            result = nil
            rotation = 0
        }
    }

    private func spin() {
        guard let index = items.indices.randomElement() else { return }
        let picked = items[index]
        let target = RouletteWheel.stopRotation(current: rotation, index: index, count: items.count, turns: 4, fraction: Double.random(in: 0.15...0.85))
        if reduceMotion {
            rotation = target
            result = picked
            onResult(picked)
            return
        }
        spinning = true
        let duration = 3.2
        withAnimation(.timingCurve(0.12, 0.6, 0.1, 1, duration: duration)) { rotation = target }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            result = picked
            spinning = false
            onResult(picked)
        }
    }
}

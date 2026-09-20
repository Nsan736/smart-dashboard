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
                let label = TournamentLayout.shortName(items[index], units: count <= 8 ? 12 : 8)
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

// MARK: - サイコロ

/// サイコロの面。6面は点、それ以外は数字。
struct DiceFaceView: View {
    let value: Int
    let sides: Int

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let shape = Path(roundedRect: rect, cornerRadius: size.width * 0.18)
            context.fill(shape, with: .color(.white))
            context.stroke(shape, with: .color(.gray), lineWidth: 1.5)
            if sides == 6 {
                let cell = size.width / 4
                let dot = size.width * 0.17
                for position in DicePips.positions(value) {
                    let center = CGPoint(x: cell * CGFloat(position.column + 1), y: cell * CGFloat(position.row + 1))
                    let circle = Path(ellipseIn: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
                    context.fill(circle, with: .color(value == 1 ? .red : .black))
                }
            } else {
                context.draw(Text("\(value)").font(.system(size: size.width * (value >= 100 ? 0.34 : 0.45), weight: .bold, design: .rounded)).foregroundStyle(Color.black),
                             at: CGPoint(x: size.width / 2, y: size.height / 2), anchor: .center)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("\(value)")
    }
}

struct DiceToolView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var count = 2
    @State private var sides = 6
    @State private var rolls: [Int] = []
    @State private var rolling = false
    @State private var tilt = 0.0

    var body: some View {
        Form {
            Section {
                Stepper("個数: \(count)", value: $count, in: 1...20)
                Picker("面の数", selection: $sides) {
                    ForEach([4, 6, 8, 10, 12, 20, 100], id: \.self) { Text("\($0)面").tag($0) }
                }
                Button(rolling ? "振っています…" : "振る") { roll() }
                    .disabled(rolling)
            }
            if !rolls.isEmpty {
                Section("結果") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 72), spacing: 10)], spacing: 10) {
                        ForEach(Array(rolls.enumerated()), id: \.offset) { index, value in
                            DiceFaceView(value: value, sides: sides)
                                .rotationEffect(.degrees(rolling ? (index % 2 == 0 ? tilt : -tilt) : 0))
                        }
                    }
                    .padding(.vertical, 4)
                    HStack(alignment: .firstTextBaseline) {
                        Text("合計").foregroundStyle(.secondary)
                        Spacer()
                        Text(rolling ? "…" : String(rolls.reduce(0, +))).font(.title3.weight(.bold)).monospacedDigit()
                    }
                }
            }
        }
        .onChange(of: sides) { _, _ in rolls = [] }
    }

    private func throwOnce() -> [Int] { (0..<count).map { _ in Int.random(in: 1...sides) } }

    private func roll() {
        if reduceMotion {
            rolls = throwOnce()
            return
        }
        rolling = true
        Task { @MainActor in
            // 短い間、目を切り替えながら左右に傾ける
            for step in 0..<7 {
                rolls = throwOnce()
                withAnimation(.linear(duration: 0.07)) { tilt = step % 2 == 0 ? 14 : -14 }
                try? await Task.sleep(nanoseconds: 75_000_000)
            }
            rolls = throwOnce()
            withAnimation(.spring(duration: 0.2)) {
                tilt = 0
                rolling = false
            }
        }
    }
}

// MARK: - コイントス

/// コインの絵。角度に合わせて、手前に見える面を切り替える。
struct CoinView: View, Animatable {
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let heads = CoinFlip.showsHeads(angle: angle)
        ZStack {
            Circle().fill(heads ? Color(red: 0.93, green: 0.76, blue: 0.27) : Color(red: 0.75, green: 0.77, blue: 0.8))
            Circle().strokeBorder(heads ? Color(red: 0.7, green: 0.52, blue: 0.1) : Color(red: 0.5, green: 0.52, blue: 0.56), lineWidth: 6)
            Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1).padding(10)
            VStack(spacing: 0) {
                Image(systemName: heads ? "sun.max.fill" : "leaf.fill").font(.system(size: 26))
                Text(heads ? "表" : "裏").font(.system(size: 44, weight: .heavy, design: .rounded))
            }
            .foregroundStyle(heads ? Color(red: 0.45, green: 0.3, blue: 0.02) : Color(red: 0.25, green: 0.27, blue: 0.32))
            // 裏の面は、回転で文字が裏返らないように戻す
            .scaleEffect(x: 1, y: heads ? 1 : -1)
        }
        .frame(width: 150, height: 150)
        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
    }
}

struct CoinToolView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0
    @State private var result: Bool?
    @State private var flipping = false
    @State private var heads = 0
    @State private var tails = 0
    @State private var lift = 0.0

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    CoinView(angle: angle)
                        .offset(y: -lift)
                        .padding(.top, 30)
                    Text(flipping ? " " : (result.map { $0 ? "表" : "裏" } ?? "—"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                Button(flipping ? "投げています…" : "投げる") { flip() }
                    .disabled(flipping)
            }
            Section("これまで") {
                counterRow("表", heads)
                counterRow("裏", tails)
                Button("リセット") {
                    heads = 0
                    tails = 0
                    result = nil
                }
            }
        }
    }

    private func counterRow(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(value)回").font(.title3.weight(.bold)).monospacedDigit()
        }
    }

    private func finish(_ value: Bool) {
        result = value
        if value { heads += 1 } else { tails += 1 }
    }

    private func flip() {
        let value = Bool.random()
        let target = CoinFlip.targetAngle(current: angle, heads: value, turns: 3)
        if reduceMotion {
            angle = target
            finish(value)
            return
        }
        flipping = true
        let duration = 1.1
        withAnimation(.easeOut(duration: duration)) { angle = target }
        withAnimation(.easeOut(duration: duration / 2)) { lift = 24 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration / 2 * 1_000_000_000))
            withAnimation(.easeIn(duration: duration / 2)) { lift = 0 }
            try? await Task.sleep(nanoseconds: UInt64(duration / 2 * 1_000_000_000))
            flipping = false
            finish(value)
        }
    }
}

// MARK: - トーナメント表

/// 山型の表を1枚の Canvas で描く。枠・名前・線をまとめて描き、タップは配置(TournamentLayout)から判定する。
struct TournamentChartCanvas: View, Equatable {
    let layout: TournamentLayout
    let scale: CGFloat
    let selected: String?

    var body: some View {
        Canvas { context, _ in
            var context = context
            context.scaleBy(x: scale, y: scale)
            // 線は、まだの線と、勝ち上がった線の2回でまとめて描く
            var pending = Path()
            var won = Path()
            for connector in layout.connectors {
                if connector.isWon { won.addLines(connector.points) } else { pending.addLines(connector.points) }
            }
            context.stroke(pending, with: .color(.gray.opacity(0.6)), lineWidth: 1.5)
            context.stroke(won, with: .color(.orange), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

            for title in layout.roundTitles {
                context.draw(Text(title.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondary),
                             at: CGPoint(x: title.x + 2, y: 12 + TournamentLayout.titleHeight / 2), anchor: .leading)
            }
            for box in layout.boxes {
                let shape = Path(roundedRect: box.rect, cornerRadius: 6)
                context.fill(shape, with: .color(Color(.secondarySystemBackground)))
                let isSelected = selected == "\(box.round)-\(box.index)"
                context.stroke(shape, with: .color(isSelected ? .accentColor : .gray.opacity(0.7)), lineWidth: isSelected ? 2 : 1)
                var divider = Path()
                divider.move(to: CGPoint(x: box.rect.minX, y: box.rect.midY))
                divider.addLine(to: CGPoint(x: box.rect.maxX, y: box.rect.midY))
                context.stroke(divider, with: .color(.gray.opacity(0.35)), lineWidth: 0.5)
                for slot in [box.first, box.second] { draw(slot, in: &context) }
            }
            // 優勝者
            let championShape = Path(roundedRect: layout.championRect, cornerRadius: 10)
            context.fill(championShape, with: .color(.orange.opacity(layout.champion == nil ? 0.08 : 0.2)))
            context.stroke(championShape, with: .color(.orange), lineWidth: layout.champion == nil ? 1 : 2)
            context.draw(Text("優勝").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.orange),
                         at: CGPoint(x: layout.championRect.midX, y: layout.championRect.minY + 13), anchor: .center)
            let name = layout.champion.map { TournamentLayout.shortName($0, units: 12) } ?? "—"
            context.draw(Text(name).font(.system(size: 18, weight: .heavy)).foregroundStyle(layout.champion == nil ? Color.secondary : Color.primary),
                         at: CGPoint(x: layout.championRect.midX, y: layout.championRect.minY + 40), anchor: .center)
        }
        .frame(width: layout.size.width * scale, height: layout.size.height * scale)
    }

    private func draw(_ slot: TournamentLayout.Slot, in context: inout GraphicsContext) {
        if slot.isWinner {
            context.fill(Path(roundedRect: slot.rect.insetBy(dx: 1, dy: 1), cornerRadius: 5), with: .color(.orange.opacity(0.22)))
        }
        let text: Text
        if slot.name == nil {
            text = Text("未定").font(.system(size: 12)).foregroundStyle(Color.secondary.opacity(0.7))
        } else if slot.isWinner {
            text = Text(slot.shortName).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.orange)
        } else if slot.isLoser {
            text = Text(slot.shortName).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.35))
        } else {
            text = Text(slot.shortName).font(.system(size: 13)).foregroundStyle(Color.primary)
        }
        context.draw(text, at: CGPoint(x: slot.rect.minX + 7, y: slot.rect.midY), anchor: .leading)
        if slot.isSeeded {
            // 不戦勝で上がってきた枠。線の代わりに、左に印を付ける
            let tag = CGRect(x: slot.rect.minX - 34, y: slot.rect.midY - 8, width: 30, height: 16)
            context.fill(Path(roundedRect: tag, cornerRadius: 4), with: .color(.blue.opacity(0.18)))
            context.draw(Text("シード").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.blue),
                         at: CGPoint(x: tag.midX, y: tag.midY), anchor: .center)
        }
    }
}

/// 表のスクロールと拡大・縮小
struct TournamentChartView: View {
    let tournament: Tournament
    let onPick: (_ round: Int, _ index: Int, _ name: String?) -> Void
    @State private var scale: CGFloat = 1
    @State private var pinchBase: CGFloat?
    @State private var fitted = false
    @State private var selected: String?

    var body: some View {
        let layout = TournamentLayout.make(tournament)
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let fit = TournamentLayout.fitScale(content: layout.size, viewport: proxy.size)
                ScrollView([.horizontal, .vertical]) {
                    TournamentChartCanvas(layout: layout, scale: scale, selected: selected)
                        .equatable()
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            tap(CGPoint(x: value.location.x / scale, y: value.location.y / scale), layout: layout)
                        })
                }
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? scale
                        pinchBase = base
                        scale = min(max(base * value.magnification, min(fit, 0.5)), 3)
                    }
                    .onEnded { _ in pinchBase = nil })
                .onAppear {
                    if !fitted {
                        scale = fit
                        fitted = true
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { scale = fit }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .padding(10)
                            .background(.thinMaterial, in: Circle())
                    }
                    .accessibilityLabel("全体を表示")
                    .padding(10)
                }
            }
            Divider()
            detail
        }
    }

    /// 選んだ試合の、省略していない名前
    @ViewBuilder
    private var detail: some View {
        if let match = tournament.rounds.joined().first(where: { $0.id == selected }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TournamentLayout.roundTitle(match.round, total: tournament.rounds.count) + " 第\(match.index + 1)試合")
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(match.first ?? "未定") 対 \(match.second ?? "未定")")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let winner = match.winner {
                    Text("勝者: \(winner)").font(.subheadline.weight(.bold)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            Text("勝者の名前をタップすると、次の試合へ進みます。もう一度タップすると取り消します。ピンチで拡大・縮小できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    private func tap(_ point: CGPoint, layout: TournamentLayout) {
        guard let hit = layout.hit(at: point) else {
            selected = nil
            return
        }
        selected = "\(hit.box.round)-\(hit.box.index)"
        let slot = hit.isFirst ? hit.box.first : hit.box.second
        guard hit.box.canPlay, let name = slot.name else { return }
        onPick(hit.box.round, hit.box.index, slot.isWinner ? nil : name)
    }
}

struct TournamentToolView: View {
    @AppStorage("tools.tournament.players") private var playersText = ""
    @AppStorage("tools.tournament.state") private var stateData = Data()
    @State private var tournament: Tournament?
    @State private var shuffles = false
    @State private var confirmsReset = false

    var body: some View {
        Group {
            if let tournament {
                VStack(spacing: 0) {
                    TournamentChartView(tournament: tournament) { round, index, name in
                        self.tournament?.setWinner(round: round, index: index, name: name)
                        save()
                    }
                    Button("作り直す", role: .destructive) { confirmsReset = true }
                        .padding(.bottom, 8)
                }
            } else {
                setup
            }
        }
        .onAppear {
            if tournament == nil, !stateData.isEmpty { tournament = try? JSONDecoder().decode(Tournament.self, from: stateData) }
        }
        .confirmationDialog("今の表を消して、作り直しますか", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("作り直す", role: .destructive) {
                tournament = nil
                stateData = Data()
            }
        }
    }

    private var setup: some View {
        Form {
            Section {
                Toggle("組み合わせをシャッフルする", isOn: $shuffles)
                Button("組み合わせを作る") {
                    var players = Shuffler.names(from: playersText)
                    if shuffles { players.shuffle() }
                    tournament = Tournament(players: players)
                    save()
                }
                .disabled(!(2...64).contains(Shuffler.names(from: playersText).count))
            } footer: {
                Text("2〜64人。シャッフルしないときは、上に書いた人ほど強いシードになり、人数が半端なときは上の人から不戦勝になります。")
            }
            Section("参加者(1行に1人。上から順にシード)") {
                TextEditor(text: $playersText).frame(minHeight: 160)
            }
        }
        .keyboardDismissable()
    }

    private func save() {
        stateData = (try? JSONEncoder().encode(tournament)) ?? Data()
    }
}

// MARK: - あみだくじ

/// 縦線・横線と、選んだ道。道は trim で少しずつ描く。
private struct AmidaPathShape: Shape {
    let points: [CGPoint]
    let columns: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mapped = points.map { AmidaBoard.position($0, columns: columns, rows: rows, size: rect.size) }
        path.addLines(mapped)
        return path
    }
}

enum AmidaBoard {
    /// 縦線の番号と段を、画面上の位置にする
    static func position(_ point: CGPoint, columns: Int, rows: Int, size: CGSize) -> CGPoint {
        let stepX = size.width / CGFloat(max(columns, 1))
        let stepY = size.height / CGFloat(rows + 1)
        return CGPoint(x: stepX * (point.x + 0.5), y: stepY * point.y)
    }
}

struct AmidaToolView: View {
    @AppStorage("tools.members") private var membersText = ""
    @AppStorage("tools.amida.goals") private var goalsText = "当たり"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var amida: Amida?
    @State private var names: [String] = []
    @State private var goals: [String] = []
    @State private var selected: Int?
    @State private var progress = 1.0
    @State private var reached = true
    @State private var revealsAll = false

    private let columnWidth: CGFloat = 64

    var body: some View {
        Form {
            if let amida {
                Section {
                    ScrollView(.horizontal) { board(amida) }
                    Toggle("結果をすべて表示", isOn: $revealsAll)
                } footer: {
                    Text("上の名前をタップすると、道をたどります。")
                }
                if revealsAll {
                    Section("結果") {
                        ForEach(names.indices, id: \.self) { index in
                            HStack {
                                Text(names[index])
                                Spacer()
                                Text(goalText(amida.result(from: index))).fontWeight(.bold)
                            }
                        }
                    }
                }
                Section {
                    Button("作り直す", role: .destructive) {
                        self.amida = nil
                        selected = nil
                        revealsAll = false
                    }
                }
            } else {
                Section {
                    Button("あみだくじを作る") { create() }
                        .disabled(!(2...12).contains(Shuffler.names(from: membersText).count))
                } footer: {
                    Text("2〜12人。ゴールが人数より少ないときは、残りは「—」(はずれ)になります。ゴールの並びはシャッフルします。")
                }
                Section("メンバー(1行に1人)") {
                    TextEditor(text: $membersText).frame(minHeight: 120)
                }
                Section("ゴール(1行に1つ)") {
                    TextEditor(text: $goalsText).frame(minHeight: 80)
                }
            }
        }
        .keyboardDismissable()
    }

    private func goalText(_ column: Int) -> String { goals.indices.contains(column) ? goals[column] : "—" }

    private func create() {
        names = Shuffler.names(from: membersText)
        var list = Shuffler.names(from: goalsText)
        list = Array(list.prefix(names.count))
        list += [String](repeating: "—", count: names.count - list.count)
        goals = list.shuffled()
        var generator = SystemRandomNumberGenerator()
        amida = Amida(columns: names.count, rows: max(8, names.count + 4), using: &generator)
        selected = nil
        revealsAll = false
    }

    private func board(_ amida: Amida) -> some View {
        let rows = amida.rungs.count
        let width = columnWidth * CGFloat(amida.columns)
        let reachedGoal = selected.map { amida.result(from: $0) }
        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(names.indices, id: \.self) { index in
                    Button {
                        pick(index)
                    } label: {
                        Text(names[index])
                            .font(.caption.weight(selected == index ? .bold : .regular))
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(selected == index ? Color.red : Color.primary)
                            .frame(width: columnWidth - 4, height: 34)
                    }
                    .buttonStyle(.plain)
                    .frame(width: columnWidth)
                }
            }
            ZStack {
                Canvas { context, size in
                    var lines = Path()
                    for column in 0..<amida.columns {
                        lines.move(to: AmidaBoard.position(CGPoint(x: Double(column), y: 0), columns: amida.columns, rows: rows, size: size))
                        lines.addLine(to: AmidaBoard.position(CGPoint(x: Double(column), y: Double(rows + 1)), columns: amida.columns, rows: rows, size: size))
                    }
                    for row in amida.rungs.indices {
                        for gap in amida.rungs[row].indices where amida.rungs[row][gap] {
                            lines.move(to: AmidaBoard.position(CGPoint(x: Double(gap), y: Double(row + 1)), columns: amida.columns, rows: rows, size: size))
                            lines.addLine(to: AmidaBoard.position(CGPoint(x: Double(gap + 1), y: Double(row + 1)), columns: amida.columns, rows: rows, size: size))
                        }
                    }
                    context.stroke(lines, with: .color(.gray), lineWidth: 2)
                }
                if let selected {
                    AmidaPathShape(points: amida.path(from: selected), columns: amida.columns, rows: rows)
                        .trim(from: 0, to: progress)
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: width, height: CGFloat(rows + 1) * 22)
            HStack(spacing: 0) {
                ForEach(0..<amida.columns, id: \.self) { column in
                    let shown = revealsAll || (reachedGoal == column && reached)
                    Text(shown ? goalText(column) : "?")
                        .font(.caption.weight(reachedGoal == column ? .bold : .regular))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(reachedGoal == column && shown ? Color.red : Color.primary)
                        .frame(width: columnWidth - 4, height: 34)
                        .frame(width: columnWidth)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func pick(_ index: Int) {
        selected = index
        if reduceMotion {
            progress = 1
            reached = true
            return
        }
        progress = 0
        reached = false
        withAnimation(.linear(duration: 1.6)) { progress = 1 }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if selected == index { reached = true }
        }
    }
}

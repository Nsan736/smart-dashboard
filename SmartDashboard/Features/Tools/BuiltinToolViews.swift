import AVFoundation
import SwiftUI

/// 大きく出す結果の行
private struct ToolResultRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// 数字の入力欄(結果と同じ画面に置き、キーボードで隠れないようにする)
private struct NumberField: View {
    let title: String
    @Binding var text: String
    var unit = ""

    var body: some View {
        HStack {
            Text(title)
            TextField("0", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
    }
}

private func yen(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return (formatter.string(from: NSNumber(value: value)) ?? String(value)) + "円"
}

// MARK: - 時間

struct DateCalcToolView: View {
    @State private var from = Date()
    @State private var to = Date()
    @State private var daysText = "30"

    var body: some View {
        Form {
            Section("日数の差") {
                DatePicker("開始", selection: $from, displayedComponents: .date)
                DatePicker("終了", selection: $to, displayedComponents: .date)
                ToolResultRow(title: "差", value: "\(DateCalc.days(from: from, to: to))日")
                ToolResultRow(title: "開始の曜日", value: DateCalc.weekdayText(from))
                ToolResultRow(title: "終了の曜日", value: DateCalc.weekdayText(to))
            }
            Section("◯日後・◯日前(開始の日から)") {
                HStack {
                    Text("日数")
                    TextField("30", text: $daysText).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
                if let days = Int(daysText) {
                    let date = DateCalc.adding(days: days, to: from)
                    ToolResultRow(title: days >= 0 ? "\(days)日後" : "\(-days)日前",
                                  value: date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "ja_JP"))) + " " + DateCalc.weekdayText(date))
                }
            }
        }
        .keyboardDismissable()
    }
}

struct WarekiToolView: View {
    @State private var date = Date()
    @State private var era = "令和"
    @State private var eraYearText = "1"

    var body: some View {
        let parts = DateCalc.calendar.dateComponents([.year, .month, .day], from: date)
        let today = DateCalc.calendar.dateComponents([.year, .month, .day], from: Date())
        Form {
            Section("西暦 → 和暦・年齢") {
                DatePicker("日付(生年月日など)", selection: $date, displayedComponents: .date)
                ToolResultRow(title: "和暦", value: Wareki.text(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1) ?? "明治より前")
                ToolResultRow(title: "干支", value: Wareki.zodiac(year: parts.year ?? 0))
                ToolResultRow(title: "今日の時点の満年齢",
                              value: "\(Wareki.age(birthYear: parts.year ?? 0, birthMonth: parts.month ?? 1, birthDay: parts.day ?? 1, onYear: today.year ?? 0, month: today.month ?? 1, day: today.day ?? 1))歳")
            }
            Section("和暦 → 西暦") {
                Picker("元号", selection: $era) {
                    ForEach(Wareki.eras, id: \.name) { Text($0.name).tag($0.name) }
                }
                NumberField(title: "年", text: $eraYearText, unit: "年")
                ToolResultRow(title: "西暦", value: Int(eraYearText).flatMap { Wareki.westernYear(era: era, year: $0) }.map { "\($0)年" } ?? "-")
            }
        }
        .keyboardDismissable()
    }
}

// MARK: - 計算

struct SplitBillToolView: View {
    @State private var totalText = ""
    @State private var people = 4
    @State private var rounding = SplitBill.Rounding.up100

    var body: some View {
        Form {
            Section {
                NumberField(title: "会計", text: $totalText, unit: "円")
                Stepper("人数: \(people)人", value: $people, in: 1...99)
                Picker("端数", selection: $rounding) {
                    ForEach(SplitBill.Rounding.allCases) { Text($0.label).tag($0) }
                }
            }
            if let total = Int(totalText), let result = SplitBill.calculate(total: total, people: people, rounding: rounding) {
                Section("結果") {
                    ToolResultRow(title: "1人あたり", value: yen(result.perPerson))
                    ToolResultRow(title: "集まる合計", value: yen(result.collected))
                    ToolResultRow(title: "余り", value: yen(result.surplus))
                }
            }
        }
        .keyboardDismissable()
    }
}

struct PercentToolView: View {
    @State private var priceText = ""
    @State private var percentText = "20"
    @State private var taxRate = 10.0

    var body: some View {
        let price = Double(priceText)
        Form {
            Section("値段") {
                NumberField(title: "値段", text: $priceText, unit: "円")
            }
            Section("割引") {
                NumberField(title: "割引", text: $percentText, unit: "%引き")
                if let price, let percent = Double(percentText) {
                    ToolResultRow(title: "割引後", value: yen(Int(PercentCalc.discounted(price: price, percentOff: percent))))
                    ToolResultRow(title: "値引き額", value: yen(Int(price - PercentCalc.discounted(price: price, percentOff: percent))))
                }
            }
            Section("消費税") {
                Picker("税率", selection: $taxRate) {
                    Text("10%").tag(10.0)
                    Text("8%(軽減税率)").tag(8.0)
                }
                .pickerStyle(.segmented)
                if let price {
                    ToolResultRow(title: "税抜 → 税込", value: yen(Int(PercentCalc.withTax(price: price, rate: taxRate))))
                    ToolResultRow(title: "税込 → 税抜", value: yen(Int(PercentCalc.withoutTax(price: price, rate: taxRate))))
                }
            }
        }
        .keyboardDismissable()
    }
}

struct UnitConvertToolView: View {
    @State private var kind = UnitKind.length
    @State private var from = 2
    @State private var valueText = "1"

    var body: some View {
        let units = kind.units
        Form {
            Section {
                Picker("種類", selection: $kind) {
                    ForEach(UnitKind.allCases) { Text($0.label).tag($0) }
                }
                Picker("単位", selection: $from) {
                    ForEach(units.indices, id: \.self) { Text(units[$0].name).tag($0) }
                }
                HStack {
                    Text("値")
                    TextField("0", text: $valueText).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
            }
            if let value = Double(valueText), units.indices.contains(from) {
                Section("換算") {
                    ForEach(units.indices, id: \.self) { index in
                        if index != from, let converted = UnitConverter.convert(value, kind: kind, from: from, to: index) {
                            ToolResultRow(title: units[index].name, value: UnitConverter.text(converted))
                        }
                    }
                }
            }
        }
        .keyboardDismissable()
        .onChange(of: kind) { _, _ in from = 0 }
    }
}

struct BaseConvertToolView: View {
    @State private var text = "255"
    @State private var from = 10

    var body: some View {
        Form {
            Section {
                Picker("入力の進数", selection: $from) {
                    ForEach([2, 8, 10, 16], id: \.self) { Text("\($0)進").tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("値", text: $text)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            Section("変換") {
                ForEach([2, 8, 10, 16], id: \.self) { base in
                    ToolResultRow(title: "\(base)進", value: BaseConverter.convert(text, from: from, to: base) ?? "-")
                }
            }
        }
        .keyboardDismissable()
    }
}

// MARK: - 決める・遊ぶ

/// 項目の一覧から選ぶ(ルーレット、くじ引き、順番決め)。内蔵のルーレットと、JSONのリスト型で共通。
struct ListPickerView: View {
    let mode: CustomTool.ListMode
    let items: [String]
    @State private var result: String?
    @State private var remaining: [String] = []
    @State private var order: [String] = []
    @State private var history: [String] = []
    @State private var spinning = false

    var body: some View {
        Section {
            switch mode {
            case .roulette:
                Text(result ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 70)
                    .multilineTextAlignment(.center)
                    .opacity(spinning ? 0.5 : 1)
                Button(spinning ? "回しています…" : "回す") { spin() }
                    .disabled(items.isEmpty || spinning)
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

    /// 少しの間、候補を切り替えてから止める
    private func spin() {
        spinning = true
        Task { @MainActor in
            for step in 0..<12 {
                result = items.randomElement()
                try? await Task.sleep(nanoseconds: UInt64(40_000_000 + step * 12_000_000))
            }
            let final = items.randomElement()
            result = final
            if let final { history.insert(final, at: 0) }
            spinning = false
        }
    }
}

struct RouletteToolView: View {
    @AppStorage("tools.roulette.items") private var itemsText = "A\nB\nC"
    @State private var mode = CustomTool.ListMode.roulette

    var body: some View {
        Form {
            Section {
                Picker("使い方", selection: $mode) {
                    Text("ルーレット").tag(CustomTool.ListMode.roulette)
                    Text("くじ引き").tag(CustomTool.ListMode.lottery)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("くじ引きは、引いたものを戻しません。")
            }
            ListPickerView(mode: mode, items: Shuffler.names(from: itemsText))
            Section("項目(1行に1つ)") {
                TextEditor(text: $itemsText).frame(minHeight: 120)
            }
        }
        .keyboardDismissable()
    }
}

struct DiceToolView: View {
    @State private var count = 2
    @State private var sides = 6
    @State private var rolls: [Int] = []

    var body: some View {
        Form {
            Section {
                Stepper("個数: \(count)", value: $count, in: 1...20)
                Picker("面の数", selection: $sides) {
                    ForEach([4, 6, 8, 10, 12, 20, 100], id: \.self) { Text("\($0)面").tag($0) }
                }
                Button("振る") { rolls = (0..<count).map { _ in Int.random(in: 1...sides) } }
            }
            if !rolls.isEmpty {
                Section("結果") {
                    Text(rolls.map(String.init).joined(separator: "  "))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    ToolResultRow(title: "合計", value: String(rolls.reduce(0, +)))
                }
            }
        }
    }
}

struct CoinToolView: View {
    @State private var result: Bool?
    @State private var heads = 0
    @State private var tails = 0

    var body: some View {
        Form {
            Section {
                Text(result.map { $0 ? "表" : "裏" } ?? "—")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 110)
                Button("投げる") {
                    let value = Bool.random()
                    result = value
                    if value { heads += 1 } else { tails += 1 }
                }
            }
            Section("これまで") {
                ToolResultRow(title: "表", value: "\(heads)回")
                ToolResultRow(title: "裏", value: "\(tails)回")
                Button("リセット") {
                    heads = 0
                    tails = 0
                    result = nil
                }
            }
        }
    }
}

struct TeamsToolView: View {
    @AppStorage("tools.members") private var membersText = ""
    @State private var teamCount = 2
    @State private var teams: [[String]] = []

    var body: some View {
        Form {
            Section {
                Stepper("チームの数: \(teamCount)", value: $teamCount, in: 2...12)
                Button("分ける") {
                    var generator = SystemRandomNumberGenerator()
                    teams = Shuffler.teams(Shuffler.names(from: membersText), count: teamCount, using: &generator)
                }
                .disabled(Shuffler.names(from: membersText).count < 2)
            }
            ForEach(Array(teams.enumerated()), id: \.offset) { index, team in
                Section("チーム\(index + 1)(\(team.count)人)") {
                    ForEach(team, id: \.self) { Text($0) }
                }
            }
            Section("メンバー(1行に1人)") {
                TextEditor(text: $membersText).frame(minHeight: 140)
            }
        }
        .keyboardDismissable()
    }
}

struct OrderToolView: View {
    @AppStorage("tools.members") private var membersText = ""

    var body: some View {
        Form {
            ListPickerView(mode: .order, items: Shuffler.names(from: membersText))
            Section("メンバー(1行に1人)") {
                TextEditor(text: $membersText).frame(minHeight: 140)
            }
        }
        .keyboardDismissable()
    }
}

struct TournamentToolView: View {
    @AppStorage("tools.tournament.players") private var playersText = ""
    @AppStorage("tools.tournament.state") private var stateData = Data()
    @State private var tournament: Tournament?
    @State private var shuffles = false

    var body: some View {
        Form {
            if let tournament {
                if let champion = tournament.champion {
                    Section {
                        Label("優勝: \(champion)", systemImage: "trophy.fill").font(.title3.weight(.bold)).foregroundStyle(.orange)
                    }
                }
                ForEach(tournament.rounds.indices, id: \.self) { round in
                    Section(roundTitle(round, total: tournament.rounds.count)) {
                        ForEach(tournament.rounds[round]) { match in
                            matchRow(match)
                        }
                    }
                }
                Section {
                    Button("作り直す", role: .destructive) {
                        self.tournament = nil
                        stateData = Data()
                    }
                }
            } else {
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
                    Text("2〜64人。シャッフルしないときは、上に書いた人ほど強いシードになり、人数が半端なときは上の人から不戦勝になります。勝者の名前をタップすると、次の試合へ進みます。")
                }
                Section("参加者(1行に1人。上から順にシード)") {
                    TextEditor(text: $playersText).frame(minHeight: 160)
                }
            }
        }
        .keyboardDismissable()
        .onAppear {
            if tournament == nil, !stateData.isEmpty { tournament = try? JSONDecoder().decode(Tournament.self, from: stateData) }
        }
    }

    private func roundTitle(_ round: Int, total: Int) -> String {
        if round == total - 1 { return "決勝" }
        if round == total - 2 { return "準決勝" }
        return "\(round + 1)回戦"
    }

    private func save() {
        stateData = (try? JSONEncoder().encode(tournament)) ?? Data()
    }

    @ViewBuilder
    private func matchRow(_ match: Tournament.Match) -> some View {
        if match.isBye {
            Text("\(match.first ?? match.second ?? "")(不戦勝)").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                playerButton(match.first, in: match)
                Text("対").font(.caption).foregroundStyle(.secondary)
                playerButton(match.second, in: match)
            }
        }
    }

    private func playerButton(_ name: String?, in match: Tournament.Match) -> some View {
        Button {
            guard let name else { return }
            tournament?.setWinner(round: match.round, index: match.index, name: match.winner == name ? nil : name)
            save()
        } label: {
            Text(name ?? "未定")
                .fontWeight(match.winner != nil && match.winner == name ? .bold : .regular)
                .foregroundStyle(name == nil ? Color.secondary : (match.winner == name ? Color.orange : Color.primary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(name == nil || match.first == nil || match.second == nil)
    }
}

struct CounterToolView: View {
    struct Counter: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var value = 0
    }

    @AppStorage("tools.counters") private var data = Data()
    @State private var counters: [Counter] = []
    @State private var pendingDelete: Counter?

    var body: some View {
        Form {
            ForEach($counters) { $counter in
                Section {
                    TextField("名前", text: $counter.name)
                    HStack {
                        Button {
                            counter.value -= 1
                        } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 38))
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Text("\(counter.value)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        Spacer()
                        Button {
                            counter.value += 1
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 38))
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack {
                        Button("0に戻す") { counter.value = 0 }.buttonStyle(.borderless)
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = counter
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section {
                Button("カウンターを追加") { counters.append(Counter(name: "カウンター\(counters.count + 1)")) }
            }
        }
        .keyboardDismissable()
        .onAppear {
            if counters.isEmpty { counters = (try? JSONDecoder().decode([Counter].self, from: data)) ?? [Counter(name: "カウンター1")] }
        }
        .onChange(of: counters) { _, new in data = (try? JSONEncoder().encode(new)) ?? Data() }
        .confirmationDialog("このカウンターを削除しますか", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { counter in
            Button("削除", role: .destructive) { counters.removeAll { $0.id == counter.id } }
        }
    }
}

// MARK: - 文字

struct TextCountToolView: View {
    @State private var text = ""
    @State private var countsNewlines = false

    var body: some View {
        let result = TextCount.count(text, countsNewlines: countsNewlines)
        Form {
            Section("結果") {
                ToolResultRow(title: "文字数", value: "\(result.characters)")
                ToolResultRow(title: "空白を除く", value: "\(result.charactersWithoutSpaces)")
                ToolResultRow(title: "全角を2、半角を1で数える", value: "\(result.halfWidthUnits)")
                ToolResultRow(title: "行数", value: "\(result.lines)")
                ToolResultRow(title: "バイト数(UTF-8)", value: "\(result.utf8Bytes)")
                Toggle("改行も1文字として数える", isOn: $countsNewlines)
            }
            Section("文章") {
                TextEditor(text: $text).frame(minHeight: 180)
                HStack {
                    Button("貼り付け") { text = UIPasteboard.general.string ?? text }.buttonStyle(.borderless)
                    Spacer()
                    Button("消去", role: .destructive) { text = "" }.buttonStyle(.borderless)
                }
            }
        }
        .keyboardDismissable()
    }
}

struct KanaConvertToolView: View {
    @State private var text = ""

    var body: some View {
        Form {
            Section("文章") {
                TextEditor(text: $text).frame(minHeight: 120)
                Button("貼り付け") { text = UIPasteboard.general.string ?? text }.buttonStyle(.borderless)
            }
            Section("変換(タップでコピー)") {
                row("ひらがな", KanaConvert.hiragana(text))
                row("カタカナ", KanaConvert.katakana(text))
                row("半角", KanaConvert.halfWidth(text))
                row("全角", KanaConvert.fullWidth(text))
                row("大文字", text.uppercased())
                row("小文字", text.lowercased())
            }
        }
        .keyboardDismissable()
    }

    private func row(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value.isEmpty ? "—" : value).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PasswordToolView: View {
    @State private var options = PasswordGenerator.Options()
    @State private var password = ""
    @State private var minText = "1"
    @State private var maxText = "100"
    @State private var number: Int?

    var body: some View {
        Form {
            Section("パスワード") {
                Text(password.isEmpty ? "—" : password)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("長さ: \(options.length)", value: $options.length, in: 4...64)
                Toggle("小文字", isOn: $options.lowercase)
                Toggle("大文字", isOn: $options.uppercase)
                Toggle("数字", isOn: $options.digits)
                Toggle("記号", isOn: $options.symbols)
                Toggle("見間違えやすい文字を除く(0 O 1 l など)", isOn: $options.avoidsAmbiguous)
                HStack {
                    Button("作る") {
                        var generator = SystemRandomNumberGenerator()
                        password = PasswordGenerator.generate(options, using: &generator)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button("コピー") { UIPasteboard.general.string = password }.buttonStyle(.borderless).disabled(password.isEmpty)
                }
            }
            Section("乱数") {
                NumberField(title: "最小", text: $minText)
                NumberField(title: "最大", text: $maxText)
                ToolResultRow(title: "結果", value: number.map(String.init) ?? "—")
                Button("作る") {
                    if let low = Int(minText), let high = Int(maxText), low <= high { number = Int.random(in: low...high) }
                }
            }
        }
        .keyboardDismissable()
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

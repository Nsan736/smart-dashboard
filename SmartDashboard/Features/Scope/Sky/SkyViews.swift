import SwiftUI

/// カメラ表示の下に出す、太陽と月の日付と時刻を変える操作(今日・明日・夏至・冬至・日付を選ぶ、時刻を指でずらす)
struct SkyTimePanel: View {
    @Binding var day: Date
    @Binding var time: Date?
    let displayTime: Date
    let scene: SkyScene?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("太陽と月").font(.subheadline.weight(.bold))
                Text(SkyText.dateTime(displayTime)).font(.subheadline.monospacedDigit())
                Spacer()
                Button("閉じる", action: onClose).font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button("今") {
                        day = Date()
                        time = nil
                    }
                    Button("今日") { choose(Date()) }
                    Button("明日") { choose(Date().addingTimeInterval(86_400)) }
                    Button("夏至") { if let date = Self.nextSolstice(summer: true) { choose(date) } }
                    Button("冬至") { if let date = Self.nextSolstice(summer: false) { choose(date) } }
                    DatePicker("日付", selection: Binding(get: { day }, set: { choose($0) }), displayedComponents: .date)
                        .labelsHidden()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            Slider(value: Binding(get: { Self.minutes(of: displayTime) }, set: { minutes in
                time = SkyEvents.startOfDay(day).addingTimeInterval(minutes * 60)
            }), in: 0...1439, step: 5)
            if let scene {
                Text([scene.sunriseText(), scene.sunsetText()].compactMap { $0 }.joined(separator: "・"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("月の出 " + (scene.moonRise.map { SkyText.time($0.date) } ?? "なし") + "・月の入り "
                     + (scene.moonSet.map { SkyText.time($0.date) } ?? "なし") + "・" + SkyText.phase(Astronomy.moonPhase(displayTime)))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if !scene.hasTerrain {
                    Text("景色の稜線がないので、地平線での時刻です(景色の表示をオンにすると、山に沈む時刻も出します)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }

    /// 別の日にするときは、時刻はそのまま(今の時刻、または選んでいた時刻)
    private func choose(_ date: Date) {
        let minutes = Self.minutes(of: displayTime)
        day = date
        if time != nil || !Calendar.japan.isDate(date, inSameDayAs: Date()) {
            time = SkyEvents.startOfDay(date).addingTimeInterval(minutes * 60)
        } else {
            time = nil
        }
    }

    static func minutes(of date: Date) -> Double {
        (date.timeIntervalSince(SkyEvents.startOfDay(date)) / 60).rounded()
    }

    /// これからの夏至・冬至(今年のが過ぎていれば来年)
    static func nextSolstice(summer: Bool, now: Date = Date()) -> Date? {
        let year = Calendar.japan.component(.year, from: now)
        if let date = SkyEvents.solstice(year: year, summer: summer), date > now.addingTimeInterval(-86_400) { return date }
        return SkyEvents.solstice(year: year + 1, summer: summer)
    }
}

/// 管理の「太陽と月」: その日の出入り(地平線・稜線)、月の満ち欠け、ダイヤモンド富士・パール富士の予報
struct SkyDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var day = Date()
    @State private var scene: SkyScene?

    var body: some View {
        let origin = env.waypoints.origin
        List {
            Section {
                DatePicker("日付", selection: $day, displayedComponents: .date)
                if let origin {
                    LabeledContent("場所", value: String(format: "%.4f, %.4f", origin.latitude, origin.longitude))
                } else {
                    Text("現在地がまだ分かりません(スコープのカメラ表示か地点の一覧を開くと測ります)").foregroundStyle(.secondary)
                }
            } footer: {
                Text("場所は、最後に分かった現在地です。計算は端末の中だけで行い、通信しません(太陽は NOAA の式、月は Meeus の式。国立天文台の暦計算室の東京の値と、出入りの時刻で1分以内)。")
            }
            if let scene {
                Section("太陽") {
                    row("日の出", scene.sunRise)
                    row("日の入り", scene.sunSet)
                    if scene.hasTerrain {
                        row("山から出る", scene.terrainSunRise)
                        row("山に沈む", scene.terrainSunSet)
                    } else {
                        Text("景色の稜線がないので、山に沈む時刻は出せません(スコープで景色の表示をオンにして、景色を計算すると出ます)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("月") {
                    row("月の出", scene.moonRise)
                    row("月の入り", scene.moonSet)
                    Text(SkyText.phase(Astronomy.moonPhase(SkyEvents.startOfDay(day).addingTimeInterval(12 * 3600))) + "(正午)")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                NavigationLink {
                    SummitForecastView()
                } label: {
                    Label("ダイヤモンド富士・パール富士の予報", systemImage: "mountain.2")
                }
            }
        }
        .navigationTitle("太陽と月")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(Int(SkyEvents.startOfDay(day).timeIntervalSince1970))|\(origin?.latitude ?? 0)|\(origin?.longitude ?? 0)") {
            guard let origin else { return }
            let skyline = nearbySkyline(latitude: origin.latitude, longitude: origin.longitude)
            let day = day
            scene = await Task.detached(priority: .utility) { () -> SkyScene in
                var horizon: ((Double) -> Double?)?
                if let skyline { horizon = { bearing in skyline.horizonAngle(atBearing: bearing) } }
                return SkyScene.make(day: day, latitude: origin.latitude, longitude: origin.longitude, horizon: horizon)
            }.value
        }
    }

    /// 景色を計算した場所が近ければ(1km 以内)、その稜線
    private func nearbySkyline(latitude: Double, longitude: Double) -> Skyline? {
        guard let scene = env.scenery.scene, let skyline = scene.skyline else { return nil }
        let distance = WaypointMath.distance(fromLatitude: latitude, longitude: longitude, toLatitude: scene.latitude, longitude: scene.longitude)
        return distance <= 1_000 ? skyline : nil
    }

    private func row(_ name: String, _ event: SkyEvent?) -> some View {
        LabeledContent(name) {
            if let event {
                Text("\(SkyText.time(event.date))・方角\(Int(event.azimuth.rounded()))°(\(WaypointMath.compassPoint(event.azimuth)))")
                    .monospacedDigit()
            } else {
                Text("なし")
            }
        }
    }
}

/// 別のスレッドの計算に、やめることを伝える
final class SkyCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}

/// ダイヤモンド富士・パール富士の予報の計算(メインスレッドの外で行い、進み具合を出す)
@MainActor
@Observable
final class SummitForecastModel {
    private(set) var results: [SummitAlignment] = []
    private(set) var progress: Double?
    private(set) var elapsed: TimeInterval?
    private(set) var errorText: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var flag = SkyCancelFlag()
    private(set) var isRunning = false

    struct Input: Sendable {
        var latitude: Double
        var longitude: Double
        var eye: Double
        var peakLatitude: Double
        var peakLongitude: Double
        var peakElevation: Double
        var bodies: [SkyBody]
        var days: Int
        var start: Date
    }

    func run(_ input: Input) {
        cancel()
        let flag = SkyCancelFlag()
        self.flag = flag
        isRunning = true
        results = []
        errorText = nil
        progress = 0
        let began = Date()
        let bearing = WaypointMath.bearing(fromLatitude: input.latitude, longitude: input.longitude,
                                           toLatitude: input.peakLatitude, longitude: input.peakLongitude)
        let distance = WaypointMath.distance(fromLatitude: input.latitude, longitude: input.longitude,
                                             toLatitude: input.peakLatitude, longitude: input.peakLongitude)
        // 山頂の見かけの仰角(地球の丸みと、地上の大気の屈折を考える)
        let angle = WaypointElevation.angle(targetAltitude: input.peakElevation, observerAltitude: input.eye, distance: distance)
        task = Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [SummitAlignment] in
                var all: [SummitAlignment] = []
                for (index, body) in input.bodies.enumerated() {
                    let share = 1 / Double(input.bodies.count)
                    all += SummitAlignmentSearch.search(body, from: input.start, days: input.days, latitude: input.latitude,
                                                        longitude: input.longitude, peakBearing: bearing, peakAngle: angle) { value in
                        let overall = (Double(index) + value) * share
                        Task { @MainActor in if !flag.isCancelled { self.progress = overall } }
                        return !flag.isCancelled
                    }
                }
                return all.sorted { $0.date < $1.date }
            }.value
            guard !flag.isCancelled else { return }
            results = found
            elapsed = Date().timeIntervalSince(began)
            progress = nil
            isRunning = false
            task = nil
        }
    }

    func cancel() {
        flag.cancel()
        task = nil
        progress = nil
        isRunning = false
    }
}

/// ダイヤモンド富士・パール富士の予報: 山を選び(初期値は富士山)、今いる場所か地点から、太陽・月がその山頂に昇る・沈む日時を1年分
struct SummitForecastView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = SummitForecastModel()
    @State private var mountainIndex: Int?
    @State private var observerID: UUID?
    @State private var bodies: Set<SkyBody> = [.sun, .moon]
    @State private var showsMountains = false

    private var catalog: [MountainCatalog.Entry] { MountainCatalog.bundled.entries }

    private var mountain: MountainCatalog.Entry? {
        if let mountainIndex { return catalog.first { $0.index == mountainIndex } }
        return catalog.first { $0.name == "富士山" } ?? catalog.first
    }

    var body: some View {
        List {
            Section {
                Button {
                    showsMountains = true
                } label: {
                    LabeledContent("山", value: mountain.map { "\($0.displayName) \(SceneryText.elevation($0.elevation))" } ?? "なし")
                }
                Picker("見る場所", selection: $observerID) {
                    Text("現在地(最後に分かった位置)").tag(UUID?.none)
                    ForEach(env.waypoints.waypoints) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Toggle("太陽(ダイヤモンド)", isOn: binding(.sun))
                Toggle("月(パール)", isOn: binding(.moon))
                if model.isRunning {
                    HStack {
                        ProgressView(value: model.progress ?? 0)
                        Button("中止", role: .destructive) { model.cancel() }
                    }
                } else {
                    Button("これから1年分を計算する") { start() }
                        .disabled(input == nil || bodies.isEmpty)
                }
                if input == nil {
                    Text("見る場所が分かりません(現在地を測るか、地点を選んでください)").font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                Text("太陽・月の中心が、山頂から ±\(String(format: "%.2f", SummitAlignmentSearch.tolerance))° 以内に来る日時を出します。地平線の近くの大気の屈折と、地球の丸み・地上の屈折を考えます。山頂が手前の山に隠れていないかは調べていません。計算は端末の中だけで行います。")
            }
            if let elapsed = model.elapsed {
                Section {
                    if model.results.isEmpty {
                        Text("この1年には見つかりませんでした").foregroundStyle(.secondary)
                    }
                    ForEach(model.results) { result in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SkyText.dateTime(result.date)).font(.headline.monospacedDigit())
                            Text(caption(result)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("予報(\(model.results.count)件)")
                } footer: {
                    Text(String(format: "計算 %.2f秒", elapsed))
                }
            }
        }
        .navigationTitle("ダイヤモンド富士の予報")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsMountains) {
            MountainPickerView(catalog: catalog) { entry in mountainIndex = entry.index }
        }
        .onDisappear { model.cancel() }
    }

    private func binding(_ body: SkyBody) -> Binding<Bool> {
        Binding(get: { bodies.contains(body) }, set: { on in
            if on { bodies.insert(body) } else { bodies.remove(body) }
        })
    }

    private func caption(_ result: SummitAlignment) -> String {
        var parts = [result.body == .sun ? "ダイヤモンド(太陽)" : "パール(月)", result.isRising ? "昇る" : "沈む",
                     String(format: "中心のずれ %.2f°", result.separation)]
        if let illumination = result.illumination { parts.append("月の輝き \(Int((illumination * 100).rounded()))%") }
        return parts.joined(separator: "・")
    }

    /// 計算の入力(見る場所の緯度経度と目の高さ、山頂)
    private var input: SummitForecastModel.Input? {
        guard let mountain else { return nil }
        let hand = env.settings.scopeHandHeight
        var latitude: Double, longitude: Double, eye: Double
        if let observerID, let waypoint = env.waypoints.waypoints.first(where: { $0.id == observerID }) {
            latitude = waypoint.latitude
            longitude = waypoint.longitude
            eye = (waypoint.altitude ?? 0) + hand
        } else if let origin = env.waypoints.origin {
            latitude = origin.latitude
            longitude = origin.longitude
            eye = origin.height ?? hand
        } else {
            return nil
        }
        return SummitForecastModel.Input(latitude: latitude, longitude: longitude, eye: eye, peakLatitude: mountain.latitude,
                                         peakLongitude: mountain.longitude, peakElevation: mountain.elevation,
                                         bodies: SkyBody.allCases.filter { bodies.contains($0) }, days: 365, start: Date())
    }

    private func start() {
        guard let input else { return }
        model.run(input)
    }
}

/// 山の一覧から選ぶ(名前で探す)
struct MountainPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let catalog: [MountainCatalog.Entry]
    let onSelect: (MountainCatalog.Entry) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(filtered.prefix(100), id: \.index) { entry in
                Button {
                    onSelect(entry)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName).foregroundStyle(Color.primary)
                        Text("\(SceneryText.elevation(entry.elevation))・\(entry.prefecture)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $query, prompt: "山の名前")
            .navigationTitle("山を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private var filtered: [MountainCatalog.Entry] {
        let text = ToolSearch.normalize(query)
        guard !text.isEmpty else { return catalog.sorted { $0.elevation > $1.elevation } }
        return catalog.filter { ToolSearch.normalize($0.name + $0.peak + $0.prefecture).contains(text) }
    }
}

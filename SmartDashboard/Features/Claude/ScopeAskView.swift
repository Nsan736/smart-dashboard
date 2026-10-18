import CoreLocation
import SafariServices
import SwiftUI

/// 「撮って聞く」の1回分(全画面で出すための入れ物)
struct ScopeAskSession: Identifiable {
    let id = UUID()
    var snapshot: ScopeAskSnapshot
}

/// 止めた映像の上で、指で囲んで Claude に聞く。画像は端末に保存せず、画面を閉じたら捨てる。
struct ScopeAskView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: ScopeAskSnapshot
    /// 確定した囲み(画像のピクセル)。なければ画像全体を送る。
    @State private var shape: [CGPoint]?
    /// 取り消しのための、前の囲み
    @State private var undoStack: [[CGPoint]?] = []
    /// 描いている途中の線
    @State private var stroke: [CGPoint] = []
    @State private var questionText = ""
    @State private var exchanges: [ScopeAskExchange] = []
    /// 送った画像(続けて質問するときも同じものを送る)。囲みを変えたら作り直す。
    @State private var jpeg: Data?
    @State private var task: Task<Void, Never>?
    @State private var notice: String?
    /// 出典を開く(SFSafariViewController)
    @State private var openedURL: ScopeAskURL?
    /// 地点に登録する場所
    @State private var registering: ScopeAskPlaceTarget?
    @FocusState private var isQuestionFocused: Bool

    init(snapshot: ScopeAskSnapshot) {
        _snapshot = State(initialValue: snapshot)
    }

    private var isThinking: Bool { task != nil }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    imageArea
                        .frame(height: geometry.size.height * 0.45)
                    drawingControls
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(exchanges) { exchangeView($0).id($0.id) }
                                questionArea.id("question")
                            }
                            .padding()
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onChange(of: exchanges) { _, _ in
                            withAnimation { proxy.scrollTo("question", anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("撮って聞く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .keyboardDismissable()
            .task {
                // 地名は、送る設定のときだけ求める(500m以内で求めた地名があれば通信しない)
                guard env.settings.claude.sendsPlace, snapshot.placeName == nil,
                      let latitude = snapshot.latitude, let longitude = snapshot.longitude else { return }
                snapshot.placeName = await env.placeNames.name(latitude: latitude, longitude: longitude)
            }
            .onDisappear { task?.cancel() }
            .sheet(item: $openedURL) { item in
                ScopeAskSafariView(url: item.url).ignoresSafeArea()
            }
            .sheet(item: $registering) { target in
                ScopeAskPlaceSheet(target: target)
            }
        }
    }

    // MARK: - 画像と囲み

    private var imageArea: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: snapshot.image.width, height: snapshot.image.height)
            let frame = Self.fittedFrame(imageSize: imageSize, in: geometry.size)
            let scale = frame.width / max(imageSize.width, 1)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(decorative: snapshot.image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                Canvas { context, _ in
                    let toView = { (point: CGPoint) in CGPoint(x: frame.minX + point.x * scale, y: frame.minY + point.y * scale) }
                    if let shape, shape.count >= 3 {
                        var outside = Path(frame)
                        outside.addLines(shape.map(toView))
                        outside.closeSubpath()
                        context.fill(outside, with: .color(Color.black.opacity(0.5)), style: FillStyle(eoFill: true))
                        var outline = Path()
                        outline.addLines(shape.map(toView))
                        outline.closeSubpath()
                        context.stroke(outline, with: .color(.yellow), lineWidth: 2.5)
                    }
                    if stroke.count >= 2 {
                        var line = Path()
                        line.addLines(stroke.map(toView))
                        context.stroke(line, with: .color(.yellow), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = CGPoint(x: (value.location.x - frame.minX) / scale, y: (value.location.y - frame.minY) / scale)
                            let clamped = CGPoint(x: min(max(point.x, 0), imageSize.width), y: min(max(point.y, 0), imageSize.height))
                            // 細かすぎる点は間引く(画面で3pt以上動いたら足す)
                            if let last = stroke.last, hypot(last.x - clamped.x, last.y - clamped.y) * scale < 3 { return }
                            stroke.append(clamped)
                        }
                        .onEnded { _ in
                            let drawn = stroke
                            stroke = []
                            guard ScopeAskImage.bounds(of: drawn, imageSize: imageSize) != nil else { return }
                            setShape(drawn)
                        }
                )
                .disabled(isThinking)
            }
        }
    }

    private var drawingControls: some View {
        HStack(spacing: 12) {
            Text(shape == nil ? "指で丸く囲むと、その部分だけを送ります(囲まなければ全体)" : "囲んだ部分だけを送ります")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                if let previous = undoStack.popLast() { applyShape(previous) }
            } label: {
                Label("取り消し", systemImage: "arrow.uturn.backward")
            }
            .disabled(undoStack.isEmpty || isThinking)
            Button {
                setShape(nil)
            } label: {
                Label("描き直し", systemImage: "eraser")
            }
            .disabled(shape == nil || isThinking)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func setShape(_ new: [CGPoint]?) {
        undoStack.append(shape)
        applyShape(new)
    }

    private func applyShape(_ new: [CGPoint]?) {
        shape = new
        // 画像が変わるので、前のやり取りは続けない
        if jpeg != nil {
            jpeg = nil
            if !exchanges.isEmpty {
                exchanges = []
                notice = "囲みを変えたので、新しい画像として聞きます"
            }
        }
    }

    /// 画像を、領域の中に縦横比を保って収めた位置
    static func fittedFrame(imageSize: CGSize, in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    // MARK: - 質問と答え

    private func exchangeView(_ exchange: ScopeAskExchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exchange.question)
                .font(.subheadline.weight(.semibold))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            if let answer = exchange.answer {
                Text(answer)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = exchange.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("考え中…").foregroundStyle(.secondary)
                    Spacer()
                    Button("取り消し", role: .cancel) { task?.cancel() }
                        .buttonStyle(.bordered)
                }
            }
            if !exchange.citations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("出典(Web 検索)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(exchange.citations) { citation in
                        Button {
                            if let url = URL(string: citation.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                openedURL = ScopeAskURL(url: url)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(citation.title).font(.caption).multilineTextAlignment(.leading)
                                Text(URL(string: citation.url)?.host ?? citation.url).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            if let place = exchange.place { placeView(place, exchange: exchange) }
            if let note = exchange.note {
                Text(note).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let usage = exchange.usage, let cost = exchange.cost {
                Text(usage.summary + "・" + ClaudePricing.text(cost))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !exchange.sentSummary.isEmpty {
                Text(exchange.sentSummary).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// 答えで特定した場所と、撮った方向との照合
    @ViewBuilder
    private func placeView(_ place: ScopeAskPlace, exchange: ScopeAskExchange) -> some View {
        let check = ScopeAskPlaceCheck.evaluate(place: place, observerLatitude: snapshot.latitude, observerLongitude: snapshot.longitude,
                                                heading: snapshot.heading, halfFieldOfView: snapshot.halfFieldOfView)
        VStack(alignment: .leading, spacing: 4) {
            if place.hasCoordinate {
                Label("\(place.name)(確からしさ: \(place.confidence?.label ?? "低"))", systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                if let check {
                    ForEach(check.lines, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(check.isWarning ? Color.orange : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    registering = ScopeAskPlaceTarget(place: place, check: check, citations: exchange.citations)
                } label: {
                    Label("地点に登録", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
            } else {
                Label("場所は特定できませんでした" + (place.reason.isEmpty ? "" : "(\(place.reason))"), systemImage: "mappin.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var questionArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ScopeAsk.presets, id: \.self) { preset in
                        Button(preset) {
                            questionText = preset
                            send()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isThinking)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(exchanges.isEmpty ? "質問(空なら「これは何ですか？」)" : "続けて質問する", text: $questionText, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($isQuestionFocused)
                    .submitLabel(.send)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill").font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isThinking)
                .accessibilityLabel("送る")
            }
            if let reason = env.claude.blockReason {
                Label(reason.localizedDescription, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(sendingNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 送るものの説明
    private var sendingNote: String {
        let settings = env.settings.claude
        var items = ["画像(長い辺\(settings.imageEdge(isExpensive: env.network.status.isExpensive))px程度のJPEG。位置などのメタデータは含みません)", "質問"]
        if settings.sendsHeading { items.append("方角と端末の向き") }
        if settings.sendsPlace { items.append(settings.sendsCoordinates ? "おおよその地名と緯度経度" : "おおよその地名") }
        if settings.sendsTargets { items.append("撮った方向にある地点などの名前と距離") }
        var text = "送るもの: " + items.joined(separator: "、") + "(設定の「Claude API」で選べます)。"
        if settings.sendsPlace || settings.sendsTargets { text += "地名や周りの地点から、居場所が推測できます。" }
        if settings.webSearch {
            text += "Claude が必要なときに Web 検索を使います(1回の質問で\(settings.webSearchMaxUses)回まで、1回約0.01ドル。検索の言葉に現在地を入れないよう指示しています)。"
        }
        text += "続けて質問するときは、同じ画像と直近\(ScopeAsk.keptExchanges)回のやり取りを送ります。取り消しても、Claude 側で処理が進んでいた分は料金がかかることがあります(使用量には記録されません)。画像は端末に保存しません。"
        return text
    }

    private func send() {
        guard !isThinking else { return }
        isQuestionFocused = false
        notice = nil
        let question = ScopeAsk.question(questionText)
        if let reason = env.claude.blockReason {
            exchanges.append(ScopeAskExchange(question: question, error: reason.localizedDescription))
            return
        }
        let settings = env.settings.claude
        if jpeg == nil {
            jpeg = ScopeAskImage.prepare(snapshot.image, shape: shape, maxEdge: settings.imageEdge(isExpensive: env.network.status.isExpensive))
        }
        guard let jpeg else {
            exchanges.append(ScopeAskExchange(question: question, error: "画像を用意できませんでした"))
            return
        }
        let options = ScopeAskOptions(settings)
        let context = ScopeAsk.contextText(snapshot, options: options)
        let messages = ScopeAsk.messages(jpeg: jpeg, context: context, history: exchanges, question: question)
        let request = ScopeAsk.request(messages: messages, settings: settings)
        var pending = ScopeAskExchange(question: question)
        pending.sentSummary = ScopeAsk.sentSummary(ScopeAsk.sentItems(snapshot, options: options))
        let exchange = pending
        exchanges.append(exchange)
        questionText = ""
        let service = env.claude
        task = Task {
            var updated = exchange
            do {
                let result = try await ScopeAsk.ask(request) { try await service.call($0) }
                updated.usage = result.response.usage
                updated.cost = result.cost
                updated.citations = result.response.citations
                var notes: [String] = []
                if result.searchFallback { notes.append("Web 検索を使う依頼が受け付けられなかったため、検索なしで答えています") }
                if result.response.searchErrors.contains("max_uses_exceeded") { notes.append("Web 検索の上限(\(settings.webSearchMaxUses)回)に達しました") }
                if result.response.stopReason == "pause_turn" { notes.append("検索に時間がかかったため、途中までの答えです") }
                updated.note = notes.isEmpty ? nil : notes.joined(separator: "。")
                let extracted = ScopeAskPlace.extract(from: result.response.text)
                updated.place = extracted.place
                if extracted.answer.isEmpty {
                    updated.error = ClaudeError.emptyAnswer(stopReason: result.response.stopReason).localizedDescription
                } else {
                    updated.answer = extracted.answer
                }
            } catch is CancellationError {
                updated.error = "取り消しました"
            } catch {
                updated.error = error.localizedDescription
            }
            if let index = exchanges.firstIndex(where: { $0.id == exchange.id }) { exchanges[index] = updated }
            task = nil
        }
    }
}

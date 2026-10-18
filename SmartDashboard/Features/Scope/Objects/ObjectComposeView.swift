import SwiftUI

/// 文章か写真からオブジェクトを作る画面。細かさと Web 検索を選び、進み具合を見ながら待ち、確認の画面でプレビューしてから保存する。
/// 作る作業は `ObjectComposeJob`(アプリ全体で1つ)が持つので、閉じても作るのは続き、結果は「最近作ったもの」に残る
struct ObjectComposeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// 写真から作る(v0.9.30)
    @State private var usesPhotos: Bool
    @State private var removesHidden = true
    @State private var safariURL: ScopeAskURL?
    @State private var recordToDelete: ObjectComposeRecord?

    init(photos: Bool = false) {
        _usesPhotos = State(initialValue: photos)
    }

    var body: some View {
        let job = env.objectCompose
        @Bindable var bindable = job
        NavigationStack {
            Form {
                Section {
                    Picker("作り方", selection: $usesPhotos) {
                        Text("文章から").tag(false)
                        Text("写真から").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(job.isRunning)
                if usesPhotos {
                    ObjectPhotoInputSections()
                } else {
                    Section {
                        TextEditor(text: $bindable.instruction)
                            .frame(minHeight: 100)
                            .disabled(job.isRunning)
                    } header: {
                        Text("作りたいオブジェクト")
                    } footer: {
                        Text("例: 「東京タワー」「高さ30mの赤い塔」「2階建ての家」「青い半透明の球(直径10m)」。送るのはこの文だけで、今いる場所などは送りません。")
                    }
                }
                Section {
                    Picker("細かさ", selection: $bindable.detailRaw) {
                        ForEach(ObjectDetail.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    if !usesPhotos {
                        Toggle("Web で調べる(2回まで)", isOn: $bindable.webSearch)
                    }
                } footer: {
                    Text(usesPhotos ? photoFooter(job) : optionsFooter(job))
                }
                .disabled(job.isRunning)
                Section {
                    if job.isRunning {
                        progressView(job)
                    } else if usesPhotos {
                        Button("写真から作ってもらう") { start() }
                            .disabled(job.photos.isEmpty)
                    } else {
                        Button("作ってもらう") { start() }
                            .disabled(job.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let reason = env.claude.blockReason {
                        Label(reason.localizedDescription, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    if let errorText = job.errorText, !job.isRunning {
                        Label(errorText, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text("画面を閉じても、作るのは続きます。作っている間とできたあとは、オブジェクトの一覧の上に帯が出て、タップでこの画面に戻れます。")
                }
                if let record = job.recents.entry(job.viewingID) { resultSections(record) }
                recentsSection(job)
            }
            .keyboardDismissable()
            .navigationTitle("文章から作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 閉じても、作るのはやめない
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(item: $safariURL) { ScopeAskSafariView(url: $0.url).ignoresSafeArea() }
            .confirmationDialog("この結果を捨てますか?", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
                                titleVisibility: .visible) {
                Button("捨てる", role: .destructive) {
                    if let recordToDelete { job.discard(recordToDelete.id) }
                    recordToDelete = nil
                }
            } message: {
                Text("最近作ったものの一覧からも消えます。")
            }
            .onAppear { job.isShowing = true }
            .onDisappear { job.isShowing = false }
            .onChange(of: job.viewingID) { _, _ in removesHidden = true }
        }
    }

    private func photoFooter(_ job: ObjectComposeJob) -> String {
        let sizes = job.photos.map { ObjectPhotoImage.sentSize($0.image, shape: $0.shape) }
        let tokens = sizes.reduce(0) { $0 + ScopeAskImage.estimatedTokens(width: $1.width, height: $1.height) }
        return "形は\(job.detail.maxShapes)個まで。料金の目安は1回あたり約\(ClaudePricing.text(job.photoEstimatedCost))"
            + "(写真\(job.photos.count)枚の画像で約\(tokens)トークンを含む)。細かいほど時間がかかります。"
    }

    private func optionsFooter(_ job: ObjectComposeJob) -> String {
        let detail = job.detail
        let cost = ClaudePricing.text(ObjectGenerator.estimatedCost(detail: detail, webSearch: job.webSearch))
        var text = "形は\(detail.maxShapes)個まで。料金の目安は1回あたり約\(cost)"
        if job.webSearch { text += "(検索1回 約0.01ドルを含む)" }
        text += "。細かいほど時間がかかります(とても細かいときは数分)。Web で調べると、実在の建物などの高さ・各部の寸法・色を調べてから作り、調べた寸法の一覧を確認の画面に出します。"
        return text
    }

    private func progressView(_ job: ObjectComposeJob) -> some View {
        let progress = job.progress
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                Text(progress.stage).font(.subheadline.weight(.semibold))
                Spacer()
                Button("中止", role: .destructive) { job.cancel() }.buttonStyle(.bordered)
            }
            if let query = progress.query {
                Text("検索: \(query)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(Int(context.date.timeIntervalSince(progress.startedAt)))秒・受け取った文字 \(progress.characters)・形 \(progress.shapes) / \(job.detail.maxShapes)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultSections(_ record: ObjectComposeRecord) -> some View {
        let outcome = record.outcome
        if let photoCount = record.photoCount {
            Section {
                LabeledContent("写真", value: "\(photoCount)枚")
                LabeledContent("寸法の指定", value: record.inputDimensions ?? "なし(写真から見積もり)")
                if record.instruction != "写真から作成" {
                    Text(record.instruction).font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("写真から作ったもの")
            }
        }
        if let generated = outcome.object {
            let object = removesHidden ? ObjectGeometry.removingShapes(outcome.hiddenShapes, from: generated) : generated
            ObjectConfirmSection(object: object)
            if !outcome.dimensions.isEmpty {
                Section {
                    ForEach(outcome.dimensions) { item in
                        LabeledContent(item.label, value: item.value)
                    }
                } header: {
                    Text(record.photoCount == nil ? "調べた寸法" : "使った寸法(見積もりを含む)")
                } footer: {
                    Text(record.photoCount == nil ? "Web で調べた結果を Claude がまとめた一覧です。この値に合わせて作っています。"
                         : "指定した寸法と、写真から見積もった寸法(「見積もり」と付いたもの)です。この値に合わせて作っています。")
                }
            }
            Section {
                if !outcome.hiddenShapes.isEmpty {
                    Toggle("隠れた形を除く(\(outcome.hiddenShapes.count)個)", isOn: $removesHidden)
                }
                LabeledContent("形の数", value: "\(object.shapes.count) / \(outcome.detail.maxShapes)")
                LabeledContent("面の数(カメラ表示で近くのとき)", value: "\(ObjectGeometry.faces(of: object).count)")
                LabeledContent("料金(概算)", value: ClaudePricing.text(outcome.cost))
                LabeledContent("Web 検索", value: outcome.searchFallback ? "使えませんでした" : "\(outcome.searches)回")
                if outcome.searchFallback {
                    Text("このモデルか組織では Web 検索を使えなかったため、検索なしで作りました。")
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !outcome.searchErrors.isEmpty {
                    Text("検索でエラーがありました(\(outcome.searchErrors.joined(separator: "、")))。分かる範囲で作っています。")
                        .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let savedAt = record.savedAt {
                    Label("保存しました(\(ClaudeRecentList.dateText(savedAt)))", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                Button(record.savedAt == nil ? "保存する" : "もう一度保存する(別のオブジェクトとして)") {
                    env.objects.save(object)
                    env.objectCompose.markSaved(record.id)
                    dismiss()
                }
                resultButtons(record)
            } header: {
                Text("結果(\(ClaudeRecentList.dateText(record.createdAt)))")
            } footer: {
                Text((outcome.hiddenShapes.isEmpty ? "" : "隠れた形は、ほかの形の中に完全に入っていて、外から見えない形です。")
                     + "呼び出し\(outcome.attempts)回: " + outcome.usage.summary)
            }
            if !outcome.citations.isEmpty {
                Section("参考にしたページ") {
                    ForEach(outcome.citations) { citation in
                        Button {
                            if let url = URL(string: citation.url) { safariURL = ScopeAskURL(url: url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(citation.title).font(.subheadline).foregroundStyle(Color.primary).lineLimit(2)
                                Text(citation.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        } else {
            Section("形式の誤りが残りました(\(outcome.issues.count)件)") {
                ForEach(outcome.issues.prefix(10)) { issue in
                    Text("\(issue.path): \(issue.message)").font(.footnote).foregroundStyle(.red)
                }
                LabeledContent("料金(概算)", value: ClaudePricing.text(outcome.cost))
                resultButtons(record)
            }
        }
    }

    /// 作り直す・捨てる
    @ViewBuilder
    private func resultButtons(_ record: ObjectComposeRecord) -> some View {
        if record.photoCount != nil {
            // 写真は保存していないので、今選んでいる写真で作り直す
            Button("今の写真と寸法で作り直す") {
                env.objectCompose.restoreInput(from: record)
                usesPhotos = true
                start()
            }
            .disabled(env.objectCompose.isRunning || env.objectCompose.photos.isEmpty)
        } else {
            Button("同じ文で作り直す") {
                env.objectCompose.restoreInput(from: record)
                usesPhotos = false
                start()
            }
            .disabled(env.objectCompose.isRunning)
        }
        Button("捨てる", role: .destructive) { recordToDelete = record }
    }

    private func recentsSection(_ job: ObjectComposeJob) -> some View {
        Section {
            if job.recents.entries.isEmpty {
                Text("まだありません").foregroundStyle(.secondary)
            }
            ForEach(job.recents.entries) { record in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        job.open(record.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.instruction).font(.subheadline).foregroundStyle(Color.primary).lineLimit(2)
                            Text(recentCaption(record)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    if record.id == job.viewingID {
                        Image(systemName: "eye").foregroundStyle(Color.accentColor)
                    }
                    Button(role: .destructive) {
                        recordToDelete = record
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("一覧から消す")
                }
            }
        } header: {
            Text("最近作ったもの(\(ClaudeRecentList.limit)件まで)")
        } footer: {
            Text("作った結果は、捨てるか一覧から消すまで残ります。タップすると確認の画面を開き直して、保存・作り直しができます。")
        }
    }

    private func recentCaption(_ record: ObjectComposeRecord) -> String {
        var parts = [ClaudeRecentList.dateText(record.createdAt), record.objectDetail.label, ClaudePricing.text(record.cost)]
        if let photoCount = record.photoCount { parts.insert("写真\(photoCount)枚", at: 1) }
        if !record.issues.isEmpty { parts.append("誤りあり") }
        parts.append(record.savedAt == nil ? "未保存" : "保存済み")
        return parts.joined(separator: "・")
    }

    private func start() {
        let job = env.objectCompose
        if let reason = env.claude.blockReason {
            job.reportBlocked(reason.localizedDescription)
            return
        }
        let settings = env.settings.claude
        let service = env.claude
        if usesPhotos {
            job.startPhotos(model: settings.model, thinking: settings.thinkingForTools) { request, onEvent in
                try await service.callStreaming(request, onEvent: onEvent)
            }
            return
        }
        job.start(model: settings.model, thinking: settings.thinkingForTools) { request, onEvent in
            try await service.callStreaming(request, onEvent: onEvent)
        }
    }
}

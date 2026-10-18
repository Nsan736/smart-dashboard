import SwiftUI

/// スクリプト型のツールの画面。キャンバス(1枚の Canvas)と入力の部品。スクリプトは専用のスレッドで動き、画面の操作は止まらない。
struct ScriptToolView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dismiss) private var dismiss
    let tool: CustomTool
    /// 保存する前のプレビュー(保存領域を使わない)
    var isPreview = false
    @State private var session: ScriptSession?
    @State private var showsLog = false
    @State private var isTouching = false

    var body: some View {
        if env.settings.scriptToolsStopped {
            ContentUnavailableView("スクリプト型のツールを止めています", systemImage: "pause.circle",
                                   description: Text("設定の「小ツール」で、止める切り替えをオフにすると動かせます。"))
        } else if !isPreview, env.settings.disabledScriptTools.contains(tool.id) {
            VStack(spacing: 12) {
                ContentUnavailableView("このツールは無効にしています", systemImage: "nosign",
                                       description: Text("前回、このツールの実行中にアプリが止まったため、無効にしました。"))
                Button("有効にして動かす") { env.settings.disabledScriptTools.removeAll { $0 == tool.id } }
                    .buttonStyle(.borderedProminent)
            }
        } else if let content = tool.script {
            runner(content)
        } else {
            ContentUnavailableView("スクリプトがありません", systemImage: "exclamationmark.triangle")
        }
    }

    private func runner(_ content: ScriptToolContent) -> some View {
        VStack(spacing: 0) {
            if content.controlsAtTop { controls }
            canvasArea(content)
            if !content.controlsAtTop { controls }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showsLog = true
                    } label: {
                        Label("ログ(\(session?.logs.count ?? 0))", systemImage: "text.alignleft")
                    }
                    Button {
                        if let session, let image = session.renderCanvas(width: 0), let data = UIImage(cgImage: image).pngData() {
                            let url = FileManager.default.temporaryDirectory.appendingPathComponent(tool.id + ".png")
                            if (try? data.write(to: url, options: .atomic)) != nil { session.exportedFile = url }
                        }
                    } label: {
                        Label("今の画面を PNG で書き出す", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        session?.restart()
                    } label: {
                        Label("最初から動かす", systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Label("スクリプト", systemImage: "curlybraces")
                }
            }
        }
        .onDisappear { session?.close() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session?.resume() } else { session?.pause() }
        }
        .sheet(isPresented: $showsLog) {
            ScriptLogView(logs: session?.logs ?? [])
        }
        .sheet(isPresented: Binding(get: { session?.exportedFile != nil }, set: { if !$0 { session?.exportedFile = nil } })) {
            if let url = session?.exportedFile { ScriptShareSheet(items: [url]) }
        }
    }

    // MARK: - キャンバス

    private func canvasArea(_ content: ScriptToolContent) -> some View {
        GeometryReader { geometry in
            let size = Self.canvasSize(available: geometry.size, aspect: content.aspect)
            ZStack {
                Color(.systemBackground)
                if let session {
                    ScriptCanvasView(ops: session.ops, images: session.images)
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    session.touch(isTouching ? .move : .down, at: value.location)
                                    isTouching = true
                                }
                                .onEnded { value in
                                    session.touch(.up, at: value.location)
                                    isTouching = false
                                }
                        )
                    statusOverlay(session)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { prepare(size: size) }
            .onChange(of: size) { _, new in prepare(size: new) }
            .onChange(of: colorScheme) { _, _ in prepare(size: size) }
        }
    }

    /// 空いている場所に、縦横比を保って収めた大きさ
    static func canvasSize(available: CGSize, aspect: Double?) -> CGSize {
        guard let aspect, aspect > 0, available.width > 0, available.height > 0 else { return available }
        let width = min(available.width, available.height * aspect)
        return CGSize(width: width.rounded(.down), height: (width / aspect).rounded(.down))
    }

    private func prepare(size: CGSize) {
        guard size.width > 1, size.height > 1, let content = tool.script else { return }
        let screen = ScriptScreen(width: Double(size.width), height: Double(size.height), dark: colorScheme == .dark, scale: Double(displayScale))
        if let session, session.status != .closed {
            session.update(screen: screen)
        } else {
            // 初めて出たとき、またはタブを切り替えて閉じたあとに、もう一度出たとき
            let created = ScriptSession(tool: tool, content: content, isPreview: isPreview, runGuard: env.tools.runGuard,
                                        storageDirectory: env.tools.scriptStorageDirectory)
            session = created
            created.start(screen: screen)
        }
    }

    @ViewBuilder
    private func statusOverlay(_ session: ScriptSession) -> some View {
        if session.isUnresponsive {
            VStack(spacing: 10) {
                Label("応答なし", systemImage: "hourglass")
                    .font(.title3.weight(.bold))
                Text("スクリプトが\(Int(ScriptSession.unresponsiveAfter))秒以上戻りません。閉じると、このツールの実行を打ち切ります。"
                     + (session.timeLimitAvailable ? "(\(Int(ScriptRuntime.defaultTimeLimit))秒たつと自動で止めます)" : ""))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("閉じる") {
                    session.close()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        } else if case .failed(let message) = session.status {
            VStack(spacing: 10) {
                Label("止まりました", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("ログ") { showsLog = true }
                        .buttonStyle(.bordered)
                    Button("最初から") { session.restart() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
        if let message = session.exportMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .onTapGesture { session.exportMessage = nil }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - 入力の部品

    @ViewBuilder
    private var controls: some View {
        if let session, !session.controls.isEmpty {
            ScriptControlsPanel(controls: session.controls) { id, value in session.input(id, value: value) }
        }
    }
}

/// 入力の部品を並べる(最小の画面幅でも収まるよう、1行に1つ)
struct ScriptControlsPanel: View {
    let controls: [ScriptControlSpec]
    let onChange: (String, ScriptControlValue) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(controls) { control in row(control) }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private func row(_ control: ScriptControlSpec) -> some View {
        switch control.kind {
        case .slider:
            let value: Double = { if case .number(let v) = control.value { return v } else { return control.min } }()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(control.label).font(.subheadline)
                    Spacer()
                    Text(Self.number(value)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { value }, set: { onChange(control.id, .number(control.snapped($0))) }),
                       in: control.min...control.max)
            }
        case .button:
            Button(control.label) { onChange(control.id, .bool(true)) }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        case .toggle:
            let isOn: Bool = { if case .bool(let v) = control.value { return v } else { return false } }()
            Toggle(control.label, isOn: Binding(get: { isOn }, set: { onChange(control.id, .bool($0)) }))
        case .text:
            let text: String = { if case .text(let v) = control.value { return v } else { return "" } }()
            TextField(control.label, text: Binding(get: { text }, set: { onChange(control.id, .text(String($0.prefix(200)))) }))
                .textFieldStyle(.roundedBorder)
        case .choice:
            let selected: String = { if case .text(let v) = control.value { return v } else { return control.options.first ?? "" } }()
            let binding = Binding(get: { selected }, set: { onChange(control.id, .text($0)) })
            if control.options.count <= 4 {
                Picker(control.label, selection: binding) {
                    ForEach(control.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            } else {
                Picker(control.label, selection: binding) {
                    ForEach(control.options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e9 ? String(Int(value)) : String(format: "%.2f", value)
    }
}

/// console.log の直近の行
struct ScriptLogView: View {
    @Environment(\.dismiss) private var dismiss
    let logs: [ScriptLogLine]

    var body: some View {
        NavigationStack {
            List {
                if logs.isEmpty {
                    Text("ログはありません(スクリプトの console.log で書けます)").foregroundStyle(.secondary)
                }
                ForEach(logs.reversed()) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.time, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(line.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(line.level == 2 ? Color.red : line.level == 1 ? Color.orange : Color.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle("ログ(新しい順)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("コピー") {
                        UIPasteboard.general.string = logs.map(\.text).joined(separator: "\n")
                    }
                    .disabled(logs.isEmpty)
                }
            }
        }
    }
}

/// 前回、スクリプト型のツールの実行中にアプリが止まったときの画面(起動したときに出す)。そのツールは開かずに、どうするかを選んでもらう。
struct ScriptCrashRecoveryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let record: ScriptRunRecord
    @State private var isRetrying = false

    var body: some View {
        NavigationStack {
            Group {
                if isRetrying, let tool = env.tools.customTool(id: record.toolID) {
                    ScriptToolView(tool: tool)
                } else {
                    Form {
                        Section {
                            Label("前回このツールの実行中に止まりました", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("「\(record.name)」" + (record.isPreview ? "(保存する前のプレビュー)" : "")
                                 + "を動かしている間に、アプリが終了しました(固まって終了した、メモリを使いすぎた、など)。このツールは開いていません。")
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !record.isPreview, env.tools.customTool(id: record.toolID) != nil {
                            Section {
                                Button("もう一度試す") {
                                    env.settings.disabledScriptTools.removeAll { $0 == record.toolID }
                                    isRetrying = true
                                }
                                Button("無効にする") {
                                    if !env.settings.disabledScriptTools.contains(record.toolID) {
                                        env.settings.disabledScriptTools.append(record.toolID)
                                    }
                                    close()
                                }
                                Button("削除する", role: .destructive) {
                                    env.tools.delete(customID: record.toolID)
                                    close()
                                }
                            } footer: {
                                Text("無効にしたツールは、一覧には残り、開いたときに有効に戻せます。設定の「小ツール」で、スクリプト型のツールをすべて止めることもできます。")
                            }
                        }
                    }
                }
            }
            .navigationTitle(isRetrying ? record.name : "小ツール")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close() } }
            }
        }
    }

    private func close() {
        env.tools.resolveCrashedScript()
        dismiss()
    }
}

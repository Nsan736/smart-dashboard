import SwiftUI

/// 編集の履歴(元に戻す・やり直し)。純粋なロジックとしてテストする
struct ObjectEditHistory: Equatable {
    static let limit = 50

    private(set) var past: [ScopeObject] = []
    private(set) var future: [ScopeObject] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// 変える前の状態を記録する(やり直しの記録は消す)
    mutating func record(_ current: ScopeObject) {
        if past.last == current { return }
        past.append(current)
        if past.count > Self.limit { past.removeFirst(past.count - Self.limit) }
        future = []
    }

    mutating func undo(_ current: ScopeObject) -> ScopeObject? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        return previous
    }

    mutating func redo(_ current: ScopeObject) -> ScopeObject? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        return next
    }
}

/// 形の一覧の操作(追加・複製・削除・並べ替え)。純粋なロジックとしてテストする
enum ObjectShapeEditing {
    static func add(_ kind: ObjectShapeKind, to object: inout ScopeObject) -> UUID? {
        guard object.shapes.count < ScopeObject.maxShapes else { return nil }
        // 全体の色(最後の形の色)を引き継ぐ。はじめは赤、不透明度0.4
        let last = object.shapes.last
        var shape = ObjectShape.make(kind, color: last?.color ?? ObjectShape.defaultColor, opacity: last?.opacity ?? ObjectShape.defaultOpacity)
        // 前の形の上に積む
        if let last { shape.z = last.z + last.height }
        object.shapes.append(shape)
        return shape.id
    }

    static func duplicate(_ id: UUID, in object: inout ScopeObject) -> UUID? {
        guard object.shapes.count < ScopeObject.maxShapes, let index = object.shapes.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = object.shapes[index]
        copy.id = UUID()
        copy.x += 1
        object.shapes.insert(copy, at: index + 1)
        return copy.id
    }

    static func delete(_ id: UUID, in object: inout ScopeObject) -> UUID? {
        guard let index = object.shapes.firstIndex(where: { $0.id == id }) else { return nil }
        object.shapes.remove(at: index)
        guard !object.shapes.isEmpty else { return nil }
        return object.shapes[min(index, object.shapes.count - 1)].id
    }

    static func move(_ id: UUID, by offset: Int, in object: inout ScopeObject) {
        guard let index = object.shapes.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard object.shapes.indices.contains(target) else { return }
        object.shapes.swapAt(index, target)
    }

    /// 全体を、上から見て時計回りに degrees 度回す(原点のまわり)。正面(+y)の向きを直すのに使う。
    /// 位置を回し、形の向き(yaw)に同じ角度を足す。ヨーは一番外側の回転なので、形の傾きはそのまま保たれる
    static func rotateAll(by degrees: Double, in object: inout ScopeObject) {
        func clean(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }
        for index in object.shapes.indices {
            var shape = object.shapes[index]
            let p = ObjectGeometry.rotate(ObjectPoint(shape.x, shape.y, 0), yaw: degrees, pitch: 0, roll: 0)
            shape.x = clean(p.x)
            shape.y = clean(p.y)
            shape.yaw = clean(remainder(shape.yaw + degrees, 360))
            object.shapes[index] = shape
        }
    }

    /// 全部の形の色と不透明度をそろえる
    static func applyToAll(color: String?, opacity: Double?, in object: inout ScopeObject) {
        for index in object.shapes.indices {
            if let color { object.shapes[index].color = color }
            if let opacity { object.shapes[index].opacity = opacity }
        }
    }
}

/// 数値の入力欄と、名前を左右にドラッグして変える調整。ドラッグを始めたときと、入力を確定したときに onBegin を呼ぶ(元に戻すの記録)。
struct NumberScrubField: View {
    let label: String
    @Binding var value: Double
    var step: Double
    var range: ClosedRange<Double>
    var unit: String
    var onBegin: () -> Void
    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: "arrow.left.and.right")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .foregroundStyle(dragStart == nil ? Color.primary : Color.accentColor)
                .frame(minWidth: 70, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                    if dragStart == nil {
                        onBegin()
                        dragStart = value
                    }
                    let raw = (dragStart ?? value) + Double(drag.translation.width) / 8 * step
                    value = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                }.onEnded { _ in dragStart = nil })
            Spacer(minLength: 4)
            TextField(label, value: Binding(get: { value }, set: { new in
                onBegin()
                value = min(max(new, range.lowerBound), range.upperBound)
            }), format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
            Text(unit).font(.footnote).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .leading)
        }
    }
}

/// オブジェクトを作る・編集する画面。上にプレビュー(指で回す・拡大)、下に形の一覧と、選んだ形の設定。
struct ObjectEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScopeObject
    @State private var history = ObjectEditHistory()
    @State private var selectedID: UUID?
    private let isNew: Bool

    init(object: ScopeObject?) {
        let initial = object ?? ScopeObject(name: "新しいオブジェクト", shapes: [ObjectShape.make(.box)])
        _draft = State(initialValue: initial)
        _selectedID = State(initialValue: initial.shapes.first?.id)
        isNew = object == nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ObjectPreviewView(object: draft, selectedID: selectedID)
                    .frame(height: 230)
                Form {
                    Section {
                        TextField("名前", text: Binding(get: { draft.name }, set: { draft.name = String($0.prefix(40)) }))
                    }
                    shapeListSection
                    if let index = selectedIndex { shapeSection(index) }
                    overallSection
                }
                .keyboardDismissable()
            }
            .navigationTitle(isNew ? "オブジェクトを作る" : "オブジェクトを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        env.objects.save(draft)
                        dismiss()
                    }
                    .disabled(draft.shapes.isEmpty || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { undo() } label: { Label("元に戻す", systemImage: "arrow.uturn.backward") }
                        .disabled(!history.canUndo)
                    Button { redo() } label: { Label("やり直し", systemImage: "arrow.uturn.forward") }
                        .disabled(!history.canRedo)
                    Spacer()
                    Text("\(draft.shapes.count) / \(ScopeObject.maxShapes)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var selectedIndex: Int? {
        draft.shapes.firstIndex { $0.id == selectedID }
    }

    private func change(_ body: (inout ScopeObject) -> Void) {
        history.record(draft)
        body(&draft)
    }

    private func undo() {
        if let previous = history.undo(draft) {
            draft = previous
            if selectedIndex == nil { selectedID = draft.shapes.first?.id }
        }
    }

    private func redo() {
        if let next = history.redo(draft) {
            draft = next
            if selectedIndex == nil { selectedID = draft.shapes.first?.id }
        }
    }

    private var shapeListSection: some View {
        Section {
            ForEach(draft.shapes) { shape in
                Button {
                    selectedID = shape.id
                } label: {
                    HStack {
                        Image(systemName: shape.kind.symbol).foregroundStyle(ObjectColor.color(shape.color))
                        Text(shape.kind.label).foregroundStyle(Color.primary)
                        Text(String(format: "%.1f×%.1f×%.1fm", shape.width, shape.depth, shape.height))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        if shape.id == selectedID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
            }
            ViewThatFits {
                HStack { shapeButtons }
                VStack(alignment: .leading, spacing: 8) { shapeButtons }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("形(上から順に描きます)")
        }
    }

    @ViewBuilder
    private var shapeButtons: some View {
        Menu {
            ForEach(ObjectShapeKind.allCases) { kind in
                Button { change { selectedID = ObjectShapeEditing.add(kind, to: &$0) ?? selectedID } } label: {
                    Label(kind.label, systemImage: kind.symbol)
                }
            }
        } label: {
            Label("追加", systemImage: "plus")
        }
        .disabled(draft.shapes.count >= ScopeObject.maxShapes)
        Button { if let id = selectedID { change { selectedID = ObjectShapeEditing.duplicate(id, in: &$0) ?? selectedID } } } label: {
            Label("複製", systemImage: "plus.square.on.square")
        }
        .disabled(selectedID == nil)
        Button(role: .destructive) { if let id = selectedID { change { selectedID = ObjectShapeEditing.delete(id, in: &$0) } } } label: {
            Label("削除", systemImage: "trash")
        }
        .disabled(selectedID == nil)
        Button { if let id = selectedID { change { ObjectShapeEditing.move(id, by: -1, in: &$0) } } } label: {
            Label("上へ", systemImage: "arrow.up")
        }
        .disabled(selectedIndex == 0 || selectedID == nil)
        Button { if let id = selectedID { change { ObjectShapeEditing.move(id, by: 1, in: &$0) } } } label: {
            Label("下へ", systemImage: "arrow.down")
        }
        .disabled(selectedIndex == nil || selectedIndex == draft.shapes.count - 1)
    }

    private func value(_ index: Int, _ key: WritableKeyPath<ObjectShape, Double>) -> Binding<Double> {
        Binding(get: { draft.shapes.indices.contains(index) ? draft.shapes[index][keyPath: key] : 0 },
                set: { if draft.shapes.indices.contains(index) { draft.shapes[index][keyPath: key] = $0 } })
    }

    private func field(_ label: String, _ index: Int, _ key: WritableKeyPath<ObjectShape, Double>, step: Double,
                       range: ClosedRange<Double>, unit: String) -> some View {
        NumberScrubField(label: label, value: value(index, key), step: step, range: range, unit: unit) { history.record(draft) }
    }

    @ViewBuilder
    private func shapeSection(_ index: Int) -> some View {
        let shape = draft.shapes[index]
        Section {
            Picker("形", selection: Binding(get: { shape.kind }, set: { kind in change { $0.shapes[index].kind = kind } })) {
                ForEach(ObjectShapeKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            ColorPicker("色", selection: Binding(get: { ObjectColor.color(shape.color) },
                                                set: { color in change { $0.shapes[index].color = ObjectColor.hex(color) } }),
                        supportsOpacity: false)
            field("不透明度", index, \.opacity, step: 0.05, range: 0.05...1, unit: "")
        } header: {
            Text("選んだ形")
        }
        Section {
            field("幅", index, \.width, step: 0.1, range: ObjectCodec.sizeRange, unit: "m")
            if shape.kind != .plane { field("奥行き", index, \.depth, step: 0.1, range: ObjectCodec.sizeRange, unit: "m") }
            field("高さ", index, \.height, step: 0.1, range: ObjectCodec.sizeRange, unit: "m")
        } header: {
            Text("大きさ")
        } footer: {
            Text("名前を左右にドラッグすると、少しずつ変えられます。")
        }
        Section("位置(形の底面の中心)") {
            field("左右", index, \.x, step: 0.1, range: ObjectCodec.positionRange, unit: "m")
            field("前後", index, \.y, step: 0.1, range: ObjectCodec.positionRange, unit: "m")
            field("上下", index, \.z, step: 0.1, range: ObjectCodec.positionRange, unit: "m")
        }
        Section("回転") {
            field("向き", index, \.yaw, step: 1, range: -360...360, unit: "°")
            field("前後の傾き", index, \.pitch, step: 1, range: -360...360, unit: "°")
            field("左右の傾き", index, \.roll, step: 1, range: -360...360, unit: "°")
        }
    }

    private var overallSection: some View {
        let first = draft.shapes.first
        return Section {
            ColorPicker("全部の色", selection: Binding(get: { ObjectColor.color(first?.color ?? ObjectShape.defaultColor) },
                                                    set: { color in change { ObjectShapeEditing.applyToAll(color: ObjectColor.hex(color), opacity: nil, in: &$0) } }),
                        supportsOpacity: false)
            HStack {
                Text("全部の不透明度")
                Slider(value: Binding(get: { first?.opacity ?? ObjectShape.defaultOpacity },
                                      set: { new in ObjectShapeEditing.applyToAll(color: nil, opacity: (new * 20).rounded() / 20, in: &draft) }),
                       in: 0.05...1, onEditingChanged: { editing in if editing { history.record(draft) } })
            }
            ViewThatFits {
                HStack { rotateButtons }
                VStack(alignment: .leading, spacing: 8) { rotateButtons }
            }
            .buttonStyle(.bordered)
        } header: {
            Text("全体")
        } footer: {
            Text("はじめは赤、不透明度0.4(半透明)です。カメラ表示では、半透明の面は奥が透けて見えます。"
                 + "プレビューの青い印の側が正面(前、+y)で、地図に置いたときの「向き」の方角を向きます。正面がずれているときは、全体を回してください。")
        }
    }

    @ViewBuilder
    private var rotateButtons: some View {
        Button { change { ObjectShapeEditing.rotateAll(by: -90, in: &$0) } } label: {
            Label("全体を左に90°", systemImage: "rotate.left")
        }
        Button { change { ObjectShapeEditing.rotateAll(by: 90, in: &$0) } } label: {
            Label("全体を右に90°", systemImage: "rotate.right")
        }
    }
}

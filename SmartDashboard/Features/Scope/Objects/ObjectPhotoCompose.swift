import ImageIO
import PhotosUI
import SwiftUI
import UIKit

/// 写真からオブジェクトを作るときの写真の扱い。送る画像は CGImageDestination で一から作るので、
/// もとの写真の位置情報(Exif の GPS など)や撮影日時は含まれない
enum ObjectPhotoImage {
    /// 送る画像の長い辺(px)
    static let maxEdge = 1024
    static let maxPhotos = 3

    /// 写真のデータを、向きを直して長い辺 maxEdge 以下の画像にする(メタデータは持たない)
    static func load(_ data: Data, maxEdge: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 送る JPEG(囲んだ部分。外側は暗くする。長い辺 maxEdge)
    static func prepare(_ image: CGImage, shape: [CGPoint]?, maxEdge: Int = maxEdge) -> Data? {
        ScopeAskImage.prepare(image, shape: shape, maxEdge: maxEdge)
    }

    /// 送る画像の大きさ(料金の目安に使う)
    static func sentSize(_ image: CGImage, shape: [CGPoint]?, maxEdge: Int = maxEdge) -> (width: Int, height: Int) {
        let size = CGSize(width: image.width, height: image.height)
        let bounds = shape.flatMap { ScopeAskImage.bounds(of: $0, imageSize: size) } ?? CGRect(origin: .zero, size: size)
        return ScopeAskImage.fittedSize(width: Int(bounds.width), height: Int(bounds.height), maxEdge: maxEdge)
    }

    /// 画像のデータに位置情報(GPS)が入っているか
    static func hasLocation(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    /// 寸法の欄(m)から、Claude に送る文(「高さ 10m、幅 5m」)。数として読めない欄は入れない
    static func dimensionsText(height: String, width: String, depth: String) -> String {
        func value(_ text: String) -> Double? {
            let normalized = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
            guard let number = Double(normalized), number > 0 else { return nil }
            return number
        }
        var parts: [String] = []
        for (name, text) in [("高さ", height), ("幅", width), ("奥行き", depth)] {
            if let number = value(text) {
                let formatted = number == number.rounded() ? String(Int(number)) : String(format: "%.2f", number)
                parts.append("\(name) \(formatted)m")
            }
        }
        return parts.joined(separator: "、")
    }
}

/// 選んだ写真(囲んだ部分)。作る画面を閉じても残す(端末には保存しない)
struct ObjectPhotoDraft: Identifiable {
    let id = UUID()
    var image: CGImage
    /// 囲んだ形(画像のピクセル)。nil なら全体
    var shape: [CGPoint]?
}

/// 写真を指で囲んで切り取る
struct PhotoCropView: View {
    @Environment(\.dismiss) private var dismiss
    let image: CGImage
    let onDone: ([CGPoint]?) -> Void
    @State private var shape: [CGPoint]?
    @State private var stroke: [CGPoint] = []

    init(image: CGImage, shape: [CGPoint]?, onDone: @escaping ([CGPoint]?) -> Void) {
        self.image = image
        self.onDone = onDone
        _shape = State(initialValue: shape)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let imageSize = CGSize(width: image.width, height: image.height)
                let frame = ScopeAskView.fittedFrame(imageSize: imageSize, in: geometry.size)
                let scale = frame.width / max(imageSize.width, 1)
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(decorative: image, scale: 1)
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
                                if let last = stroke.last, hypot(last.x - clamped.x, last.y - clamped.y) * scale < 3 { return }
                                stroke.append(clamped)
                            }
                            .onEnded { _ in
                                let drawn = stroke
                                stroke = []
                                if ScopeAskImage.bounds(of: drawn, imageSize: imageSize) != nil { shape = drawn }
                            }
                    )
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("囲んで切り取る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        onDone(shape)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("囲みを消す(写真全体)") { shape = nil }
                        .disabled(shape == nil)
                }
            }
        }
    }
}

/// カメラ表示で、オブジェクトの写真を撮り足している間に出す帯(v0.9.31)
struct ObjectPhotoCollectingBanner: View {
    let count: Int
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cube").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("オブジェクトの写真 \(count)/\(ObjectPhotoImage.maxPhotos)枚").font(.subheadline.weight(.semibold))
                Text("「撮って聞く」で撮って囲み、「オブジェクトの写真に足す」").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("作る画面へ", action: onOpen).buttonStyle(.borderedProminent).font(.caption)
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("撮り足すのをやめる")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 作る画面の、写真・寸法・説明の欄
struct ObjectPhotoInputSections: View {
    @Environment(AppEnvironment.self) private var env
    /// スコープのカメラ表示で撮る(撮って囲む操作)。作る画面を閉じて、カメラ表示へ
    let onCameraCapture: () -> Void
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var cropping: ObjectPhotoDraft?
    @State private var loadError: String?
    @FocusState private var isEditingNumber: Bool

    var body: some View {
        let job = env.objectCompose
        @Bindable var bindable = job
        Section {
            if job.photos.isEmpty {
                Text("違う角度から撮った写真を1〜\(ObjectPhotoImage.maxPhotos)枚選んでください").foregroundStyle(.secondary)
            }
            ForEach(job.photos) { photo in
                HStack(spacing: 10) {
                    Image(decorative: photo.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(photo.shape == nil ? "写真全体" : "囲んだ部分").font(.subheadline)
                    Spacer()
                    Button("囲む") { cropping = photo }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) {
                        job.removePhoto(photo.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("写真を外す")
                }
            }
            if job.photos.count < ObjectPhotoImage.maxPhotos {
                ViewThatFits {
                    HStack { addButtons(job) }
                    VStack(alignment: .leading, spacing: 8) { addButtons(job) }
                }
                .buttonStyle(.bordered)
            }
            if let loadError {
                Text(loadError).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("写真(\(job.photos.count) / \(ObjectPhotoImage.maxPhotos))")
        } footer: {
            Text("「カメラ表示で撮る」で、スコープのカメラ表示に移ります。「撮って聞く」で撮って指で囲み、「オブジェクトを作る」を押すと、この画面に戻ります(別の角度から撮り足すときも同じ)。送るのは、写真(長い辺\(ObjectPhotoImage.maxEdge)pxに縮めたもの。位置情報などは消します)と、下の寸法・説明だけです。今いる場所は送りません。写真は端末に保存しません。")
        }
        Section {
            HStack {
                Text("高さ")
                TextField("例 10", text: $bindable.photoHeight).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($isEditingNumber)
                Text("m")
            }
            HStack {
                Text("幅")
                TextField("例 5", text: $bindable.photoWidth).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($isEditingNumber)
                Text("m")
            }
            HStack {
                Text("奥行き")
                TextField("例 4", text: $bindable.photoDepth).keyboardType(.decimalPad).multilineTextAlignment(.trailing).focused($isEditingNumber)
                Text("m")
            }
            KeyboardCloseButton(isFocused: isEditingNumber)
            TextEditor(text: $bindable.photoNote)
                .frame(minHeight: 70)
        } header: {
            Text("分かっている寸法と説明(どちらも任意)")
        } footer: {
            Text("寸法がなければ、写っているもの(人・車・ドアなど)から見積もり、見積もった寸法を確認の画面に出します。説明の例: 「白い外壁の2階建ての家、屋根は濃い灰色」")
        }
        .disabled(job.isRunning)
        .sheet(item: $cropping) { photo in
            PhotoCropView(image: photo.image, shape: photo.shape) { shape in job.setShape(shape, for: photo.id) }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = ObjectPhotoImage.load(data) {
                        job.addPhoto(image)
                    } else {
                        loadError = "読み込めない写真がありました"
                    }
                }
                pickerItems = []
            }
        }
    }

    @ViewBuilder
    private func addButtons(_ job: ObjectComposeJob) -> some View {
        Button {
            loadError = nil
            job.isCollectingPhotos = true
            onCameraCapture()
        } label: {
            Label(job.photos.isEmpty ? "カメラ表示で撮る" : "カメラ表示で撮り足す", systemImage: "camera.viewfinder")
        }
        PhotosPicker(selection: $pickerItems, maxSelectionCount: max(1, ObjectPhotoImage.maxPhotos - job.photos.count), matching: .images) {
            Label("ライブラリから選ぶ", systemImage: "photo.on.rectangle")
        }
    }
}

import CoreLocation
import SafariServices
import SwiftUI

/// 出典を開くための入れ物(sheet(item:) で使う)
struct ScopeAskURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// 出典のページ(SFSafariViewController)
struct ScopeAskSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// 地点に登録する場所(答えの場所、照合の結果、出典)
struct ScopeAskPlaceTarget: Identifiable {
    let id = UUID()
    var place: ScopeAskPlace
    var check: ScopeAskPlaceCheck?
    var citations: [ClaudeCitation]
}

/// 答えの場所を、地図で確かめて地点に登録する。地図をタップするとピンを動かせる。
/// 地図は既存の仕組み(Wi-Fiでは Apple Maps、モバイル通信では保存済みの地理院タイル)。標高は登録したあと自動で取る。
struct ScopeAskPlaceSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let target: ScopeAskPlaceTarget
    @State private var name: String
    @State private var coordinate: CLLocationCoordinate2D
    private let initial: CLLocationCoordinate2D

    init(target: ScopeAskPlaceTarget) {
        self.target = target
        let start = CLLocationCoordinate2D(latitude: target.place.latitude ?? 0, longitude: target.place.longitude ?? 0)
        initial = start
        _name = State(initialValue: target.place.name)
        _coordinate = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapContainerView(center: initial, spanMeters: 2000, pin: coordinate, isInteractive: true, showsUserLocation: true,
                                 onTapCoordinate: { coordinate = $0 })
                    .frame(height: 280)
                    .overlay(alignment: .top) {
                        Text("地図をタップすると、ピンをそこに動かせます")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.top, 8)
                    }
                Form {
                    Section("名前") {
                        TextField("名前", text: $name)
                    }
                    Section {
                        Text(String(format: "緯度 %.6f、経度 %.6f", coordinate.latitude, coordinate.longitude))
                            .font(.footnote.monospacedDigit())
                        if coordinate.latitude != initial.latitude || coordinate.longitude != initial.longitude {
                            Button("Claude の答えの位置に戻す") { coordinate = initial }
                        }
                    } header: {
                        Text("位置")
                    } footer: {
                        Text("Claude の答えの位置は、目安です。地図で確かめて、違えばピンを動かしてください。標高は、登録したあと自動で取ります(国土地理院の標高API)。")
                    }
                    Section("Claude の答え") {
                        LabeledContent("確からしさ", value: target.place.confidence?.label ?? "低")
                        if !target.place.reason.isEmpty {
                            Text(target.place.reason).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        }
                        if let check = target.check {
                            ForEach(check.lines, id: \.self) { line in
                                Text(line).font(.footnote).foregroundStyle(check.isWarning ? Color.orange : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if !target.citations.isEmpty {
                            Text("出典 \(target.citations.count)件(地点のメモに残します)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .keyboardDismissable()
            .navigationTitle("地点に登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登録") { register() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func register() {
        let store = env.waypoints
        let waypoint = Waypoint(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
                                latitude: coordinate.latitude, longitude: coordinate.longitude,
                                colorIndex: store.waypoints.count % WaypointPalette.colors.count,
                                memo: ScopeAskPlaceMemo.text(place: target.place, citations: target.citations))
        // 標高は、未設定のまま追加すると、既存の仕組みが自動で取る
        store.add(waypoint)
        dismiss()
    }
}

/// 登録した地点のメモ(根拠と出典の URL)
enum ScopeAskPlaceMemo {
    static func text(place: ScopeAskPlace, citations: [ClaudeCitation]) -> String {
        var lines = ["「撮って聞く」の Claude の答えから登録(確からしさ: \(place.confidence?.label ?? "低"))"]
        if !place.reason.isEmpty { lines.append("根拠: " + place.reason) }
        for citation in citations.prefix(5) { lines.append("出典: " + citation.title + " " + citation.url) }
        return lines.joined(separator: "\n")
    }
}

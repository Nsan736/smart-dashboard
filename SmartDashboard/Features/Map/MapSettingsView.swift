import CoreLocation
import SwiftUI

/// 地図の表示と、地理院タイルの保存の設定
struct MapSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmRedownload = false
    @State private var areaToDelete: TileArea?

    var body: some View {
        @Bindable var settings = env.settings
        let tiles = env.tiles
        Form {
            Section {
                Toggle("モバイル通信時も Apple Maps を使う", isOn: $settings.mapUsesAppleOnCellular)
            } header: {
                Text("表示")
            } footer: {
                Text("オフのときは、モバイル通信・省データモード・オフラインの間、保存済みの地理院タイルだけで表示し、通信しません。")
            }

            Section {
                Toggle("Wi-Fi接続中に自動で保存", isOn: $settings.tileAutoDownload)
                Toggle("Apple Maps で表示した範囲も保存", isOn: $settings.tileSavesViewedRegion)
                Picker("登録エリアの最大ズーム", selection: $settings.tileMaxZoom) {
                    ForEach(14...16, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("保存容量の上限", selection: $settings.tileStorageLimitMB) {
                    ForEach([100, 200, 300, 500, 1000], id: \.self) { Text("\($0) MB").tag($0) }
                }
            } header: {
                Text("保存")
            } footer: {
                Text("保存はアプリを開いていて、Wi-Fiなど従量制でない回線に接続している間だけ行います。同時接続は2本までです。")
            }
            .onChange(of: settings.tileAutoDownload) { _, _ in tiles.settingsChanged() }
            .onChange(of: settings.tileMaxZoom) { _, _ in tiles.settingsChanged() }
            .onChange(of: settings.tileStorageLimitMB) { _, _ in tiles.settingsChanged() }

            Section("状態") {
                LabeledContent("状態", value: tiles.state.label)
                if tiles.plannedCount > 0 {
                    ProgressView(value: Double(min(tiles.finishedCount, tiles.plannedCount)), total: Double(tiles.plannedCount)) {
                        Text("進捗 \(tiles.finishedCount) / \(tiles.plannedCount) 枚")
                            .font(.footnote)
                    }
                    if tiles.failedCount > 0 {
                        Text("取得に失敗: \(tiles.failedCount) 枚(次回に再試行します)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("保存済み", value: "\(Formatters.bytes(tiles.storedBytes)) / \(settings.tileStorageLimitMB) MB")
                LabeledContent("回線", value: env.network.summary)
            }

            Section {
                let nationwide = TileMath.estimate(bounds: .japan, zooms: TileMath.nationwideZooms)
                LabeledContent("日本全国の広域(ズーム5〜8)", value: Self.estimateText(nationwide))
                ForEach(settings.tileAreas) { area in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(area.name).font(.headline)
                            Spacer()
                            Button(role: .destructive) {
                                areaToDelete = area
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        Text(String(format: "%.3f, %.3f・半径 %.0f km", area.latitude, area.longitude, area.radiusKm))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("目安(ズーム9〜\(settings.tileMaxZoom)): \(Self.estimateText(TileMath.estimate(area: area, maxZoom: settings.tileMaxZoom)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    TileAreaEditorView()
                } label: {
                    Label("エリアを追加", systemImage: "plus.circle")
                }
            } header: {
                Text("保存する範囲")
            } footer: {
                Text("容量は東京周辺での実測の平均から計算した目安です。郊外や海上ではこれより小さくなります。")
            }

            Section {
                Button("すべて再ダウンロード") { confirmRedownload = true }
                Button("保存済みの地図をすべて削除", role: .destructive) {
                    Task { await tiles.deleteAll() }
                }
            } footer: {
                Link("出典: 地理院タイル(国土地理院)", destination: MapContainerView.gsiURL)
            }
        }
        .navigationTitle("地図")
        .task { await tiles.refreshUsage() }
        .confirmationDialog("保存済みの地図を削除して、取得し直しますか？", isPresented: $confirmRedownload, titleVisibility: .visible) {
            Button("再ダウンロード", role: .destructive) {
                Task { await tiles.redownloadAll() }
            }
        } message: {
            Text("Wi-Fi接続中のみ取得します。")
        }
        .confirmationDialog(
            "このエリアを削除しますか？",
            isPresented: Binding(get: { areaToDelete != nil }, set: { if !$0 { areaToDelete = nil } }),
            titleVisibility: .visible,
            presenting: areaToDelete
        ) { area in
            Button("エリアと保存済みの地図を削除", role: .destructive) {
                settings.tileAreas.removeAll { $0.id == area.id }
                areaToDelete = nil
                Task { await tiles.deleteTiles(of: area) }
            }
        } message: { area in
            Text("\(area.name) だけが使っているタイルを削除します。")
        }
    }

    static func estimateText(_ estimate: TileMath.Estimate) -> String {
        "約\(estimate.tileCount)枚・\(Formatters.bytes(estimate.bytes))"
    }
}

/// 登録エリアの追加。初期値は現在地から半径20km。
struct TileAreaEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var name = "現在地周辺"
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var radiusKm = 20.0
    @State private var locationMessage: String?

    private var area: TileArea? {
        guard let lat = Double(latitude), let lon = Double(longitude),
              (-90...90).contains(lat), (-180...180).contains(lon),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return TileArea(name: name.trimmingCharacters(in: .whitespaces), latitude: lat, longitude: lon, radiusKm: radiusKm)
    }

    var body: some View {
        Form {
            Section("エリア") {
                TextField("名前", text: $name)
                TextField("中心の緯度", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("中心の経度", text: $longitude).keyboardType(.numbersAndPunctuation)
                Button("現在地を中心にする") {
                    Task { await fillCurrentLocation() }
                }
                if let locationMessage {
                    Text(locationMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Stepper(value: $radiusKm, in: 5...50, step: 5) {
                    Text(String(format: "半径 %.0f km", radiusKm))
                }
            }
            Section("タイル数と容量の目安") {
                if let area {
                    ForEach(14...16, id: \.self) { zoom in
                        LabeledContent("ズーム9〜\(zoom)", value: MapSettingsView.estimateText(TileMath.estimate(area: area, maxZoom: zoom)))
                    }
                } else {
                    Text("中心を入力すると表示します").foregroundStyle(.secondary)
                }
            }
            Section {
                Button("登録") {
                    if let area {
                        env.settings.tileAreas.append(area)
                        env.tiles.settingsChanged()
                        dismiss()
                    }
                }
                .disabled(area == nil)
            }
        }
        .navigationTitle("エリアを追加")
        .task {
            if latitude.isEmpty { await fillCurrentLocation() }
        }
    }

    private func fillCurrentLocation() async {
        do {
            let location = try await env.location.currentLocation()
            latitude = String(format: "%.4f", location.coordinate.latitude)
            longitude = String(format: "%.4f", location.coordinate.longitude)
            locationMessage = nil
        } catch {
            locationMessage = error.localizedDescription
        }
    }
}

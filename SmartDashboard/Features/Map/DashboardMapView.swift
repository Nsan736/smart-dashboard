import MapKit
import SwiftUI
import UIKit

/// 端末に保存した地理院タイルだけで描くオーバーレイ。通信はしない。
/// 保存されていないタイルは、保存済みの広い縮尺のタイルを拡大して使い、それもなければグレーの空白にする。
final class StoredTileOverlay: MKTileOverlay {
    private let store: TileStore
    private static let placeholder: Data = makePlaceholder()

    init(store: TileStore) {
        self.store = store
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = TileMath.sourceZooms.lowerBound
        maximumZ = TileMath.sourceZooms.upperBound
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let tile = TileCoord(z: path.z, x: path.x, y: path.y)
        if let data = store.data(for: tile), !data.isEmpty {
            result(data, nil)
            return
        }
        result(Self.upscaled(tile, store: store) ?? Self.placeholder, nil)
    }

    /// 最大5段階まで親のタイルをさかのぼり、該当部分を切り出して拡大する
    private static func upscaled(_ tile: TileCoord, store: TileStore) -> Data? {
        var ancestor = tile
        for level in 1...5 {
            guard let parent = ancestor.parent, parent.z >= TileMath.sourceZooms.lowerBound else { return nil }
            ancestor = parent
            guard let data = store.data(for: ancestor), !data.isEmpty,
                  let image = UIImage(data: data)?.cgImage else { continue }
            let scale = 1 << level
            let size = CGFloat(image.width) / CGFloat(scale)
            let rect = CGRect(x: CGFloat(tile.x % scale) * size, y: CGFloat(tile.y % scale) * size, width: size, height: size)
            guard let cropped = image.cropping(to: rect) else { return nil }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: rendererFormat())
            return renderer.pngData { context in
                context.cgContext.interpolationQuality = .low
                UIImage(cgImage: cropped).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
            }
        }
        return nil
    }

    private static func rendererFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return format
    }

    private static func makePlaceholder() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: rendererFormat())
        return renderer.pngData { context in
            UIColor(white: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            UIColor(white: 0.75, alpha: 1).setStroke()
            context.stroke(CGRect(x: 0.5, y: 0.5, width: 255, height: 255))
            let text = "未ダウンロードの範囲" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: UIColor(white: 0.45, alpha: 1),
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (256 - size.width) / 2, y: (256 - size.height) / 2), withAttributes: attributes)
        }
    }
}

/// 回線の状態で Apple Maps と保存済み地図を切り替える地図。表示位置と縮尺は切り替え後も維持する。
struct DashboardMapView: UIViewRepresentable {
    let mode: MapMode
    let store: TileStore
    /// 保存済みタイルが増えたときに描き直すための値
    let tileRevision: Int
    var center: CLLocationCoordinate2D?
    var spanMeters: CLLocationDistance = 3000
    var pin: CLLocationCoordinate2D?
    var isInteractive = true
    var showsUserLocation = false
    /// 半透明で重ねる雨雲レーダー
    var radar: RadarLayer?
    /// 表示範囲が変わったとき(範囲、ズーム)
    var onRegionChange: ((GeoBounds, Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = isInteractive
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        if let center {
            map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters), animated: false)
            context.coordinator.lastCenter = center
        } else {
            // 位置が分からないときは日本全体を表示する
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.5, longitude: 138),
                                             span: MKCoordinateSpan(latitudeDelta: 16, longitudeDelta: 16)), animated: false)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onRegionChange = onRegionChange
        map.isScrollEnabled = isInteractive
        map.isZoomEnabled = isInteractive
        map.showsUserLocation = showsUserLocation

        // 地図の切り替え。MKMapViewはそのままなので、表示位置と縮尺は維持される。
        if coordinator.mode != mode {
            coordinator.mode = mode
            if let overlay = coordinator.baseOverlay {
                map.removeOverlay(overlay)
                coordinator.baseOverlay = nil
            }
            if mode == .offline {
                let overlay = StoredTileOverlay(store: store)
                map.insertOverlay(overlay, at: 0, level: .aboveLabels)
                coordinator.baseOverlay = overlay
            }
            coordinator.tileRevision = tileRevision
        } else if mode == .offline, coordinator.tileRevision != tileRevision {
            coordinator.tileRevision = tileRevision
            coordinator.scheduleReload(map)
        }

        // 雨雲レーダー。コマが変わったら、新しいものを重ねてから古いものを外す(ちらつきを抑える)。
        if coordinator.radarOverlay?.frame != radar?.frame {
            let old = coordinator.radarOverlay
            if let radar {
                let overlay = RadarTileOverlay(frame: radar.frame, loader: radar.loader)
                map.addOverlay(overlay, level: .aboveLabels)
                coordinator.radarOverlay = overlay
            } else {
                coordinator.radarOverlay = nil
            }
            if let old {
                DispatchQueue.main.asyncAfter(deadline: .now() + (radar == nil ? 0 : 0.35)) { [weak map] in
                    map?.removeOverlay(old)
                }
            }
        }

        // 外から中心が変わったとき(現在地の更新など)だけ移動する
        if let center, !isInteractive || coordinator.lastCenter == nil {
            let moved = coordinator.lastCenter.map {
                abs($0.latitude - center.latitude) > 0.0005 || abs($0.longitude - center.longitude) > 0.0005
            } ?? true
            if moved {
                coordinator.lastCenter = center
                map.setRegion(MKCoordinateRegion(center: center, latitudinalMeters: spanMeters, longitudinalMeters: spanMeters), animated: false)
            }
        }

        // ピン
        let currentPin = map.annotations.compactMap { $0 as? MKPointAnnotation }.first
        if let pin {
            if let currentPin {
                currentPin.coordinate = pin
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = pin
                map.addAnnotation(annotation)
            }
        } else if let currentPin {
            map.removeAnnotation(currentPin)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var mode: MapMode?
        var baseOverlay: MKTileOverlay?
        var radarOverlay: RadarTileOverlay?
        var tileRevision = 0
        var lastCenter: CLLocationCoordinate2D?
        var onRegionChange: ((GeoBounds, Int) -> Void)?
        private var reloadScheduled = false

        /// タイルが保存されるたびに描き直すと重いので、2秒に1回にまとめる
        func scheduleReload(_ map: MKMapView) {
            guard !reloadScheduled else { return }
            reloadScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak map] in
                guard let self else { return }
                self.reloadScheduled = false
                guard let map, let overlay = self.baseOverlay,
                      let renderer = map.renderer(for: overlay) as? MKTileOverlayRenderer else { return }
                renderer.reloadData()
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                if tiles is RadarTileOverlay { renderer.alpha = 0.65 }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            let bounds = GeoBounds(
                minLatitude: region.center.latitude - region.span.latitudeDelta / 2,
                maxLatitude: region.center.latitude + region.span.latitudeDelta / 2,
                minLongitude: region.center.longitude - region.span.longitudeDelta / 2,
                maxLongitude: region.center.longitude + region.span.longitudeDelta / 2)
            let zoom = TileMath.zoomLevel(longitudeDelta: region.span.longitudeDelta, widthPoints: Double(mapView.bounds.width))
            onRegionChange?(bounds, zoom)
        }
    }
}

/// 地図に、どちらの地図かの表示と出典を重ねたもの
struct MapContainerView: View {
    @Environment(AppEnvironment.self) private var env
    var center: CLLocationCoordinate2D?
    var spanMeters: CLLocationDistance = 3000
    var pin: CLLocationCoordinate2D?
    var isInteractive = true
    var showsUserLocation = false
    var radar: RadarLayer?

    static let gsiURL = URL(string: "https://maps.gsi.go.jp/development/ichiran.html")!

    var body: some View {
        let mode = MapMode.decide(network: env.network.status, allowAppleOnCellular: env.settings.mapUsesAppleOnCellular)
        DashboardMapView(
            mode: mode,
            store: env.tiles.store,
            tileRevision: env.tiles.revision,
            center: center,
            spanMeters: spanMeters,
            pin: pin,
            isInteractive: isInteractive,
            showsUserLocation: showsUserLocation,
            radar: radar,
            onRegionChange: { bounds, zoom in
                // Wi-Fi接続中に Apple Maps で見た範囲を保存する
                guard mode == .apple, isInteractive else { return }
                env.tiles.enqueueViewedRegion(bounds: bounds, zoom: zoom)
            }
        )
        .overlay(alignment: .topLeading) {
            Text(mode.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
                .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            if mode == .offline {
                Link("出典: 地理院タイル", destination: Self.gsiURL)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }
        }
    }
}

/// 全画面の地図
struct FullMapView: View {
    var center: CLLocationCoordinate2D?

    var body: some View {
        MapContainerView(center: center, spanMeters: 5000, pin: center, isInteractive: true, showsUserLocation: true)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("地図")
            .navigationBarTitleDisplayMode(.inline)
    }
}

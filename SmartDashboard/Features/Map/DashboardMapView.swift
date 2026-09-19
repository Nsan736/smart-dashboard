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
    /// 路線などの線と、駅などのピン
    var lines: [MapLine] = []
    var markers: [MapMarker] = []
    /// この値が変わったとき、線とピンの全体が入るように表示範囲を合わせる
    var fitKey: String?
    var onSelectLine: ((String) -> Void)?
    var onSelectMarker: ((String) -> Void)?
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
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
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
        coordinator.onSelectLine = onSelectLine
        coordinator.onSelectMarker = onSelectMarker
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

        coordinator.updateRoutes(lines, on: map)
        coordinator.updateMarkers(markers, on: map)
        coordinator.fitIfNeeded(key: fitKey, lines: lines, markers: markers, on: map)

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
        let currentPin = map.annotations.compactMap { $0 as? MKPointAnnotation }.first { !($0 is StationAnnotation) }
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

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopBlinking()
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var mode: MapMode?
        var baseOverlay: MKTileOverlay?
        var radarOverlay: RadarTileOverlay?
        var onSelectLine: ((String) -> Void)?
        var onSelectMarker: ((String) -> Void)?
        private var routeOverlays: [RouteOverlay] = []
        private var routeSignature = ""
        private var markerSignature = ""
        private var lastFitKey: String?
        private var routeRenderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
        private var blinkTimer: Timer?
        private var blinkDimmed = false

        // MARK: 線

        func updateRoutes(_ lines: [MapLine], on map: MKMapView) {
            let signature = lines.map(\.signature).joined(separator: ";")
            guard signature != routeSignature else { return }
            routeSignature = signature
            map.removeOverlays(routeOverlays)
            routeOverlays = []
            routeRenderers = [:]
            for line in lines where line.coordinates.count >= 2 {
                // 縁取り(路線の色)を下に、運行状況の色を上に重ねる
                if let casing = line.casingColor {
                    routeOverlays.append(makeOverlay(line, color: casing, width: line.isEmphasized ? 11 : 8, isCasing: true))
                }
                routeOverlays.append(makeOverlay(line, color: line.color, width: line.isEmphasized ? 7 : 4, isCasing: false))
            }
            // 保存済み地図のタイル(.aboveLabels の一番下)より上に描く
            map.addOverlays(routeOverlays, level: .aboveLabels)
            if lines.contains(where: \.isEmphasized) { startBlinking() } else { stopBlinking() }
        }

        private func makeOverlay(_ line: MapLine, color: UIColor, width: CGFloat, isCasing: Bool) -> RouteOverlay {
            let overlay = RouteOverlay(coordinates: line.coordinates, count: line.coordinates.count)
            overlay.lineID = line.id
            overlay.isCasing = isCasing
            overlay.strokeColor = color
            overlay.strokeWidth = width
            overlay.blinks = line.isEmphasized && !isCasing
            return overlay
        }

        private func startBlinking() {
            guard blinkTimer == nil else { return }
            // タイマーはメインのRunLoopで動く
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.blinkTick() }
            }
        }

        private func blinkTick() {
            blinkDimmed.toggle()
            for overlay in routeOverlays where overlay.blinks {
                guard let renderer = routeRenderers[ObjectIdentifier(overlay)] else { continue }
                renderer.alpha = blinkDimmed ? 0.3 : 1
                renderer.setNeedsDisplay()
            }
        }

        func stopBlinking() {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }

        // MARK: ピン

        func updateMarkers(_ markers: [MapMarker], on map: MKMapView) {
            let signature = markers.map(\.signature).joined(separator: ";")
            guard signature != markerSignature else { return }
            markerSignature = signature
            map.removeAnnotations(map.annotations.filter { $0 is StationAnnotation })
            for marker in markers {
                let annotation = StationAnnotation()
                annotation.markerID = marker.id
                annotation.title = marker.title
                annotation.coordinate = marker.coordinate
                map.addAnnotation(annotation)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is StationAnnotation else { return nil }
            let identifier = "station"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.glyphImage = UIImage(systemName: "tram.fill")
            view.markerTintColor = .systemIndigo
            view.displayPriority = .required
            view.canShowCallout = false
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let station = view.annotation as? StationAnnotation else { return }
            onSelectMarker?(station.markerID)
            mapView.deselectAnnotation(station, animated: false)
        }

        // MARK: 表示範囲

        func fitIfNeeded(key: String?, lines: [MapLine], markers: [MapMarker], on map: MKMapView) {
            guard let key, key != lastFitKey else { return }
            let coordinates = lines.flatMap(\.coordinates) + markers.map(\.coordinate)
            guard !coordinates.isEmpty else { return }
            lastFitKey = key
            var rect = MKMapRect.null
            for coordinate in coordinates {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 36, left: 28, bottom: 28, right: 28), animated: false)
        }

        // MARK: 線のタップ

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: map)
            // ピンのタップは didSelect で扱う
            var hit = map.hitTest(point, with: nil)
            while let view = hit {
                if view is MKAnnotationView { return }
                hit = view.superview
            }
            var best: (id: String, distance: CGFloat)?
            for overlay in routeOverlays where !overlay.isCasing {
                let points = overlay.points()
                var screen: [CGPoint] = []
                screen.reserveCapacity(overlay.pointCount)
                for index in 0..<overlay.pointCount {
                    screen.append(map.convert(points[index].coordinate, toPointTo: map))
                }
                let distance = MapGeometry.distance(from: point, toPolyline: screen)
                if distance < (best?.distance ?? 24) { best = (overlay.lineID, distance) }
            }
            if let best { onSelectLine?(best.id) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

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
            if let route = overlay as? RouteOverlay {
                let renderer = MKPolylineRenderer(polyline: route)
                renderer.strokeColor = route.strokeColor
                renderer.lineWidth = route.strokeWidth
                renderer.lineCap = .round
                renderer.lineJoin = .round
                routeRenderers[ObjectIdentifier(route)] = renderer
                return renderer
            }
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
    var lines: [MapLine] = []
    var markers: [MapMarker] = []
    var fitKey: String?
    var onSelectLine: ((String) -> Void)?
    var onSelectMarker: ((String) -> Void)?

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
            lines: lines,
            markers: markers,
            fitKey: fitKey,
            onSelectLine: onSelectLine,
            onSelectMarker: onSelectMarker,
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

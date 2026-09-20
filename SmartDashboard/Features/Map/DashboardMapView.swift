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
    /// 観測点ごとの震度(1枚の重ね描きで描く)
    var intensityDots: [MapIntensityDot] = []
    /// この値が変わったとき、線とピンの全体が入るように表示範囲を合わせる
    var fitKey: String?
    /// 表示範囲を合わせる対象の線。nilならすべての線。
    var fitLineIDs: Set<String>?
    var onSelectLine: ((String) -> Void)?
    var onSelectMarker: ((String) -> Void)?
    /// 電車(1秒ごとに位置が変わる)と、駅の点
    var trains: [MapTrain] = []
    var stationDots: [MapStationDot] = []
    var onSelectTrain: ((String) -> Void)?
    /// この値が変わったら、現在地へ移動する
    var recenterKey = 0
    /// 地図を長押しした位置(スコープの地点の登録用)
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    /// 表示範囲が変わったとき(範囲、ズーム)
    var onRegionChange: ((GeoBounds, Int) -> Void)?
    /// 現在地への追従(経路の案内用)。trackingKey が変わったら、追従をかけ直す(「現在地に戻る」)。
    var tracking: MapTracking = .none
    var trackingKey = 0
    /// 指で地図を動かして、追従が外れたとき
    var onTrackingLost: (() -> Void)?

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
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        map.addGestureRecognizer(longPress)
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
        coordinator.onLongPress = onLongPress
        coordinator.onTrackingLost = onTrackingLost
        coordinator.applyTracking(tracking, key: trackingKey, on: map)
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

        coordinator.onSelectTrain = onSelectTrain
        coordinator.updateRoutes(lines, on: map)
        coordinator.updateMarkers(markers, on: map)
        coordinator.updateIntensityDots(intensityDots, on: map)
        coordinator.updateStationDots(stationDots, on: map)
        coordinator.updateTrains(trains, on: map)
        coordinator.recenterIfNeeded(key: recenterKey, on: map)
        coordinator.fitIfNeeded(key: fitKey, lines: lines.filter { fitLineIDs?.contains($0.id) ?? true }, markers: markers, on: map)

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
        // 駅や電車の注釈(MKPointAnnotation のサブクラス)は除き、素のピンだけを対象にする
        let currentPin = map.annotations.compactMap { $0 as? MKPointAnnotation }.first { type(of: $0) == MKPointAnnotation.self }
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
        var onSelectTrain: ((String) -> Void)?
        private var trainAnnotations: [String: TrainAnnotation] = [:]
        private var stationDotSignature = ""
        private var lastRecenterKey = 0
        private var currentZoom = 0

        // MARK: 電車

        /// 毎秒呼ばれる。追加と削除は差分だけ行い、位置は1秒かけてなめらかに動かす。
        func updateTrains(_ trains: [MapTrain], on map: MKMapView) {
            let ids = Set(trains.map(\.id))
            let removed = trainAnnotations.filter { !ids.contains($0.key) }
            if !removed.isEmpty {
                map.removeAnnotations(Array(removed.values))
                for key in removed.keys { trainAnnotations[key] = nil }
            }
            for train in trains {
                if let annotation = trainAnnotations[train.id] {
                    UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
                        annotation.coordinate = train.coordinate
                    }
                    if annotation.appearance != train.appearance {
                        configure(annotation, with: train)
                        (map.view(for: annotation) as? TrainAnnotationView)?.apply(annotation)
                    }
                } else {
                    let annotation = TrainAnnotation()
                    annotation.trainID = train.id
                    annotation.coordinate = train.coordinate
                    configure(annotation, with: train)
                    trainAnnotations[train.id] = annotation
                    map.addAnnotation(annotation)
                }
            }
        }

        private func configure(_ annotation: TrainAnnotation, with train: MapTrain) {
            annotation.appearance = train.appearance
            annotation.color = train.color
            annotation.heading = train.heading
            annotation.label = train.label
            annotation.isExpress = train.isExpress
            annotation.isDimmed = train.isDimmed
        }

        // MARK: 駅の点

        func updateStationDots(_ dots: [MapStationDot], on map: MKMapView) {
            let signature = dots.map(\.signature).joined(separator: ";")
            guard signature != stationDotSignature else { return }
            stationDotSignature = signature
            map.removeAnnotations(map.annotations.filter { $0 is StationDotAnnotation })
            for dot in dots {
                let annotation = StationDotAnnotation()
                annotation.stationID = dot.id
                annotation.title = dot.title
                annotation.coordinate = dot.coordinate
                annotation.isMajor = dot.isMajor
                annotation.isRegistered = dot.isRegistered
                map.addAnnotation(annotation)
            }
        }

        /// ズームに応じて駅名を出し分ける(広域では主要駅と登録駅だけ)
        private func refreshStationNames(on map: MKMapView) {
            for annotation in map.annotations {
                guard let station = annotation as? StationDotAnnotation,
                      let view = map.view(for: station) as? StationDotView else { continue }
                view.apply(station, showsName: MapStationRule.showsName(zoom: currentZoom, isMajor: station.isMajor))
            }
        }

        func recenterIfNeeded(key: Int, on map: MKMapView) {
            guard key != lastRecenterKey else { return }
            lastRecenterKey = key
            guard let location = map.userLocation.location else { return }
            let region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)
            map.setRegion(region, animated: true)
        }

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
                // 選ばれていない路線は、細く薄く描く
                if let casing = line.casingColor {
                    routeOverlays.append(makeOverlay(line, color: casing, width: line.isDimmed ? 5 : (line.isEmphasized ? 11 : 8), isCasing: true))
                }
                routeOverlays.append(makeOverlay(line, color: line.color, width: line.isDimmed ? 2.5 : (line.isEmphasized ? 7 : 4), isCasing: false))
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
            overlay.baseAlpha = line.isDimmed ? 0.3 : 1
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
                renderer.alpha = blinkDimmed ? 0.3 : overlay.baseAlpha
                renderer.setNeedsDisplay()
            }
        }

        func stopBlinking() {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }

        // MARK: 現在地への追従

        var onTrackingLost: (() -> Void)?
        private var tracking: MapTracking = .none
        private var trackingKey = 0
        /// 追従の設定を自分で変えている間は、「外れた」と知らせない
        private var isApplyingTracking = false

        /// 一度でも追従を使った地図(経路の案内)では、現在地を矢印で表示する
        private(set) var showsDirectionArrow = false

        func applyTracking(_ new: MapTracking, key: Int, on map: MKMapView) {
            guard new != tracking || key != trackingKey else { return }
            tracking = new
            trackingKey = key
            if new != .none { showsDirectionArrow = true }
            isApplyingTracking = true
            map.isRotateEnabled = new == .followHeading
            switch new {
            case .none: map.setUserTrackingMode(.none, animated: false)
            // 進行方向を上にする表示から戻すと、MapKit が北を上に戻す
            case .follow: map.setUserTrackingMode(.follow, animated: true)
            case .followHeading: map.setUserTrackingMode(.followWithHeading, animated: true)
            }
            isApplyingTracking = false
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // 指で地図を動かすと、MapKit が追従を外す
            if mode == .none, tracking != .none, !isApplyingTracking {
                tracking = .none
                onTrackingLost?()
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            rotateDirectionArrow(on: mapView)
        }

        /// 現在地の矢印を、進行方向(なければ端末の向き)に向ける。地図が回転していれば、その分を引く。
        func rotateDirectionArrow(on map: MKMapView) {
            guard let view = map.view(for: map.userLocation) as? DirectionArrowView else { return }
            let course = map.userLocation.location?.course ?? -1
            let heading = map.userLocation.heading?.trueHeading ?? -1
            guard let direction = MapDirection.arrowRotation(course: course, heading: heading, cameraHeading: map.camera.heading) else { return }
            view.setRotation(degrees: direction)
        }

        // MARK: 観測点ごとの震度

        private var intensitySignature = ""

        func updateIntensityDots(_ dots: [MapIntensityDot], on map: MKMapView) {
            let signature = IntensityDotsOverlay.signature(dots)
            guard signature != intensitySignature else { return }
            intensitySignature = signature
            map.removeOverlays(map.overlays.filter { $0 is IntensityDotsOverlay })
            if !dots.isEmpty { map.addOverlay(IntensityDotsOverlay(dots: dots), level: .aboveLabels) }
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
                annotation.style = marker.style
                annotation.title = marker.title
                annotation.coordinate = marker.coordinate
                map.addAnnotation(annotation)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                // 経路の案内では、現在地を進行方向の分かる矢印で表示する。それ以外は標準の青い点。
                guard showsDirectionArrow else { return nil }
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: DirectionArrowView.reuseID) as? DirectionArrowView)
                    ?? DirectionArrowView(annotation: annotation, reuseIdentifier: DirectionArrowView.reuseID)
                view.annotation = annotation
                return view
            }
            if let train = annotation as? TrainAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: TrainAnnotationView.reuseID) as? TrainAnnotationView)
                    ?? TrainAnnotationView(annotation: train, reuseIdentifier: TrainAnnotationView.reuseID)
                view.annotation = train
                view.apply(train)
                return view
            }
            if let station = annotation as? StationDotAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: StationDotView.reuseID) as? StationDotView)
                    ?? StationDotView(annotation: station, reuseIdentifier: StationDotView.reuseID)
                view.annotation = station
                view.apply(station, showsName: MapStationRule.showsName(zoom: currentZoom, isMajor: station.isMajor))
                return view
            }
            guard let marker = annotation as? StationAnnotation else { return nil }
            let identifier = "station"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.glyphText = nil
            switch marker.style {
            case .station:
                view.glyphImage = UIImage(systemName: "tram.fill")
                view.markerTintColor = .systemIndigo
            case .place:
                view.glyphImage = UIImage(systemName: "mappin")
                view.markerTintColor = .systemOrange
            case .epicenter:
                view.glyphImage = UIImage(systemName: "xmark")
                view.markerTintColor = .systemRed
            case .dot:
                view.glyphImage = UIImage(systemName: "circle.fill")
                view.markerTintColor = .systemBlue
            case .turn:
                view.glyphImage = UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                view.markerTintColor = .systemYellow
            }
            view.titleVisibility = .visible
            view.displayPriority = .required
            view.canShowCallout = false
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let train = view.annotation as? TrainAnnotation {
                onSelectTrain?(train.trainID)
                mapView.deselectAnnotation(train, animated: false)
                return
            }
            if let dot = view.annotation as? StationDotAnnotation {
                if dot.isRegistered { onSelectMarker?(dot.stationID) }
                mapView.deselectAnnotation(dot, animated: false)
                return
            }
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

        var onLongPress: ((CLLocationCoordinate2D) -> Void)?

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map = recognizer.view as? MKMapView else { return }
            onLongPress?(map.convert(recognizer.location(in: map), toCoordinateFrom: map))
        }

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
                renderer.alpha = route.baseAlpha
                routeRenderers[ObjectIdentifier(route)] = renderer
                return renderer
            }
            if let dots = overlay as? IntensityDotsOverlay {
                return IntensityDotsRenderer(overlay: dots)
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
            if zoom != currentZoom {
                currentZoom = zoom
                refreshStationNames(on: mapView)
            }
            onRegionChange?(bounds, zoom)
            rotateDirectionArrow(on: mapView)
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
    var intensityDots: [MapIntensityDot] = []
    var fitKey: String?
    var fitLineIDs: Set<String>?
    var onSelectLine: ((String) -> Void)?
    var onSelectMarker: ((String) -> Void)?
    var trains: [MapTrain] = []
    var stationDots: [MapStationDot] = []
    var onSelectTrain: ((String) -> Void)?
    var recenterKey = 0
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    var tracking: MapTracking = .none
    var trackingKey = 0
    var onTrackingLost: (() -> Void)?

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
            intensityDots: intensityDots,
            fitKey: fitKey,
            fitLineIDs: fitLineIDs,
            onSelectLine: onSelectLine,
            onSelectMarker: onSelectMarker,
            trains: trains,
            stationDots: stationDots,
            onSelectTrain: onSelectTrain,
            recenterKey: recenterKey,
            onLongPress: onLongPress,
            onRegionChange: { bounds, zoom in
                // Wi-Fi接続中に Apple Maps で見た範囲を保存する
                guard mode == .apple, isInteractive else { return }
                env.tiles.enqueueViewedRegion(bounds: bounds, zoom: zoom)
            },
            tracking: tracking,
            trackingKey: trackingKey,
            onTrackingLost: onTrackingLost
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

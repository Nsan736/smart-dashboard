import MapKit
import UIKit

/// 観測点ごとの震度を、1枚の重ね描きで地図に描く。ピン(アノテーション)を数千個置くと iPhone SE 第2世代では重いので使わない。
final class IntensityDotsOverlay: NSObject, MKOverlay {
    struct Item {
        let point: MKMapPoint
        let scale: Int
    }

    /// 震度の小さい順(あとに描く大きい震度が上に重なる)
    let items: [Item]
    let signature: String
    let coordinate = CLLocationCoordinate2D(latitude: 36.5, longitude: 138)
    let boundingMapRect = MKMapRect.world

    init(dots: [MapIntensityDot]) {
        items = dots.map { Item(point: MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)), scale: $0.scale) }
        signature = Self.signature(dots)
    }

    static func signature(_ dots: [MapIntensityDot]) -> String {
        "\(dots.count)|\(dots.first?.latitude ?? 0)|\(dots.last?.longitude ?? 0)|\(dots.reduce(0) { $0 + $1.scale })"
    }
}

/// 地図のタイルごとに呼ばれる。そのタイルに入る点だけを描く。点の大きさは、縮尺に関係なく画面上で一定。
final class IntensityDotsRenderer: MKOverlayRenderer {
    /// 画面上の点の半径(pt)
    static let radius: CGFloat = 5

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? IntensityDotsOverlay else { return }
        // 地図の座標での半径。タイルの境目にかかる点も描くよう、範囲を半径の分だけ広げて探す
        let radius = Double(Self.radius / zoomScale)
        let search = mapRect.insetBy(dx: -radius * 1.5, dy: -radius * 1.5)
        context.setLineWidth(CGFloat(radius) * 0.25)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        for item in overlay.items where search.contains(item.point) {
            let center = point(for: item.point)
            let rect = CGRect(x: center.x - CGFloat(radius), y: center.y - CGFloat(radius), width: CGFloat(radius) * 2, height: CGFloat(radius) * 2)
            context.setFillColor(SeismicScaleStyle.uiColor(item.scale).cgColor)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }
}

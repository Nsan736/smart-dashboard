import MapKit
import UIKit

/// 地図に描く円(位置の精度など)
struct MapCircle {
    let id: String
    let center: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let color: UIColor

    var signature: String {
        "\(id)|\(String(format: "%.6f,%.6f", center.latitude, center.longitude))|\(Int(radius))|\(color.description)"
    }
}

/// 地図の上で動く印(仮想の現在地、線路に投影した位置など)。位置は差分で動かし、作り直さない。
struct MapMovingMark {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let color: UIColor
    /// 直径(pt)
    var diameter: CGFloat = 16
    /// 中を白く抜く(投影した位置など)
    var isHollow = false

    var appearance: String { "\(color.description)|\(diameter)|\(isHollow)" }
}

final class MapCircleOverlay: MKCircle {
    var circleID = ""
    var color: UIColor = .systemBlue
}

final class MovingMarkAnnotation: MKPointAnnotation {
    var markID = ""
    var appearance = ""
    var color: UIColor = .systemBlue
    var diameter: CGFloat = 16
    var isHollow = false
}

final class MovingMarkView: MKAnnotationView {
    static let reuseID = "movingMark"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .circle
        canShowCallout = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    func apply(_ mark: MovingMarkAnnotation) {
        let size = CGSize(width: mark.diameter, height: mark.diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1.5, dy: 1.5)
            let cg = context.cgContext
            if mark.isHollow {
                cg.setFillColor(UIColor.white.cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(mark.color.cgColor)
                cg.setLineWidth(3)
                cg.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))
            } else {
                cg.setFillColor(mark.color.cgColor)
                cg.fillEllipse(in: rect)
                cg.setStrokeColor(UIColor.white.cgColor)
                cg.setLineWidth(2.5)
                cg.strokeEllipse(in: rect)
            }
        }
        frame.size = size
    }
}

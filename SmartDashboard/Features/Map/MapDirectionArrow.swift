import MapKit
import UIKit

enum MapDirection {
    /// 現在地の矢印の回転(度、画面の上が0、時計回り)。
    /// 進行方向(course)が分かればそれを、なければ端末の向き(heading)を使う。どちらも無効(負の値)なら nil。
    /// 地図が回転している(進行方向を上にしている)ときは、その分を引く。
    static func arrowRotation(course: Double, heading: Double, cameraHeading: Double) -> Double? {
        let direction: Double
        if course >= 0 {
            direction = course
        } else if heading >= 0 {
            direction = heading
        } else {
            return nil
        }
        return WaypointMath.normalized(direction - cameraHeading)
    }
}

/// 現在地を、進行方向の分かる矢印で表示する(経路の案内用)
final class DirectionArrowView: MKAnnotationView {
    static let reuseID = "directionArrow"
    private let arrow = UIImageView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        backgroundColor = .clear
        let circle = UIView(frame: bounds.insetBy(dx: 3, dy: 3))
        circle.backgroundColor = .white
        circle.layer.cornerRadius = circle.bounds.width / 2
        circle.layer.shadowColor = UIColor.black.cgColor
        circle.layer.shadowOpacity = 0.3
        circle.layer.shadowRadius = 3
        circle.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(circle)
        arrow.frame = bounds.insetBy(dx: 8, dy: 8)
        arrow.image = UIImage(systemName: "location.north.fill")
        arrow.tintColor = .systemBlue
        arrow.contentMode = .scaleAspectFit
        addSubview(arrow)
        displayPriority = .required
        canShowCallout = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) は使いません")
    }

    func setRotation(degrees: Double) {
        arrow.transform = CGAffineTransform(rotationAngle: CGFloat(degrees * .pi / 180))
    }
}

import MapKit
import UIKit

/// 地図に描く電車
struct MapTrain {
    let id: String
    let coordinate: CLLocationCoordinate2D
    /// 進行方向(度。北が0、時計回り)。止まっていて向きが分からないときはnil。
    let heading: Double?
    let color: UIColor
    /// 種別の短いラベル(各停は空)
    let label: String
    /// 各停以外は形を変える
    let isExpress: Bool
    /// 選ばれていない路線の電車。薄く表示する。
    var isDimmed = false

    var appearance: String {
        "\(color.description)|\(label)|\(isExpress)|\(isDimmed)|\(heading.map { String(Int($0 / 5)) } ?? "-")"
    }
}

/// 地図に描く駅の点
struct MapStationDot {
    let id: String
    let title: String
    let coordinate: CLLocationCoordinate2D
    /// 広域でも駅名を出す駅(登録した駅、終点、乗換駅)
    let isMajor: Bool
    /// 登録した駅(強調して、タップできるようにする)
    let isRegistered: Bool

    var signature: String {
        "\(id)|\(title)|\(isMajor)|\(isRegistered)"
    }
}

final class TrainAnnotation: MKPointAnnotation {
    var trainID = ""
    var appearance = ""
    var color: UIColor = .systemGreen
    var heading: Double?
    var label = ""
    var isExpress = false
    var isDimmed = false
}

final class StationDotAnnotation: MKPointAnnotation {
    var stationID = ""
    var isMajor = false
    var isRegistered = false
}

/// 進行方向が分かる矢印のアイコン。色は遅れの有無、形とラベルは種別を表す。
final class TrainAnnotationView: MKAnnotationView {
    static let reuseID = "train"
    private let arrow = UIImageView()
    private let typeLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        arrow.frame = bounds
        addSubview(arrow)
        typeLabel.font = .systemFont(ofSize: 9, weight: .bold)
        typeLabel.textColor = .white
        typeLabel.textAlignment = .center
        typeLabel.layer.cornerRadius = 3
        typeLabel.layer.masksToBounds = true
        addSubview(typeLabel)
        displayPriority = .required
        collisionMode = .circle
        canShowCallout = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    func apply(_ train: TrainAnnotation) {
        arrow.image = Self.icon(color: train.color, isExpress: train.isExpress, hasHeading: train.heading != nil)
        arrow.transform = CGAffineTransform(rotationAngle: CGFloat((train.heading ?? 0) * .pi / 180))
        alpha = train.isDimmed ? 0.3 : 1
        typeLabel.isHidden = train.label.isEmpty
        typeLabel.text = train.label
        typeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        let width = max(14, typeLabel.intrinsicContentSize.width + 6)
        typeLabel.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 2, width: width, height: 12)
    }

    /// 上向きの矢印。各停は円、それ以外は角丸の四角。
    static func icon(color: UIColor, isExpress: Bool, hasHeading: Bool) -> UIImage {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { context in
            let body = CGRect(x: 5, y: 5, width: 20, height: 20)
            let shape = isExpress ? UIBezierPath(roundedRect: body, cornerRadius: 5) : UIBezierPath(ovalIn: body)
            color.setFill()
            shape.fill()
            UIColor.white.setStroke()
            shape.lineWidth = 2
            shape.stroke()
            if hasHeading {
                let tip = UIBezierPath()
                tip.move(to: CGPoint(x: 15, y: 0))
                tip.addLine(to: CGPoint(x: 21, y: 8))
                tip.addLine(to: CGPoint(x: 9, y: 8))
                tip.close()
                color.setFill()
                tip.fill()
                UIColor.white.setStroke()
                tip.lineWidth = 1.5
                tip.stroke()
                let inner = UIBezierPath()
                inner.move(to: CGPoint(x: 15, y: 9))
                inner.addLine(to: CGPoint(x: 19, y: 17))
                inner.addLine(to: CGPoint(x: 11, y: 17))
                inner.close()
                UIColor.white.setFill()
                inner.fill()
            }
            _ = context
        }
    }
}

/// 駅の点。駅名はズームに応じて出す。
final class StationDotView: MKAnnotationView {
    static let reuseID = "stationDot"
    private let dot = UIView()
    private let nameLabel = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        dot.isUserInteractionEnabled = false
        addSubview(dot)
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.75)
        nameLabel.layer.cornerRadius = 3
        nameLabel.layer.masksToBounds = true
        nameLabel.textAlignment = .center
        addSubview(nameLabel)
        displayPriority = .defaultHigh
        canShowCallout = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    func apply(_ station: StationDotAnnotation, showsName: Bool) {
        let diameter: CGFloat = station.isRegistered ? 14 : 8
        dot.frame = CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        dot.layer.cornerRadius = diameter / 2
        dot.backgroundColor = station.isRegistered ? .systemIndigo : .white
        dot.layer.borderColor = (station.isRegistered ? UIColor.white : UIColor.darkGray).cgColor
        dot.layer.borderWidth = 2
        nameLabel.text = station.title
        nameLabel.isHidden = !showsName
        let width = nameLabel.intrinsicContentSize.width + 6
        nameLabel.frame = CGRect(x: bounds.width / 2 + diameter / 2 + 2, y: (bounds.height - 15) / 2, width: width, height: 15)
        displayPriority = station.isRegistered ? .required : .defaultHigh
    }

}

enum MapStationRule {
    /// 駅名を出すかどうか。広域では主要駅(登録した駅、終点、乗換駅)だけ。
    static func showsName(zoom: Int, isMajor: Bool) -> Bool {
        isMajor ? zoom >= 10 : zoom >= 13
    }
}

enum MapBearing {
    /// 2点間の方位(度。北が0、時計回り)
    static func degrees(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double? {
        guard a.latitude != b.latitude || a.longitude != b.longitude else { return nil }
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

import MapKit
import UIKit

/// 駅の点のまわりに重ねる電車の小さなアイコン(停車中と、まもなく着く電車)
struct MapStationTrain {
    let trainID: String
    let coordinate: CLLocationCoordinate2D
    /// 駅の点からのずれ(画面上のpt)
    let offset: CGPoint
    /// 種別の短い文字と、行先の頭文字
    let label: String
    /// 各停以外は角の少ない四角、各停は丸みのある形
    let isExpress: Bool
    /// 遅れの有無の色
    let color: UIColor
    /// 停車中は塗りつぶし、まもなく着く電車は枠だけ
    let isStopped: Bool
    /// この行に入りきらなかった数
    let hiddenCount: Int

    var signature: String {
        "\(trainID)|\(Int(offset.x)),\(Int(offset.y))|\(label)|\(isExpress)|\(color.description)|\(isStopped)|\(hiddenCount)"
    }
}

/// 駅に重ねる電車を、1枚の重ね描きで描く。アイコンごとの部品(アノテーション)を作らないので、数が多くても軽い。
final class StationTrainsOverlay: NSObject, MKOverlay {
    struct Item {
        let point: MKMapPoint
        let train: MapStationTrain
    }

    let items: [Item]
    let coordinate = CLLocationCoordinate2D(latitude: 36.5, longitude: 138)
    let boundingMapRect = MKMapRect.world

    init(trains: [MapStationTrain]) {
        items = trains.map { Item(point: MKMapPoint($0.coordinate), train: $0) }
    }
}

/// 地図のタイルごとに呼ばれ、そのタイルにかかるアイコンだけを描く。大きさは縮尺に関係なく画面上で一定。
final class StationTrainsRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? StationTrainsOverlay else { return }
        let scale = 1 / zoomScale
        let size = StationTrainPlacement.iconSize
        // アイコンは駅の点から最大で約90pt離れるので、その分だけ広げて探す
        let margin = Double(120 * scale)
        let search = mapRect.insetBy(dx: -margin, dy: -margin)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        for item in overlay.items where search.contains(item.point) {
            let base = point(for: item.point)
            let train = item.train
            let center = CGPoint(x: base.x + train.offset.x * scale, y: base.y + train.offset.y * scale)
            let rect = CGRect(x: center.x - size.width * scale / 2, y: center.y - size.height * scale / 2,
                              width: size.width * scale, height: size.height * scale)
            let radius = (train.isExpress ? 3 : size.height / 2) * scale
            let path = UIBezierPath(roundedRect: rect, cornerRadius: radius)
            if train.isStopped {
                train.color.setFill()
                path.fill()
                UIColor.white.setStroke()
                path.lineWidth = 1 * scale
            } else {
                UIColor.white.withAlphaComponent(0.92).setFill()
                path.fill()
                train.color.setStroke()
                path.lineWidth = 1.8 * scale
            }
            path.stroke()
            let font = UIFont.systemFont(ofSize: 9 * scale, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: train.isStopped ? UIColor.white : train.color,
            ]
            let text = train.label as NSString
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            if train.hiddenCount > 0 {
                let more = "+\(train.hiddenCount)" as NSString
                let moreAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 8 * scale, weight: .semibold),
                    .foregroundColor: UIColor.darkGray,
                ]
                let moreSize = more.size(withAttributes: moreAttributes)
                more.draw(at: CGPoint(x: rect.minX - moreSize.width - 2 * scale, y: rect.midY - moreSize.height / 2), withAttributes: moreAttributes)
            }
        }
    }
}

extension MapStationRule {
    /// 駅に電車を重ねる縮尺(これ以上拡大したとき)
    static let stationTrainZoom = 14
}

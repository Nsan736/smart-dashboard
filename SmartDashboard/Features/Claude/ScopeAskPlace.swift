import Foundation

/// Claude の答えの最後の、決まった形の場所(<place>{...}</place>)。特定できないときは座標を持たない。
struct ScopeAskPlace: Codable, Equatable {
    enum Confidence: String, Codable, CaseIterable {
        case high
        case medium
        case low

        var label: String {
            switch self {
            case .high: return "高"
            case .medium: return "中"
            case .low: return "低"
            }
        }
    }

    var identified: Bool
    var name: String
    var latitude: Double?
    var longitude: Double?
    var confidence: Confidence?
    var reason: String

    /// 座標まで分かっているか
    var hasCoordinate: Bool { identified && latitude != nil && longitude != nil }

    static let openTag = "<place>"
    static let closeTag = "</place>"

    /// 答えの文から、決まった形の場所を取り出す。表示する文からは、その部分を消す。
    /// 形が読めないとき、緯度経度が範囲の外のとき、identified が true でも座標がないときは、特定できないとして扱う。
    static func extract(from text: String) -> (answer: String, place: ScopeAskPlace?) {
        guard let open = text.range(of: openTag, options: .backwards),
              let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let body = String(text[open.upperBound..<close.lowerBound])
        var answer = text
        answer.removeSubrange(open.lowerBound..<close.upperBound)
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer, parse(body))
    }

    static func parse(_ json: String) -> ScopeAskPlace? {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let reason = String((raw["reason"] as? String ?? "").prefix(300))
        let name = String((raw["name"] as? String ?? "").prefix(60))
        guard raw["identified"] as? Bool == true else {
            return ScopeAskPlace(identified: false, name: name, latitude: nil, longitude: nil, confidence: nil, reason: reason)
        }
        func number(_ key: String) -> Double? {
            if let value = raw[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { return value.doubleValue }
            if let text = raw[key] as? String { return Double(text) }
            return nil
        }
        guard let latitude = number("latitude"), let longitude = number("longitude"),
              (-90...90).contains(latitude), (-180...180).contains(longitude), !(latitude == 0 && longitude == 0), !name.isEmpty else {
            // 特定したと言っていても、座標がなければ特定できないとして扱う(座標を作らない)
            return ScopeAskPlace(identified: false, name: name, latitude: nil, longitude: nil, confidence: nil,
                                 reason: reason.isEmpty ? "場所の座標がありませんでした" : reason)
        }
        let confidence = (raw["confidence"] as? String).flatMap { Confidence(rawValue: $0.lowercased()) } ?? .low
        return ScopeAskPlace(identified: true, name: name, latitude: latitude, longitude: longitude, confidence: confidence, reason: reason)
    }
}

/// 答えの場所を、撮ったときの位置と向きで確かめる(端末の中だけで計算し、自分の位置は外に送らない)
struct ScopeAskPlaceCheck: Equatable {
    enum Direction: Equatable {
        /// 写る範囲の中
        case inView
        /// 写る範囲の少し外(外れた角度)
        case nearEdge(Double)
        /// 写る範囲から大きく外れている(外れた角度)
        case mismatch(Double)
        /// 撮ったときの位置か向きが分からない
        case unknown
    }

    enum DistanceNote: Equatable {
        case tooClose
        case tooFar
        case normal
        case unknown
    }

    /// 写る範囲からこれ以上外れていたら「撮った方向と合いません」
    static let mismatchDegrees = 30.0
    /// これより近いと、撮った位置とほぼ同じ(目安)
    static let tooCloseMeters = 10.0
    /// これより遠いと、見えている可能性が低い(目安)
    static let tooFarMeters = 250_000.0
    /// 写る範囲が分からないときの、左右の半分(度)
    static let defaultHalfFieldOfView = 30.0

    var bearing: Double?
    var distance: Double?
    var direction: Direction
    var distanceNote: DistanceNote

    static func evaluate(place: ScopeAskPlace, observerLatitude: Double?, observerLongitude: Double?, heading: Double?,
                         halfFieldOfView: Double?) -> ScopeAskPlaceCheck? {
        guard place.hasCoordinate, let latitude = place.latitude, let longitude = place.longitude else { return nil }
        guard let observerLatitude, let observerLongitude else {
            return ScopeAskPlaceCheck(bearing: nil, distance: nil, direction: .unknown, distanceNote: .unknown)
        }
        let bearing = WaypointMath.bearing(fromLatitude: observerLatitude, longitude: observerLongitude, toLatitude: latitude, longitude: longitude)
        let distance = WaypointMath.distance(fromLatitude: observerLatitude, longitude: observerLongitude, toLatitude: latitude, longitude: longitude)
        let note: DistanceNote = distance < tooCloseMeters ? .tooClose : distance > tooFarMeters ? .tooFar : .normal
        var direction = Direction.unknown
        if let heading {
            let half = halfFieldOfView ?? defaultHalfFieldOfView
            let off = abs(WaypointMath.difference(from: heading, to: bearing))
            let outside = max(0, off - half)
            direction = outside == 0 ? .inView : outside >= mismatchDegrees ? .mismatch(outside) : .nearEdge(outside)
        }
        // とても近いときは、方角はあてにならない
        if note == .tooClose { direction = .unknown }
        return ScopeAskPlaceCheck(bearing: bearing, distance: distance, direction: direction, distanceNote: note)
    }

    /// 画面に出す説明(1行ずつ)
    var lines: [String] {
        var lines: [String] = []
        if let bearing, let distance {
            lines.append("ここから \(WaypointMath.compassPoint(bearing))(\(Int(bearing.rounded()))°)、\(WaypointMath.distanceText(distance))")
        }
        switch direction {
        case .inView: lines.append("撮った方向と合っています")
        case .nearEdge(let degrees): lines.append("撮った範囲の少し外です(\(Int(degrees.rounded()))°)")
        case .mismatch(let degrees): lines.append("撮った方向と合いません(写る範囲から\(Int(degrees.rounded()))°外れています)")
        case .unknown: lines.append(distance == nil ? "撮ったときの位置が分からないため、方向を確かめられません" : "撮ったときの向きでは確かめられません")
        }
        switch distanceNote {
        case .tooClose: lines.append("撮った位置とほぼ同じ場所です(目安)")
        case .tooFar: lines.append("とても遠い場所です。見えている可能性は低い(目安)")
        case .normal, .unknown: break
        }
        return lines
    }

    var isWarning: Bool {
        if case .mismatch = direction { return true }
        return distanceNote == .tooFar
    }
}

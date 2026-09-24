import Foundation

/// デバッグの仮想の移動の設定。地図に置いた点(または路線の駅)を結んだ線を、決めた速さで動く。
struct VirtualPlan: Codable, Equatable {
    /// 停車する場所
    struct Stop: Codable, Equatable {
        /// 何番目の点で止まるか
        var pointIndex: Int
        /// 停車時間(仮想の秒)
        var dwell: TimeInterval
        var name: String = ""
    }

    /// GPSなしの区間(点の番号で指定)
    struct Gap: Codable, Equatable {
        var fromIndex: Int
        var toIndex: Int
    }

    var points: [GeoPoint] = []
    /// 速さ(km/h)
    var speedKmh: Double = 60
    /// 時間の倍率(1秒 = ◯秒)
    var timeScale: Double = 1
    var stops: [Stop] = []
    var gaps: [Gap] = []
    /// 位置のばらつき(m)。0ならなし。
    var noiseMeters: Double = 0
    /// 仮想の時刻の開始。nil なら開始したときの時刻。
    var startClock: Date?

    static let timeScales: [Double] = [1, 2, 5, 10, 30, 60]

    var path: GeoPath { GeoPath(points) }

    /// 点を移したり消したりしたあと、範囲の外になった停車とGPSなしの区間を直す
    mutating func normalize() {
        let count = points.count
        stops = stops.filter { $0.pointIndex >= 0 && $0.pointIndex < count }
        var seen = Set<Int>()
        stops = stops.filter { seen.insert($0.pointIndex).inserted }.sorted { $0.pointIndex < $1.pointIndex }
        gaps = gaps.compactMap { gap in
            let low = max(0, min(gap.fromIndex, gap.toIndex))
            let high = min(count - 1, max(gap.fromIndex, gap.toIndex))
            return high > low ? Gap(fromIndex: low, toIndex: high) : nil
        }
    }

    /// 点を1つ消す。後ろの点の番号を詰める。
    mutating func removePoint(at index: Int) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
        stops = stops.filter { $0.pointIndex != index }.map { stop in
            var stop = stop
            if stop.pointIndex > index { stop.pointIndex -= 1 }
            return stop
        }
        gaps = gaps.map { Gap(fromIndex: $0.fromIndex > index ? $0.fromIndex - 1 : $0.fromIndex,
                              toIndex: $0.toIndex >= index ? $0.toIndex - 1 : $0.toIndex) }
        normalize()
    }

    /// 選んだ路線の2駅の間を、線路の線(駅を結んだ線)に沿った経路にする。途中の駅には停車する。
    static func along(line: RideLine, fromStation: Int, toStation: Int, dwell: TimeInterval) -> [GeoPoint]? {
        guard line.stations.indices.contains(fromStation), line.stations.indices.contains(toStation), fromStation != toStation else { return nil }
        let indices = fromStation < toStation ? Array(fromStation...toStation) : Array((toStation...fromStation).reversed())
        return indices.compactMap { line.path.points.indices.contains($0) ? line.path.points[$0] : nil }
    }

    static func stationPlan(line: RideLine, fromStation: Int, toStation: Int, dwell: TimeInterval, base: VirtualPlan) -> VirtualPlan? {
        guard let points = along(line: line, fromStation: fromStation, toStation: toStation, dwell: dwell) else { return nil }
        let indices = fromStation < toStation ? Array(fromStation...toStation) : Array((toStation...fromStation).reversed())
        var plan = base
        plan.points = points
        plan.gaps = []
        // 始発と終点を除く駅で止まる
        plan.stops = []
        for (offset, station) in indices.enumerated() where offset > 0 && offset < indices.count - 1 {
            plan.stops.append(Stop(pointIndex: offset, dwell: dwell, name: line.stations[station].name))
        }
        return plan
    }
}

/// 仮想の移動を1ステップずつ進める。実時間の経過に倍率を掛けた「仮想の秒」で動く。
struct VirtualMover: Equatable {
    let path: GeoPath
    /// 停車する位置(線に沿った距離)と停車時間
    let stops: [(along: Double, dwell: TimeInterval)]
    /// GPSなしの区間(線に沿った距離の範囲)
    let gaps: [ClosedRange<Double>]
    /// 線に沿った位置(m)
    private(set) var along = 0.0
    /// 開始からの仮想の経過秒
    private(set) var virtualElapsed: TimeInterval = 0
    /// 停車中の残り(仮想の秒)
    private(set) var dwellRemaining: TimeInterval = 0
    private var nextStop = 0

    static func == (lhs: VirtualMover, rhs: VirtualMover) -> Bool {
        lhs.path == rhs.path && lhs.along == rhs.along && lhs.virtualElapsed == rhs.virtualElapsed
            && lhs.dwellRemaining == rhs.dwellRemaining && lhs.nextStop == rhs.nextStop && lhs.gaps == rhs.gaps
    }

    init(plan: VirtualPlan) {
        let path = plan.path
        self.path = path
        stops = plan.stops
            .filter { path.cumulative.indices.contains($0.pointIndex) }
            .map { (along: path.cumulative[$0.pointIndex], dwell: max(0, $0.dwell)) }
            .sorted { $0.along < $1.along }
        gaps = plan.gaps.compactMap { gap in
            guard path.cumulative.indices.contains(gap.fromIndex), path.cumulative.indices.contains(gap.toIndex) else { return nil }
            let a = path.cumulative[gap.fromIndex]
            let b = path.cumulative[gap.toIndex]
            return min(a, b)...max(a, b)
        }
        // 始点にある停車は使わない
        while nextStop < stops.count, stops[nextStop].along <= 0 { nextStop += 1 }
    }

    var isFinished: Bool { along >= path.length && dwellRemaining <= 0 }
    var isStopped: Bool { dwellRemaining > 0 }
    var isInGap: Bool { gaps.contains { $0.contains(along) } }
    var position: GeoPoint? { path.point(atAlong: along) }

    /// 実時間で realSeconds だけ進める。speedKmh と timeScale は、動かしながら変えられる。
    mutating func advance(realSeconds: TimeInterval, speedKmh: Double, timeScale: Double) {
        var remaining = max(0, realSeconds) * max(0, timeScale)
        virtualElapsed += remaining
        let speed = max(0.1, speedKmh) / 3.6
        var guardCount = 0
        while remaining > 0, guardCount < 1000 {
            guardCount += 1
            if dwellRemaining > 0 {
                let used = min(dwellRemaining, remaining)
                dwellRemaining -= used
                remaining -= used
                continue
            }
            if along >= path.length { break }
            let target = nextStop < stops.count ? min(stops[nextStop].along, path.length) : path.length
            let time = (target - along) / speed
            // 36 / 3.6 のような割り算の誤差で、停車位置にわずかに届かないことがないようにする
            if time <= remaining + 1e-6 {
                along = target
                remaining = max(0, remaining - time)
                if nextStop < stops.count, abs(stops[nextStop].along - target) < 0.001 {
                    dwellRemaining = stops[nextStop].dwell
                    nextStop += 1
                }
            } else {
                along += speed * remaining
                remaining = 0
            }
        }
    }

    /// 今の位置の測位の結果。GPSなしの区間では nil。noise は東・北へのずれ(m)。
    func sample(at time: Date, noise: (east: Double, north: Double) = (0, 0), accuracy: Double, speedKmh: Double) -> RideSample? {
        guard !isInGap, let point = position else { return nil }
        let moved = GeoMath.offset(point, east: noise.east, north: noise.north)
        return RideSample(time: time, point: moved, accuracy: accuracy, speed: isStopped || isFinished ? 0 : speedKmh / 3.6)
    }

    /// 半径 meters の円の中の、ばらつきの量
    static func noise<G: RandomNumberGenerator>(meters: Double, using generator: inout G) -> (east: Double, north: Double) {
        guard meters > 0 else { return (0, 0) }
        let angle = Double.random(in: 0..<(2 * .pi), using: &generator)
        let radius = meters * Double.random(in: 0...1, using: &generator).squareRoot()
        return (radius * cos(angle), radius * sin(angle))
    }
}

/// GPXの再生。記録した時刻の間隔を保ち、時間の倍率で早送りする。
struct GPXReplay: Equatable {
    let samples: [RideSample]
    /// 開始からの仮想の経過秒
    private(set) var virtualElapsed: TimeInterval = 0
    private(set) var nextIndex = 0

    init(samples: [RideSample]) {
        self.samples = samples.sorted { $0.time < $1.time }
    }

    var firstTime: Date? { samples.first?.time }
    var duration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.time.timeIntervalSince(first.time)
    }
    var isFinished: Bool { nextIndex >= samples.count }

    /// 進めて、その間に届く点を返す。点の時刻は、仮想の時刻の開始(clockStart)に合わせて付け直す。
    mutating func advance(realSeconds: TimeInterval, timeScale: Double, clockStart: Date) -> [RideSample] {
        guard let first = samples.first else { return [] }
        virtualElapsed += max(0, realSeconds) * max(0, timeScale)
        var result: [RideSample] = []
        while nextIndex < samples.count, samples[nextIndex].time.timeIntervalSince(first.time) <= virtualElapsed {
            var sample = samples[nextIndex]
            sample.time = clockStart.addingTimeInterval(sample.time.timeIntervalSince(first.time))
            result.append(sample)
            nextIndex += 1
        }
        return result
    }
}

/// 仮想の時刻。倍率を掛けて進み、一時停止の間は止まる。
struct VirtualClock: Equatable {
    var start: Date
    private(set) var elapsed: TimeInterval = 0

    init(start: Date) {
        self.start = start
    }

    var now: Date { start.addingTimeInterval(elapsed) }

    mutating func advance(realSeconds: TimeInterval, timeScale: Double) {
        elapsed += max(0, realSeconds) * max(0, timeScale)
    }

    /// 指定した日の hour:minute を、仮想の時刻の開始にする(例: 平日の8時)
    static func start(on day: Date, hour: Int, minute: Int, calendar: Calendar = JapaneseHolidays.calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }
}

// MARK: - GPX

/// GPX 1.1 の書き出しと読み込み。精度と速さは、このアプリの拡張の要素に入れる(ほかのアプリでは無視される)。
enum GPXCodec {
    static let namespace = "https://github.com/Nsan736/smart-dashboard/gpx/1"

    struct Track: Equatable {
        var name: String
        var samples: [RideSample]
    }

    static func write(name: String, samples: [RideSample], rides: [MovementRide] = []) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<gpx version=\"1.1\" creator=\"SmartDashboard\" xmlns=\"http://www.topografix.com/GPX/1/1\" xmlns:sd=\"\(namespace)\">")
        lines.append("  <trk>")
        lines.append("    <name>\(escape(name))</name>")
        if !rides.isEmpty {
            let text = rides.map { "\(formatter.string(from: $0.start)) - \(formatter.string(from: $0.end)) \($0.railwayName) \($0.trainLabel ?? "")" }
            lines.append("    <desc>\(escape("乗車と判定した区間: " + text.joined(separator: " / ")))</desc>")
        }
        lines.append("    <trkseg>")
        for sample in samples {
            var point = "      <trkpt lat=\"\(String(format: "%.7f", sample.latitude))\" lon=\"\(String(format: "%.7f", sample.longitude))\">"
            point += "<time>\(formatter.string(from: sample.time))</time>"
            var extensions = ""
            if sample.accuracy >= 0 { extensions += "<sd:acc>\(String(format: "%.1f", sample.accuracy))</sd:acc>" }
            if sample.speed >= 0 { extensions += "<sd:spd>\(String(format: "%.2f", sample.speed))</sd:spd>" }
            if !extensions.isEmpty { point += "<extensions>\(extensions)</extensions>" }
            point += "</trkpt>"
            lines.append(point)
        }
        lines.append("    </trkseg>")
        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// 読み込む。trkpt(なければ rtept、wpt)の緯度経度と時刻を使う。時刻がない点は1秒間隔とみなす。読めなければ nil。
    static func parse(_ data: Data) -> Track? {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        var points = delegate.trackPoints
        if points.isEmpty { points = delegate.routePoints }
        if points.isEmpty { points = delegate.wayPoints }
        guard !points.isEmpty else { return nil }
        let base = points.compactMap(\.time).first ?? Date()
        var samples: [RideSample] = []
        for (index, point) in points.enumerated() {
            let time = point.time ?? base.addingTimeInterval(Double(index))
            samples.append(RideSample(time: time, latitude: point.latitude, longitude: point.longitude,
                                      accuracy: point.accuracy ?? -1, speed: point.speed ?? -1))
        }
        return Track(name: delegate.name ?? "", samples: samples.sorted { $0.time < $1.time })
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private struct ParsedPoint {
        var latitude: Double
        var longitude: Double
        var time: Date?
        var accuracy: Double?
        var speed: Double?
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var trackPoints: [ParsedPoint] = []
        var routePoints: [ParsedPoint] = []
        var wayPoints: [ParsedPoint] = []
        var name: String?
        private var current: ParsedPoint?
        private var currentKind = ""
        private var text = ""
        private var depthInTrack = false
        private let formatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let plainFormatter = ISO8601DateFormatter()

        private static func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let name = Self.localName(elementName)
            text = ""
            if name == "trk" { depthInTrack = true }
            if name == "trkpt" || name == "rtept" || name == "wpt" {
                guard let lat = attributeDict["lat"].flatMap(Double.init), let lon = attributeDict["lon"].flatMap(Double.init),
                      (-90...90).contains(lat), (-180...180).contains(lon) else {
                    current = nil
                    return
                }
                current = ParsedPoint(latitude: lat, longitude: lon)
                currentKind = name
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let name = Self.localName(elementName)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "time":
                current?.time = formatter.date(from: value) ?? plainFormatter.date(from: value)
            case "acc":
                current?.accuracy = Double(value)
            case "spd", "speed":
                current?.speed = Double(value)
            case "name":
                if current == nil, depthInTrack, self.name == nil { self.name = value }
            case "trkpt", "rtept", "wpt":
                if let point = current, currentKind == name {
                    switch name {
                    case "trkpt": trackPoints.append(point)
                    case "rtept": routePoints.append(point)
                    default: wayPoints.append(point)
                    }
                }
                current = nil
            case "trk":
                depthInTrack = false
            default:
                break
            }
            text = ""
        }
    }
}

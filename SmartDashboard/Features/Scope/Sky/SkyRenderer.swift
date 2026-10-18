import SwiftUI

/// カメラ表示に描く、1日分の太陽と月(通り道、出入り、本当の日の出入り)。日付か場所が変わったときだけ作る
struct SkyScene: Equatable {
    var day: Date
    var latitude: Double
    var longitude: Double
    var sunPath: [SkyEvents.PathPoint]
    var moonPath: [SkyEvents.PathPoint]
    var sunRise: SkyEvent?
    var sunSet: SkyEvent?
    var moonRise: SkyEvent?
    var moonSet: SkyEvent?
    /// 景色の稜線に隠れる・出てくる時刻(稜線がなければ nil)
    var terrainSunRise: SkyEvent?
    var terrainSunSet: SkyEvent?
    var hasTerrain: Bool

    /// 作る(稜線は、景色を計算していればその値。horizon(方角) が見える高さ)
    static func make(day: Date, latitude: Double, longitude: Double, horizon: ((Double) -> Double?)?) -> SkyScene {
        let sun = SkyEvents.riseSet(.sun, on: day, latitude: latitude, longitude: longitude)
        let moon = SkyEvents.riseSet(.moon, on: day, latitude: latitude, longitude: longitude)
        var scene = SkyScene(day: SkyEvents.startOfDay(day), latitude: latitude, longitude: longitude,
                             sunPath: SkyEvents.path(.sun, on: day, latitude: latitude, longitude: longitude),
                             moonPath: SkyEvents.path(.moon, on: day, latitude: latitude, longitude: longitude),
                             sunRise: sun.rise, sunSet: sun.set, moonRise: moon.rise, moonSet: moon.set,
                             terrainSunRise: nil, terrainSunSet: nil, hasTerrain: horizon != nil)
        if let horizon {
            let terrain = SkyEvents.terrainRiseSet(.sun, on: day, latitude: latitude, longitude: longitude, horizon: horizon)
            scene.terrainSunRise = terrain.rise
            scene.terrainSunSet = terrain.set
        }
        return scene
    }

    /// 日の入りの文(「山に沈む 16:42(地平線では 16:55)」)
    func sunsetText() -> String? {
        guard let set = sunSet else { return nil }
        let horizon = SkyText.time(set.date)
        guard hasTerrain, let terrain = terrainSunSet, set.date.timeIntervalSince(terrain.date) > 30 else { return "日の入り \(horizon)" }
        return "山に沈む \(SkyText.time(terrain.date))(地平線では \(horizon))"
    }

    func sunriseText() -> String? {
        guard let rise = sunRise else { return nil }
        let horizon = SkyText.time(rise.date)
        guard hasTerrain, let terrain = terrainSunRise, terrain.date.timeIntervalSince(rise.date) > 30 else { return "日の出 \(horizon)" }
        return "山から出る \(SkyText.time(terrain.date))(地平線では \(horizon))"
    }
}

enum SkyText {
    /// 時刻(分に四捨五入。暦計算室の表と同じ)
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = Calendar.japan.timeZone
        formatter.dateFormat = "H:mm"
        return formatter.string(from: date.addingTimeInterval(30))
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = Calendar.japan.timeZone
        formatter.dateFormat = "yyyy/M/d(E) H:mm"
        return formatter.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = Calendar.japan.timeZone
        formatter.dateFormat = "M/d(E)"
        return formatter.string(from: date)
    }

    static func phase(_ phase: Astronomy.MoonPhase) -> String {
        let percent = Int((phase.illumination * 100).rounded())
        let name: String
        switch phase.age {
        case ..<1.5, 28...: name = "新月のころ"
        case ..<6: name = "三日月のころ"
        case ..<9: name = "上弦のころ"
        case ..<13.5: name = "十三夜のころ"
        case ..<16: name = "満月のころ"
        case ..<21: name = "居待月のころ"
        case ..<24: name = "下弦のころ"
        default: name = "有明月のころ"
        }
        return "\(name)(輝いている部分 \(percent)%・月齢 \(String(format: "%.1f", phase.age)))"
    }
}

/// 太陽と月の描き方(地点と同じ投影 `ScopeTrainRenderer.project`)
enum SkyRenderer {
    static let sunColor = Color(red: 1.0, green: 0.78, blue: 0.2)
    static let moonColor = Color(red: 0.92, green: 0.93, blue: 1.0)

    /// 方角・高さの向き(基準の座標系 x=北、y=西、z=上)
    static func vector(azimuth: Double, altitude: Double) -> Vector3 {
        let a = azimuth * Astronomy.degree, h = altitude * Astronomy.degree
        return Vector3(x: cos(h) * cos(a), y: -cos(h) * sin(a), z: sin(h))
    }

    static func project(azimuth: Double, altitude: Double, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double),
                        size: CGSize) -> CGPoint? {
        ScopeTrainRenderer.project(vector(azimuth: azimuth, altitude: altitude), attitude: attitude, tangents: tangents, size: size)
    }

    /// 通り道の線。地平線より下の部分は別の線(薄く描く)
    static func paths(_ points: [SkyEvents.PathPoint], attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double),
                      size: CGSize) -> (above: Path, below: Path) {
        var above = Path(), below = Path()
        var previous: (point: CGPoint, isAbove: Bool)?
        for item in points {
            guard let point = project(azimuth: item.azimuth, altitude: item.apparentAltitude, attitude: attitude, tangents: tangents, size: size),
                  abs(point.x) < size.width * 3, abs(point.y) < size.height * 3 else {
                previous = nil
                continue
            }
            let isAbove = item.apparentAltitude >= 0
            if let previous, previous.isAbove == isAbove {
                if isAbove { above.addLine(to: point) } else { below.addLine(to: point) }
            } else {
                if isAbove { above.move(to: point) } else { below.move(to: point) }
                if let previous {
                    // 地平線をまたぐ所は、上の線を地平線まで伸ばす
                    if isAbove { above.addLine(to: point); above.move(to: previous.point) } else { below.move(to: previous.point); below.addLine(to: point) }
                }
            }
            previous = (point, isAbove)
        }
        return (above, below)
    }

    /// 月の輝いている部分の形(中心 center、半径 r、太陽の向き(画面の角度、右が0で時計回り) angle)
    static func moonLitPath(center: CGPoint, radius r: CGFloat, illumination: Double, towardSun angle: Double) -> Path {
        let e = 2 * illumination - 1
        var path = Path()
        let steps = 24
        // 太陽の側の半円(上から下へ)
        for i in 0...steps {
            let y = -r + 2 * r * CGFloat(i) / CGFloat(steps)
            let x = sqrt(max(r * r - y * y, 0))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        // 明暗の境目(下から上へ)
        for i in (0...steps).reversed() {
            let y = -r + 2 * r * CGFloat(i) / CGFloat(steps)
            let x = -CGFloat(e) * sqrt(max(r * r - y * y, 0))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(angle))
        return path.applying(transform)
    }

    struct DrawInput {
        var scene: SkyScene
        /// 描く時刻(指で時刻をずらしているときは、その時刻)
        var time: Date
    }

    static func draw(_ context: inout GraphicsContext, input: DrawInput, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double),
                     size: CGSize) {
        let scene = input.scene
        let latitude = scene.latitude, longitude = scene.longitude
        // 通り道と1時間ごとの印
        for (points, color) in [(scene.sunPath, sunColor), (scene.moonPath, moonColor)] {
            let lines = paths(points, attitude: attitude, tangents: tangents, size: size)
            context.stroke(lines.above, with: .color(color.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            context.stroke(lines.below, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            for point in points where point.isHour {
                guard let p = project(azimuth: point.azimuth, altitude: point.apparentAltitude, attitude: attitude, tangents: tangents, size: size),
                      CGRect(origin: .zero, size: size).contains(p) else { continue }
                let faded = point.apparentAltitude < 0
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(color.opacity(faded ? 0.3 : 0.9)))
                let hour = Calendar.japan.component(.hour, from: point.date)
                let label = context.resolve(Text("\(hour)時").font(.system(size: 10, weight: .semibold)).foregroundColor(color.opacity(faded ? 0.4 : 1)))
                context.draw(label, at: CGPoint(x: p.x + 10, y: p.y - 7), anchor: .leading)
            }
        }
        // 出入りの方角(地平線の上の印)
        let events: [(SkyEvent?, String, Color)] = [
            (scene.sunRise, "日の出", sunColor), (scene.sunSet, "日の入り", sunColor),
            (scene.moonRise, "月の出", moonColor), (scene.moonSet, "月の入り", moonColor),
            (scene.terrainSunRise, "山から出る", sunColor), (scene.terrainSunSet, "山に沈む", sunColor),
        ]
        for (event, name, color) in events {
            guard let event, let p = project(azimuth: event.azimuth, altitude: 0, attitude: attitude, tangents: tangents, size: size),
                  CGRect(origin: .zero, size: size).contains(p) else { continue }
            var mark = Path()
            mark.move(to: CGPoint(x: p.x, y: p.y - 10))
            mark.addLine(to: CGPoint(x: p.x - 5, y: p.y))
            mark.addLine(to: CGPoint(x: p.x + 5, y: p.y))
            mark.closeSubpath()
            context.fill(mark, with: .color(color))
            let label = context.resolve(Text("\(name) \(SkyText.time(event.date))").font(.system(size: 11, weight: .bold)).foregroundColor(.white))
            let measured = label.measure(in: CGSize(width: 160, height: 30))
            let rect = CGRect(x: p.x - measured.width / 2 - 4, y: p.y + 4, width: measured.width + 8, height: measured.height + 2)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color.black.opacity(0.55)))
            context.draw(label, in: rect.insetBy(dx: 4, dy: 1))
        }
        // 今(または選んだ時刻)の太陽と月
        let sun = Astronomy.sunHorizontal(input.time, latitude: latitude, longitude: longitude)
        let moon = Astronomy.moonHorizontal(input.time, latitude: latitude, longitude: longitude)
        let perDegree = WaypointProjection.pointsPerDegree(tangents: tangents, viewSize: size).vertical
        if let p = project(azimuth: sun.azimuth, altitude: sun.apparentAltitude, attitude: attitude, tangents: tangents, size: size) {
            let r = max(CGFloat(Astronomy.sunSemidiameter(input.time) * perDegree), 7)
            let faded = sun.apparentAltitude < 0
            context.fill(Path(ellipseIn: CGRect(x: p.x - r * 1.8, y: p.y - r * 1.8, width: r * 3.6, height: r * 3.6)),
                         with: .color(sunColor.opacity(faded ? 0.08 : 0.25)))
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(sunColor.opacity(faded ? 0.35 : 1)))
            drawCaption(&context, "太陽 高さ\(Int(sun.apparentAltitude.rounded()))°", at: CGPoint(x: p.x, y: p.y + r + 10))
        }
        if let p = project(azimuth: moon.azimuth, altitude: moon.apparentAltitude, attitude: attitude, tangents: tangents, size: size) {
            let r = max(CGFloat(Astronomy.moonSemidiameter(input.time) * perDegree), 7)
            let phase = Astronomy.moonPhase(input.time)
            let faded = moon.apparentAltitude < 0
            // 太陽の向き(画面の上で): 月から太陽へ少し進んだ点を投影する
            let m = vector(azimuth: moon.azimuth, altitude: moon.apparentAltitude)
            let s = vector(azimuth: sun.azimuth, altitude: sun.apparentAltitude)
            let toward = Vector3(x: m.x + (s.x - m.x) * 0.02, y: m.y + (s.y - m.y) * 0.02, z: m.z + (s.z - m.z) * 0.02)
            var angle = phase.isWaxing ? 0.0 : Double.pi
            if let q = ScopeTrainRenderer.project(toward, attitude: attitude, tangents: tangents, size: size) {
                angle = atan2(Double(q.y - p.y), Double(q.x - p.x))
            }
            context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Color.gray.opacity(faded ? 0.15 : 0.35)))
            context.fill(moonLitPath(center: p, radius: r, illumination: phase.illumination, towardSun: angle),
                         with: .color(moonColor.opacity(faded ? 0.35 : 1)))
            drawCaption(&context, "月 高さ\(Int(moon.apparentAltitude.rounded()))°・\(Int((phase.illumination * 100).rounded()))%",
                        at: CGPoint(x: p.x, y: p.y + r + 10))
        }
    }

    static func drawCaption(_ context: inout GraphicsContext, _ text: String, at point: CGPoint) {
        let label = context.resolve(Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(.white))
        let measured = label.measure(in: CGSize(width: 200, height: 30))
        let rect = CGRect(x: point.x - measured.width / 2 - 4, y: point.y, width: measured.width + 8, height: measured.height + 2)
        context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color.black.opacity(0.5)))
        context.draw(label, in: rect.insetBy(dx: 4, dy: 1))
    }
}

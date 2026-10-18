import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SmartDashboard

/// 太陽と月の計算。国立天文台 暦計算室の公表値(東京: 緯度35.6581° 経度139.7414°、2026年)と比べる
final class SkyTests: XCTestCase {
    private let latitude = 35.6581
    private let longitude = 139.7414

    private func jst(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.japan.date(from: components) ?? Date()
    }

    /// 公表値(分まで)との差(秒)
    private func assertTime(_ date: Date?, _ hour: Int, _ minute: Int, on day: Date, tolerance: TimeInterval = 60,
                            _ message: String, line: UInt = #line) {
        guard let date else { return XCTFail("時刻がない \(message)", line: line) }
        let expected = SkyEvents.startOfDay(day).addingTimeInterval(Double(hour * 3600 + minute * 60))
        let difference = date.timeIntervalSince(expected)
        XCTAssertLessThanOrEqual(abs(difference), tolerance, "\(message) 差 \(Int(difference))秒", line: line)
    }

    func testSunriseSunsetMatchNAOJ() {
        // (月, 日, 日の出, 方位, 日の入り, 方位)
        let table: [(Int, Int, (Int, Int), Double, (Int, Int), Double)] = [
            (6, 1, (4, 27), 61.9, (18, 51), 298.3),
            (6, 21, (4, 25), 60.0, (19, 0), 300.0),
            (6, 30, (4, 28), 60.3, (19, 1), 299.6),
            (12, 1, (6, 32), 116.4, (16, 28), 243.5),
            (12, 22, (6, 47), 118.6, (16, 32), 241.4),
            (12, 31, (6, 50), 118.2, (16, 37), 241.8),
        ]
        for row in table {
            let day = jst(2026, row.0, row.1)
            let events = SkyEvents.riseSet(.sun, on: day, latitude: latitude, longitude: longitude)
            assertTime(events.rise?.date, row.2.0, row.2.1, on: day, "日の出 \(row.0)/\(row.1)")
            assertTime(events.set?.date, row.4.0, row.4.1, on: day, "日の入り \(row.0)/\(row.1)")
            XCTAssertEqual(events.rise?.azimuth ?? 0, row.3, accuracy: 0.2, "日の出の方位 \(row.0)/\(row.1)")
            XCTAssertEqual(events.set?.azimuth ?? 0, row.5, accuracy: 0.2, "日の入りの方位 \(row.0)/\(row.1)")
        }
    }

    func testMoonriseMoonsetMatchNAOJ() {
        // (日, 月の出, 月の入り) 2026年6月
        let table: [(Int, (Int, Int), (Int, Int))] = [
            (1, (20, 1), (4, 28)), (10, (0, 30), (13, 22)), (16, (5, 1), (20, 28)), (22, (12, 0), (23, 47)), (27, (17, 0), (1, 45)),
        ]
        for row in table {
            let day = jst(2026, 6, row.0)
            let events = SkyEvents.riseSet(.moon, on: day, latitude: latitude, longitude: longitude)
            assertTime(events.rise?.date, row.1.0, row.1.1, on: day, "月の出 6/\(row.0)")
            assertTime(events.set?.date, row.2.0, row.2.1, on: day, "月の入り 6/\(row.0)")
        }
    }

    func testMoonPhase() {
        // 暦計算室の月齢: 6/15 正午 0.0(新月)、6/22 7.0(上弦のころ)、6/30 15.0(満月のころ)
        let newMoon = Astronomy.moonPhase(jst(2026, 6, 15, 12))
        XCTAssertLessThan(newMoon.illumination, 0.01)
        let quarter = Astronomy.moonPhase(jst(2026, 6, 22, 12))
        XCTAssertEqual(quarter.illumination, 0.5, accuracy: 0.08)
        XCTAssertTrue(quarter.isWaxing)
        XCTAssertEqual(quarter.age, 7.0, accuracy: 1.0)
        let full = Astronomy.moonPhase(jst(2026, 6, 30, 12))
        XCTAssertGreaterThan(full.illumination, 0.98)
        XCTAssertTrue(SkyText.phase(full).contains("満月"))
    }

    func testSunPositionAndSolstice() {
        // 南中のころの高さ(暦計算室: 6/21 11:43 に 77.8°、12/22 11:39 に 30.9°)
        let summer = Astronomy.sunHorizontal(jst(2026, 6, 21, 11, 43), latitude: latitude, longitude: longitude)
        XCTAssertEqual(summer.altitude, 77.8, accuracy: 0.15)
        XCTAssertEqual(summer.azimuth, 180, accuracy: 2)
        let winter = Astronomy.sunHorizontal(jst(2026, 12, 22, 11, 39), latitude: latitude, longitude: longitude)
        XCTAssertEqual(winter.altitude, 30.9, accuracy: 0.15)
        // 夏至・冬至(2026年は 6/21 17:24、12/22 5:50)
        let june = SkyEvents.solstice(year: 2026, summer: true)
        XCTAssertEqual(june?.timeIntervalSince(jst(2026, 6, 21, 17, 24)) ?? 99_999, 0, accuracy: 1800)
        let december = SkyEvents.solstice(year: 2026, summer: false)
        XCTAssertEqual(december?.timeIntervalSince(jst(2026, 12, 22, 5, 50)) ?? 99_999, 0, accuracy: 1800)
        // 大気の屈折: 地平線で約0.5°、高いところでは小さい
        XCTAssertEqual(Astronomy.refraction(altitude: 0), 0.48, accuracy: 0.05)
        XCTAssertLessThan(Astronomy.refraction(altitude: 45), 0.02)
    }

    func testTerrainSunsetIsBeforeHorizonSunset() {
        let day = jst(2026, 12, 22)
        let horizon = SkyEvents.riseSet(.sun, on: day, latitude: latitude, longitude: longitude)
        // 西に高さ2°の山並み(東は平ら)
        let terrain = SkyEvents.terrainRiseSet(.sun, on: day, latitude: latitude, longitude: longitude) { bearing in
            bearing > 180 ? 2.0 : 0.0
        }
        let setGap = (horizon.set?.date ?? Date()).timeIntervalSince(terrain.set?.date ?? Date())
        XCTAssertGreaterThan(setGap, 5 * 60)
        XCTAssertLessThan(setGap, 25 * 60)
        // 東が平らなら、出る時刻は地平線とほぼ同じ(屈折の扱いの差の分だけ)
        let riseGap = (terrain.rise?.date ?? Date()).timeIntervalSince(horizon.rise?.date ?? Date())
        XCTAssertLessThan(abs(riseGap), 120)
        // 稜線が分からない方角だけなら、求めない
        let unknown = SkyEvents.terrainRiseSet(.sun, on: day, latitude: latitude, longitude: longitude) { _ in nil }
        XCTAssertNil(unknown.set)
        // 文
        let scene = SkyScene.make(day: day, latitude: latitude, longitude: longitude) { bearing in bearing > 180 ? 2.0 : 0.0 }
        XCTAssertTrue(scene.sunsetText()?.hasPrefix("山に沈む") ?? false)
        XCTAssertTrue(scene.sunsetText()?.contains("地平線では 16:32") ?? false)
        let flat = SkyScene.make(day: day, latitude: latitude, longitude: longitude, horizon: nil)
        XCTAssertEqual(flat.sunsetText(), "日の入り 16:32")
        XCTAssertEqual(flat.sunPath.count, 145)
        XCTAssertEqual(flat.sunPath.filter(\.isHour).count, 25)
    }

    func testDiamondFujiFromShinjuku() {
        // 新宿(35.6896, 139.6917、目の高さ40m)から富士山(剣ヶ峰 35.3606, 138.7274, 3776m)
        let observer = (latitude: 35.6896, longitude: 139.6917, eye: 40.0)
        let peak = (latitude: 35.3606, longitude: 138.7274, elevation: 3776.0)
        let bearing = WaypointMath.bearing(fromLatitude: observer.latitude, longitude: observer.longitude, toLatitude: peak.latitude, longitude: peak.longitude)
        let distance = WaypointMath.distance(fromLatitude: observer.latitude, longitude: observer.longitude, toLatitude: peak.latitude, longitude: peak.longitude)
        let angle = WaypointElevation.angle(targetAltitude: peak.elevation, observerAltitude: observer.eye, distance: distance)
        XCTAssertEqual(bearing, 247.5, accuracy: 0.2)
        XCTAssertEqual(angle, 1.89, accuracy: 0.05)
        let found = SummitAlignmentSearch.search(.sun, from: jst(2026, 11, 1), days: 20, latitude: observer.latitude, longitude: observer.longitude,
                                                 peakBearing: bearing, peakAngle: angle)
        XCTAssertFalse(found.isEmpty)
        for item in found {
            XCTAssertFalse(item.isRising)
            XCTAssertLessThanOrEqual(item.separation, SummitAlignmentSearch.tolerance)
            let day = Calendar.japan.component(.day, from: item.date)
            XCTAssertTrue((8...11).contains(day), "11/\(day)")
            XCTAssertEqual(Calendar.japan.component(.hour, from: item.date), 16)
        }
        // 1年分(太陽と月)の計算時間(シミュレーターでの値。iPhone SE 第2世代では数倍の見込み)
        let began = Date()
        let year = SummitAlignmentSearch.search(.sun, from: jst(2026, 10, 19), days: 365, latitude: observer.latitude, longitude: observer.longitude,
                                                peakBearing: bearing, peakAngle: angle)
            + SummitAlignmentSearch.search(.moon, from: jst(2026, 10, 19), days: 365, latitude: observer.latitude, longitude: observer.longitude,
                                           peakBearing: bearing, peakAngle: angle)
        let elapsed = Date().timeIntervalSince(began)
        print("ダイヤモンド富士の1年分の計算: \(String(format: "%.3f", elapsed))秒、\(year.count)件")
        XCTAssertTrue(year.contains { $0.body == .sun })
        XCTAssertLessThan(elapsed, 10)
        // 途中でやめられる
        var calls = 0
        let stopped = SummitAlignmentSearch.search(.sun, from: jst(2026, 10, 19), days: 365, latitude: observer.latitude, longitude: observer.longitude,
                                                   peakBearing: bearing, peakAngle: angle) { _ in
            calls += 1
            return calls < 2
        }
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertEqual(SummitAlignmentSearch.separation(azimuth: 10, altitude: 0, azimuth: 11, altitude: 0), 1, accuracy: 1e-9)
    }

    func testMoonLitShape() {
        let center = CGPoint(x: 100, y: 100)
        let full = SkyRenderer.moonLitPath(center: center, radius: 10, illumination: 1, towardSun: 0).boundingRect
        XCTAssertEqual(full.width, 20, accuracy: 0.5)
        let half = SkyRenderer.moonLitPath(center: center, radius: 10, illumination: 0.5, towardSun: 0).boundingRect
        XCTAssertEqual(half.width, 10, accuracy: 0.5)
        XCTAssertEqual(half.minX, 100, accuracy: 0.5)
        // 太陽が左にあれば、輝く側も左
        let left = SkyRenderer.moonLitPath(center: center, radius: 10, illumination: 0.5, towardSun: .pi).boundingRect
        XCTAssertEqual(left.maxX, 100, accuracy: 0.5)
    }
}

/// 写真からオブジェクトを作る
final class ObjectPhotoTests: XCTestCase {
    private func jpegWithLocation() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 35.68, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 139.76, kCGImagePropertyGPSLongitudeRef: "E"]
        let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyOrientation: 6]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testLocationIsRemovedAndOrientationApplied() throws {
        let original = try jpegWithLocation()
        XCTAssertTrue(ObjectPhotoImage.hasLocation(original))
        let image = try XCTUnwrap(ObjectPhotoImage.load(original))
        // 向き(6 = 右に90°回す)を直すので、縦長になる
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 400)
        let sent = try XCTUnwrap(ObjectPhotoImage.prepare(image, shape: nil))
        XCTAssertFalse(ObjectPhotoImage.hasLocation(sent))
        // 長い辺を縮める
        let small = try XCTUnwrap(ObjectPhotoImage.load(original, maxEdge: 200))
        XCTAssertEqual(max(small.width, small.height), 200)
    }

    func testDimensionsAndMessages() {
        XCTAssertEqual(ObjectPhotoImage.dimensionsText(height: "10", width: "4.5", depth: ""), "高さ 10m、幅 4.50m")
        XCTAssertEqual(ObjectPhotoImage.dimensionsText(height: "", width: "abc", depth: "0"), "")
        XCTAssertEqual(ObjectPhotoImage.dimensionsText(height: "3,5", width: "", depth: "2"), "高さ 3.50m、奥行き 2m")
        let messages = ObjectGenerator.photoMessages(images: [Data([1]), Data([2])], description: "白い家", dimensions: "高さ 8m",
                                                     detail: .detailed)
        XCTAssertEqual(messages.count, 1)
        let content = messages[0].content
        XCTAssertEqual(content.count, 3)
        guard case .text(let text, _) = content[2] else { return XCTFail("文がない") }
        XCTAssertTrue(text.contains("2枚の写真"))
        XCTAssertTrue(text.contains("寸法の指定: 高さ 8m"))
        XCTAssertTrue(text.contains("説明: 白い家"))
        XCTAssertTrue(ObjectGenerator.photoSystemPrompt.contains("+y がオブジェクトの正面"))
        XCTAssertTrue(ObjectGenerator.photoSystemPrompt.contains("(見積もり)"))
        // 料金の目安: 画像の分だけ高い
        let none = ObjectGenerator.estimatedPhotoCost(detail: .normal, imageSizes: [])
        let three = ObjectGenerator.estimatedPhotoCost(detail: .normal, imageSizes: Array(repeating: (width: 1024, height: 768), count: 3))
        XCTAssertGreaterThan(three, none)
    }

    func testPhotoRecordRoundTrip() throws {
        let json = #"{"format":1,"type":"scope-object","name":"家","shapes":[{"kind":"box"}]}"#
        let outcome = ObjectGenerator.Outcome(object: nil, json: json, issues: [], usage: ClaudeUsage(input: 1, output: 1), cost: 0.01,
                                              attempts: 1, detail: .normal)
        let record = ObjectComposeRecord(outcome: outcome, instruction: "写真から作成", webSearch: false,
                                         createdAt: Date(timeIntervalSince1970: 1_000_000), photoCount: 2, inputDimensions: "高さ 8m")
        let decoded = ClaudeRecentList.decode(ClaudeRecentList.encode([record]), as: ObjectComposeRecord.self)
        XCTAssertEqual(decoded.first?.photoCount, 2)
        XCTAssertEqual(decoded.first?.inputDimensions, "高さ 8m")
        XCTAssertNotNil(decoded.first?.outcome.object)
    }

    @MainActor
    func testPhotoJobKeepsInputs() throws {
        let name = "ObjectPhotoTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString)").appendingPathComponent("objects.json")
        let job = ObjectComposeJob(defaults: defaults, fileURL: url)
        job.photoHeight = "12"
        job.photoNote = "赤い屋根"
        let original = try jpegWithLocation()
        let image = try XCTUnwrap(ObjectPhotoImage.load(original))
        for _ in 0..<4 { job.addPhoto(image) }
        XCTAssertEqual(job.photos.count, ObjectPhotoImage.maxPhotos)
        job.setShape([CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 10), CGPoint(x: 200, y: 300)], for: job.photos[0].id)
        XCTAssertNotNil(job.photos[0].shape)
        XCTAssertEqual(job.photoDimensionsText, "高さ 12m")
        XCTAssertGreaterThan(job.photoEstimatedCost, 0)
        job.removePhoto(job.photos[1].id)
        XCTAssertEqual(job.photos.count, 2)
        let reopened = ObjectComposeJob(defaults: defaults, fileURL: url)
        XCTAssertEqual(reopened.photoHeight, "12")
        XCTAssertEqual(reopened.photoNote, "赤い屋根")
        // 写真そのものは残さない
        XCTAssertTrue(reopened.photos.isEmpty)
        defaults.removePersistentDomain(forName: name)
    }
}

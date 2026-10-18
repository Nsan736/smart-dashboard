import XCTest
@testable import SmartDashboard

/// カメラ表示の縦の目盛り(画角から縦の画角、画面いっぱいに広げたときの切り取り)と、山が平たく見える対策
final class ScopeScaleTests: XCTestCase {
    private func camera(azimuth: Double, elevation: Double = 0) -> CameraAttitude {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        let forward = Vector3(x: cos(e) * cos(a), y: -cos(e) * sin(a), z: sin(e))
        let right = Vector3(x: cos(a + .pi / 2), y: -sin(a + .pi / 2), z: 0)
        return CameraAttitude(right: right, up: Vector3.cross(right, forward), forward: forward)
    }

    func testFieldOfViewWithCorrectionAndZoom() {
        XCTAssertEqual(WaypointProjection.effectiveFieldOfView(format: 60, distortionCorrected: nil, zoom: 1), 60, accuracy: 1e-9)
        // 歪みの補正が効いていれば、補正のあとの画角
        XCTAssertEqual(WaypointProjection.effectiveFieldOfView(format: 60, distortionCorrected: 55, zoom: 1), 55, accuracy: 1e-9)
        XCTAssertEqual(WaypointProjection.effectiveFieldOfView(format: 60, distortionCorrected: 0, zoom: 1), 60, accuracy: 1e-9)
        // 2倍のズームでは、画角の半分の正接が半分
        let zoomed = WaypointProjection.effectiveFieldOfView(format: 60, distortionCorrected: nil, zoom: 2)
        XCTAssertEqual(tan(zoomed / 2 * .pi / 180), tan(30 * Double.pi / 180) / 2, accuracy: 1e-9)
    }

    func testVerticalScaleFromHorizontalFieldOfView() {
        // 16:9 の映像の長辺の画角60°。縦長の画面に、映像を画面いっぱいに広げる
        let tanLong = tan(30 * Double.pi / 180)
        let tanShort = tanLong * 9 / 16
        // 画面が映像より横に広い(iPhone SE で、上のバーと下の情報の分だけ縦が短い 375×520): 横は映像の短辺の全体、縦は切り取られる
        let wide = WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: CGSize(width: 375, height: 520))
        XCTAssertEqual(wide.horizontal, tanShort, accuracy: 1e-9)
        XCTAssertEqual(wide.vertical, tanShort * 520 / 375, accuracy: 1e-9)
        XCTAssertLessThan(wide.vertical, tanLong)
        // 画面が映像より縦に長い: 縦は映像の長辺の全体、横が切り取られる
        let tall = WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: CGSize(width: 375, height: 812))
        XCTAssertEqual(tall.vertical, tanLong, accuracy: 1e-9)
        XCTAssertEqual(tall.horizontal, tanLong * 375 / 812, accuracy: 1e-9)
        // どちらでも、1°の長さは縦と横で同じ(映像は縦横同じ倍率で広げる)
        for (size, tangents) in [(CGSize(width: 375, height: 520), wide), (CGSize(width: 375, height: 812), tall)] {
            let perDegree = WaypointProjection.pointsPerDegree(tangents: tangents, viewSize: size)
            XCTAssertEqual(perDegree.horizontal, perDegree.vertical, accuracy: 1e-9)
        }
        // iPhone SE の例: 縦 1°が約10.1pt。富士山の頂(東京から仰角約1.75°)は、地平線から約17.6pt上
        let perDegree = WaypointProjection.pointsPerDegree(tangents: wide, viewSize: CGSize(width: 375, height: 520))
        XCTAssertEqual(perDegree.vertical, 10.08, accuracy: 0.02)
        let attitude = camera(azimuth: 250)
        let size = CGSize(width: 375, height: 520)
        let top = WaypointProjection.point(bearing: 250, elevation: 1.75, attitude: attitude, tangents: wide, viewSize: size)
        let horizon = WaypointProjection.point(bearing: 250, elevation: 0, attitude: attitude, tangents: wide, viewSize: size)
        XCTAssertEqual(Double((horizon?.y ?? 0) - (top?.y ?? 0)), 17.6, accuracy: 0.1)
    }

    func testElevationRulerMatchesScale() {
        let tangents = WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: CGSize(width: 375, height: 520))
        let size = CGSize(width: 375, height: 520)
        let attitude = camera(azimuth: 90, elevation: 3)
        let zero = ScopeCompassRose.elevationY(0, attitude: attitude, tangents: tangents, size: size) ?? 0
        let five = ScopeCompassRose.elevationY(5, attitude: attitude, tangents: tangents, size: size) ?? 0
        let perDegree = WaypointProjection.pointsPerDegree(tangents: tangents, viewSize: size).vertical
        XCTAssertEqual(Double(zero - five), 5 * perDegree, accuracy: 1)
        XCTAssertFalse(ScopeCompassRose.elevationLine(5, attitude: attitude, tangents: tangents, size: size).isEmpty)
        XCTAssertEqual(ScopeCompassRose.rulerDegrees.first, -2)
        XCTAssertEqual(ScopeCompassRose.rulerDegrees.last, 10)
        XCTAssertFalse(ScopeCompassRose.rulerDegrees.contains(0))
    }

    func testCoarseTilesKeepRidges() {
        // 1つのセルだけが高い(尾根)タイル
        let size = TerrainGrid.tileSize
        var values = [Float](repeating: 100, count: size * size)
        values[100 * size + 100] = 500
        values[0] = .nan
        for zoom in [12, 10, 9] {
            let key = TileKey.locate(latitude: 35.36, longitude: 138.73, zoom: zoom).key
            let grid = TerrainGrid(tiles: [key: values])
            func center(_ i: Int, _ j: Int) -> (latitude: Double, longitude: Double) {
                TileKey.coordinate(x: Double(key.x) + (Double(i) + 0.5) / Double(size), y: Double(key.y) + (Double(j) + 0.5) / Double(size), zoom: zoom)
            }
            let next = center(101, 100)
            let far = center(110, 100)
            let sea = center(0, 0)
            let nearPeak = grid.sample(latitude: next.latitude, longitude: next.longitude, zoom: zoom)
            if zoom <= TerrainGrid.maxPoolZoom {
                // 粗いタイルでは、隣のセルの高い値を使う
                XCTAssertEqual(nearPeak, .elevation(500), "ズーム\(zoom)")
            } else {
                XCTAssertEqual(nearPeak, .elevation(100), "ズーム\(zoom)")
            }
            XCTAssertEqual(grid.sample(latitude: far.latitude, longitude: far.longitude, zoom: zoom), .elevation(100))
            // 海のセルは海のまま
            XCTAssertEqual(grid.sample(latitude: sea.latitude, longitude: sea.longitude, zoom: zoom), .sea)
        }
    }

    func testHeightScaleRaisesSceneryOnly() {
        let size = CGSize(width: 375, height: 520)
        let tangents = WaypointProjection.tangents(fieldOfView: 60, videoAspect: 16.0 / 9.0, viewSize: size)
        let attitude = camera(azimuth: 250)
        let entry = MountainCatalog.Entry(index: 0, name: "富士山", peak: "剣ヶ峰", elevation: 3776, latitude: 35.36, longitude: 138.73, prefecture: "")
        let mountain = SceneryMountain(entry: entry, bearing: 250, distance: 100_000, angle: 1.75, visibility: .visible, priority: 1)
        let scene = SceneryScene(latitude: 35.68, longitude: 139.76, eye: 40, radius: 100_000, skyline: nil, ridges: [], mountains: [mountain],
                                 water: [], labels: [], coverage: 1, computedAt: Date())
        func y(_ scale: Double) -> CGFloat? {
            SceneryRenderer.layout(scene: scene, options: SceneryDrawOptions(layers: [.mountains], showsHiddenMountains: true, heightScale: scale),
                                   attitude: attitude, tangents: tangents, size: size).mountains.first?.point.y
        }
        let doubled = WaypointProjection.point(bearing: 250, elevation: 3.5, attitude: attitude, tangents: tangents, viewSize: size)?.y
        XCTAssertEqual(Double(y(2) ?? 0), Double(doubled ?? 1), accuracy: 1e-6)
        XCTAssertLessThan(y(2) ?? 0, y(1) ?? 0)
        XCTAssertEqual(SceneryHeightScale.choices, [1, 1.5, 2])
        XCTAssertEqual(SceneryHeightScale.label(1.5), "1.5倍")
        XCTAssertEqual(SceneryHeightScale.label(2), "2倍")
    }
}

/// スコープの重ねる表示(v0.9.29)
final class ScopeLayerTests: XCTestCase {
    func testMigrationFromSectionsAndOverlays() {
        // 以前の「電車」の画面で、景色とオブジェクトを重ねていた
        XCTAssertEqual(ScopeLayerMigration.initial(section: "trains", sceneryOverlaysOthers: true, objectsOverlayOthers: true, hasSceneryLayers: true),
                       [.trains, .scenery, .objects])
        // 景色の層を1つも選んでいなければ、景色は重ねていなかった
        XCTAssertEqual(ScopeLayerMigration.initial(section: nil, sceneryOverlaysOthers: true, objectsOverlayOthers: false, hasSceneryLayers: false),
                       [.places])
        // 「ほかにも重ねる」をオフにしていても、景色の画面を開いていたら景色
        XCTAssertEqual(ScopeLayerMigration.initial(section: "scenery", sceneryOverlaysOthers: false, objectsOverlayOthers: false, hasSceneryLayers: true),
                       [.scenery])
        XCTAssertEqual(ScopeLayerMigration.decode(["places", "unknown", "route"]), [.places, .route])
        XCTAssertEqual(ScopeLayer.sorted([.scenery, .places, .trains]), [.places, .trains, .scenery])
        // グループ
        XCTAssertEqual(ScopeLayerGroup.marks.layers, [.places, .nearby, .objects])
        XCTAssertEqual(ScopeLayerGroup.movement.layers, [.route, .trains])
        XCTAssertEqual(ScopeLayerGroup.sky.layers, [.scenery, .sunMoon])
        XCTAssertEqual(ScopeLayerPreset.all.first { $0.name == "歩く" }?.layers, [.places, .route])
        XCTAssertEqual(ScopeLayerPreset.all.first { $0.name == "電車" }?.layers, [.trains, .places])
        XCTAssertEqual(ScopeSightSource.places(selectedID: nil).layer, .places)
        XCTAssertEqual(ScopeSightSource.objects.layer, .objects)
    }

    @MainActor
    func testSettingsKeepLayers() throws {
        let name = "ScopeLayerTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        // v0.9.28 までの状態(景色の画面、オブジェクトも重ねる)
        defaults.set("scenery", forKey: "scope.section")
        defaults.set(true, forKey: "scope.objectsOverlayOthers")
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.scopeLayers.contains(.scenery))
        XCTAssertTrue(settings.scopeLayers.contains(.objects))
        settings.scopeLayers = [.trains, .places]
        XCTAssertEqual(AppSettings(defaults: defaults).scopeLayers, [.trains, .places])
        XCTAssertEqual(settings.sceneryHeightScale, 1)
        settings.sceneryHeightScale = 1.5
        XCTAssertEqual(AppSettings(defaults: defaults).sceneryHeightScale, 1.5)
        defaults.removePersistentDomain(forName: name)
    }
}

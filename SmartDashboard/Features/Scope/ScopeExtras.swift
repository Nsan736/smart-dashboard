import SwiftUI

/// カメラ表示の Canvas に、地点・電車の印と一緒に描くもの(景色とオブジェクト)。印より先に(奥に)描く。
struct ScopeExtras {
    var scenery: SceneryScene?
    var sceneryOptions = SceneryDrawOptions(layers: [], showsHiddenMountains: true)
    var objects: ObjectDrawInput?
    /// 山をタップしたとき
    var onMountain: ((SceneryMountain) -> Void)?
    /// オブジェクトをタップしたとき(置いたものの ID)
    var onObject: ((UUID) -> Void)?

    var isTappable: Bool {
        (scenery != nil && onMountain != nil && sceneryOptions.layers.contains(.mountains)) || (objects != nil && onObject != nil)
    }

    /// 景色(遠く)→ オブジェクトの順に描く
    func draw(_ context: inout GraphicsContext, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) {
        if let scenery {
            SceneryRenderer.draw(&context, layout: SceneryRenderer.layout(scene: scenery, options: sceneryOptions, attitude: attitude,
                                                                          tangents: tangents, size: size))
        }
        if let objects, !objects.items.isEmpty {
            ObjectRenderer.draw(&context, layout: ObjectRenderer.layout(objects, attitude: attitude, tangents: tangents, size: size))
        }
    }

    /// タップ(オブジェクトを先に、なければ山)。何かに当たれば true
    @discardableResult
    func tap(_ location: CGPoint, attitude: CameraAttitude, tangents: (horizontal: Double, vertical: Double), size: CGSize) -> Bool {
        if let objects, let onObject,
           let id = ObjectRenderer.hit(location, layout: ObjectRenderer.layout(objects, attitude: attitude, tangents: tangents, size: size)) {
            onObject(id)
            return true
        }
        if let scenery, let onMountain,
           let mountain = SceneryRenderer.hitMountain(location, layout: SceneryRenderer.layout(scene: scenery, options: sceneryOptions,
                                                                                               attitude: attitude, tangents: tangents, size: size)) {
            onMountain(mountain)
            return true
        }
        return false
    }
}

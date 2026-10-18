import SceneKit
import SwiftUI
import simd

/// オブジェクトのプレビュー(SceneKit)。指で回す・拡大する(allowsCameraControl)。編集の画面と確認の画面で使う。
/// 座標は、オブジェクトの中の x=右、y=前、z=上 を、SceneKit の x=右、y=上、z=手前(前の逆)に直す。
struct ObjectPreviewView: UIViewRepresentable {
    let object: ScopeObject
    var selectedID: UUID?

    final class Coordinator {
        var signature = ""
        let content = SCNNode()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor.secondarySystemBackground
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling2X
        let scene = SCNScene()
        view.scene = scene
        scene.rootNode.addChildNode(context.coordinator.content)

        // 地面(格子の代わりに薄い板)と、正面の向きの印
        let floor = SCNNode(geometry: SCNPlane(width: 60, height: 60))
        floor.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGray.withAlphaComponent(0.25)
        floor.geometry?.firstMaterial?.isDoubleSided = true
        floor.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(floor)
        let arrow = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: 0.6, height: 1.6))
        arrow.geometry?.firstMaterial?.diffuse.contents = UIColor.systemBlue
        arrow.eulerAngles.x = -.pi / 2
        arrow.position = SCNVector3(0, 0.05, -8)
        scene.rootNode.addChildNode(arrow)

        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        light.light?.intensity = 800
        light.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 6, 0)
        scene.rootNode.addChildNode(light)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        // カメラは、オブジェクト全体が入る位置に1回だけ置く(あとは指で動かす)
        let extent = ObjectGeometry.extent(of: object)
        let size = max(extent.width, extent.depth, extent.height, 4)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = Double(size) * 40
        camera.position = SCNVector3(Float(size) * 1.1, Float(size) * 0.9, Float(size) * 1.6)
        camera.look(at: SCNVector3(0, Float(extent.height) / 2, 0))
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera
        update(context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ coordinator: Coordinator) {
        let signature = "\(object.shapes.hashValueForPreview)|\(selectedID?.uuidString ?? "")"
        guard signature != coordinator.signature else { return }
        coordinator.signature = signature
        coordinator.content.childNodes.forEach { $0.removeFromParentNode() }
        for shape in object.shapes {
            coordinator.content.addChildNode(Self.node(shape, selected: shape.id == selectedID))
        }
    }

    static func node(_ shape: ObjectShape, selected: Bool) -> SCNNode {
        let geometry: SCNGeometry
        switch shape.kind {
        case .box: geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        case .cylinder:
            let cylinder = SCNCylinder(radius: 0.5, height: 1)
            cylinder.radialSegmentCount = 24
            geometry = cylinder
        case .cone: geometry = SCNCone(topRadius: 0, bottomRadius: 0.5, height: 1)
        case .sphere: geometry = SCNSphere(radius: 0.5)
        case .pyramid: geometry = SCNPyramid(width: 1, height: 1, length: 1)
        case .plane: geometry = SCNPlane(width: 1, height: 1)
        }
        let material = SCNMaterial()
        material.diffuse.contents = ObjectColor.uiColor(shape.color)
        material.transparency = CGFloat(shape.opacity)
        material.transparencyMode = .dualLayer
        material.isDoubleSided = true
        material.lightingModel = .lambert
        if selected { material.emission.contents = UIColor.white.withAlphaComponent(0.35) }
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        // 角錐は底面が原点なので、中心に合わせる
        if shape.kind == .pyramid { node.pivot = SCNMatrix4MakeTranslation(0, 0.5, 0) }
        node.scale = SCNVector3(Float(shape.width), Float(shape.height), Float(shape.kind == .plane ? 1 : shape.depth))
        node.simdPosition = SIMD3<Float>(Float(shape.x), Float(shape.z + shape.height / 2), Float(-shape.y))
        node.simdOrientation = orientation(yaw: shape.yaw, pitch: shape.pitch, roll: shape.roll)
        return node
    }

    /// ObjectGeometry.rotate と同じ回転(ロール → ピッチ → ヨー)を、SceneKit の軸で表す
    static func orientation(yaw: Double, pitch: Double, roll: Double) -> simd_quatf {
        func rad(_ d: Double) -> Float { Float(d * .pi / 180) }
        let qYaw = simd_quatf(angle: -rad(yaw), axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: rad(pitch), axis: SIMD3(1, 0, 0))
        let qRoll = simd_quatf(angle: -rad(roll), axis: SIMD3(0, 0, 1))
        return qYaw * qPitch * qRoll
    }
}

private extension Array where Element == ObjectShape {
    /// プレビューを作り直すかの判定(形の値が1つでも変わったら)
    var hashValueForPreview: Int {
        var hasher = Hasher()
        for shape in self {
            hasher.combine(shape.id)
            hasher.combine(shape.kind.rawValue)
            for v in [shape.width, shape.depth, shape.height, shape.x, shape.y, shape.z, shape.yaw, shape.pitch, shape.roll, shape.opacity] {
                hasher.combine(v)
            }
            hasher.combine(shape.color)
        }
        return hasher.finalize()
    }
}

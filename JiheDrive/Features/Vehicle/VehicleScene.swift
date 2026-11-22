import Metal
import SceneKit
import UIKit

/// 3D 展示舞台：相机轨道、灯光、地面阴影、环境贴图。
/// 车辆网格一律来自接口返回的模型文件，这里不做任何建模。
enum VehicleSceneBuilder {

    static func skyTexture() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [
                UIColor(white: 0.98, alpha: 1).cgColor,
                UIColor(hex: 0x8FA8C4).cgColor,
                UIColor(white: 0.06, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.58, 1]
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: 0, y: size.height),
                    options: []
                )
            }
        }
    }

    static func material(
        _ color: UIColor,
        metalness: CGFloat = 0.0,
        roughness: CGFloat = 0.6
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = NSNumber(value: Double(metalness))
        material.roughness.contents = NSNumber(value: Double(roughness))
        material.isDoubleSided = true
        return material
    }

    static func groundNode() -> SCNNode {
        let plane = SCNPlane(width: 3.4, height: 3.4)
        plane.firstMaterial = material(UIColor.clear, metalness: 0, roughness: 1)
        plane.firstMaterial?.diffuse.contents = shadowTexture()
        plane.firstMaterial?.isDoubleSided = false
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.writesToDepthBuffer = false
        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0.002, 0)
        node.renderingOrder = -10
        return node
    }

    static func shadowTexture() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [
                UIColor.black.withAlphaComponent(0.55).cgColor,
                UIColor.black.withAlphaComponent(0.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cg.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: 128, y: 128),
                    startRadius: 4,
                    endCenter: CGPoint(x: 128, y: 128),
                    endRadius: 120,
                    options: []
                )
            }
        }
    }

    static func lightRig() -> SCNNode {
        let group = SCNNode()

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 420
        ambient.color = UIColor(hex: 0xBFD4F2)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        group.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 1100
        key.color = UIColor.white
        key.castsShadow = true
        key.shadowRadius = 8
        key.shadowSampleCount = 16
        key.shadowColor = UIColor.black.withAlphaComponent(0.35)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.position = SCNVector3(2.2, 3.0, 2.6)
        keyNode.look(at: SCNVector3(0, 0.5, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        group.addChildNode(keyNode)

        let rim = SCNLight()
        rim.type = .omni
        rim.intensity = 800
        rim.color = UIColor(hex: 0x6FA8FF)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.position = SCNVector3(-2.0, 1.4, -1.8)
        group.addChildNode(rimNode)

        let fill = SCNLight()
        fill.type = .omni
        fill.intensity = 400
        fill.color = UIColor(hex: 0xFFE7C8)
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.position = SCNVector3(1.4, 0.8, -2.2)
        group.addChildNode(fillNode)
        return group
    }

    /// 轨道相机：orbit 绕 Y 旋转，rig 始终看向 orbit 局部原点
    static func cameraOrbit() -> SCNNode {
        let orbit = SCNNode()
        orbit.name = "orbit"
        orbit.position = SCNVector3(0, 0.82, 0)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.01
        camera.zFar = 40
        camera.wantsHDR = true
        camera.bloomIntensity = 0.24
        camera.bloomThreshold = 0.88
        camera.bloomBlurRadius = 6

        let cameraNode = SCNNode()
        cameraNode.camera = camera

        let rig = SCNNode()
        rig.name = "rig"
        rig.position = SCNVector3(0, 0, 2.6)
        rig.addChildNode(cameraNode)

        orbit.addChildNode(rig)
        return orbit
    }
}

/// 把当前 3D 场景拍成透明底图，给位置地图当定位点
enum VehicleSceneSnapshot {
    static func image(from scene: SCNScene, size: CGSize = CGSize(width: 360, height: 240)) -> UIImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        var cameraNode: SCNNode?
        scene.rootNode.enumerateChildNodes { node, stop in
            if node.camera != nil {
                cameraNode = node
                stop.pointee = true
            }
        }
        renderer.pointOfView = cameraNode
        let shot = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling2X)
        return shot
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

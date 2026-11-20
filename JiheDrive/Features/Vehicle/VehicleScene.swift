import SceneKit
import UIKit

/// 程序化踏板车模型：侧面轮廓用贝塞尔路径挤出成车身，其余部件用几何体拼装。
/// 接口提供官方 USDZ 时优先用官方模型，这里是没有模型时的兜底。
enum VehicleSceneBuilder {

    /// 涂装目录
    static let paints: [(name: String, hex: UInt32)] = [
        ("曜石蓝", 0x1268E0),
        ("钛银", 0xB9C2CC),
        ("炽橙", 0xF0602A),
        ("石墨黑", 0x2A2F36)
    ]

    static func build(paint: UInt32 = 0x1268E0) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = skyTexture()
        scene.lightingEnvironment.intensity = 1.1

        let stage = SCNNode()
        stage.name = "stage"
        scene.rootNode.addChildNode(stage)

        let paintColor = UIColor(hex: paint)

        stage.addChildNode(bodyNode(paint: paintColor))
        stage.addChildNode(seatNode())
        stage.addChildNode(skirtNode())
        stage.addChildNode(wheelNode(radius: 0.30, at: SCNVector3(0.56, 0.30, 0)))
        stage.addChildNode(wheelNode(radius: 0.30, at: SCNVector3(-0.54, 0.30, 0)))
        stage.addChildNode(forkNode(paint: paintColor))
        stage.addChildNode(handlebarNode())
        stage.addChildNode(headlightNode())
        stage.addChildNode(tailLightNode())
        stage.addChildNode(mirrorNodes())
        stage.addChildNode(fenderNode(center: SCNVector3(0.56, 0.30, 0), radius: 0.335, width: 0.17))
        stage.addChildNode(fenderNode(center: SCNVector3(-0.54, 0.30, 0), radius: 0.345, width: 0.18))
        stage.addChildNode(groundNode())

        scene.rootNode.addChildNode(lightRig())
        scene.rootNode.addChildNode(cameraOrbit())
        return scene
    }

    // MARK: - 材质

    static func material(
        _ color: UIColor,
        metalness: CGFloat = 0.0,
        roughness: CGFloat = 0.6,
        emission: UIColor? = nil
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = NSNumber(value: Double(metalness))
        material.roughness.contents = NSNumber(value: Double(roughness))
        if let emission {
            material.emission.contents = emission
        }
        material.isDoubleSided = true
        return material
    }

    private static func chrome() -> SCNMaterial {
        material(UIColor(white: 0.82, alpha: 1), metalness: 0.95, roughness: 0.18)
    }

    private static func rubber() -> SCNMaterial {
        material(UIColor(white: 0.09, alpha: 1), metalness: 0.0, roughness: 0.92)
    }

    // MARK: - 车身

    private static func bodyNode(paint: UIColor) -> SCNNode {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.32, y: 0.24))
        path.addLine(to: CGPoint(x: 0.56, y: 0.26))
        path.addCurve(
            to: CGPoint(x: 0.72, y: 0.56),
            controlPoint1: CGPoint(x: 0.68, y: 0.30),
            controlPoint2: CGPoint(x: 0.72, y: 0.42)
        )
        path.addLine(to: CGPoint(x: 0.70, y: 0.90))
        path.addCurve(
            to: CGPoint(x: 0.50, y: 0.94),
            controlPoint1: CGPoint(x: 0.68, y: 0.97),
            controlPoint2: CGPoint(x: 0.57, y: 0.98)
        )
        path.addCurve(
            to: CGPoint(x: 0.18, y: 0.68),
            controlPoint1: CGPoint(x: 0.42, y: 0.90),
            controlPoint2: CGPoint(x: 0.26, y: 0.76)
        )
        path.addLine(to: CGPoint(x: 0.10, y: 0.66))
        path.addLine(to: CGPoint(x: -0.36, y: 0.68))
        path.addCurve(
            to: CGPoint(x: -0.64, y: 0.58),
            controlPoint1: CGPoint(x: -0.50, y: 0.70),
            controlPoint2: CGPoint(x: -0.60, y: 0.66)
        )
        path.addCurve(
            to: CGPoint(x: -0.68, y: 0.36),
            controlPoint1: CGPoint(x: -0.70, y: 0.50),
            controlPoint2: CGPoint(x: -0.72, y: 0.42)
        )
        path.addCurve(
            to: CGPoint(x: -0.34, y: 0.24),
            controlPoint1: CGPoint(x: -0.62, y: 0.28),
            controlPoint2: CGPoint(x: -0.50, y: 0.24)
        )
        path.close()

        let shape = SCNShape(path: path, extrusionDepth: 0.34)
        shape.chamferRadius = 0.075
        shape.chamferMode = .both
        shape.firstMaterial = material(paint, metalness: 0.72, roughness: 0.24)

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(0, 0, -0.17)
        return node
    }

    private static func seatNode() -> SCNNode {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0.12, y: 0.66))
        path.addCurve(
            to: CGPoint(x: -0.34, y: 0.70),
            controlPoint1: CGPoint(x: -0.04, y: 0.73),
            controlPoint2: CGPoint(x: -0.22, y: 0.74)
        )
        path.addCurve(
            to: CGPoint(x: -0.52, y: 0.64),
            controlPoint1: CGPoint(x: -0.44, y: 0.70),
            controlPoint2: CGPoint(x: -0.50, y: 0.68)
        )
        path.addLine(to: CGPoint(x: -0.46, y: 0.58))
        path.addLine(to: CGPoint(x: 0.06, y: 0.58))
        path.close()

        let shape = SCNShape(path: path, extrusionDepth: 0.30)
        shape.chamferRadius = 0.045
        shape.firstMaterial = material(UIColor(white: 0.13, alpha: 1), metalness: 0.05, roughness: 0.88)

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(0, 0, -0.15)
        return node
    }

    /// 下护板：一块深色窄板压住车身底部
    private static func skirtNode() -> SCNNode {
        let box = SCNBox(width: 0.94, height: 0.10, length: 0.30, chamferRadius: 0.04)
        box.firstMaterial = material(UIColor(white: 0.15, alpha: 1), metalness: 0.10, roughness: 0.80)
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(0.02, 0.20, 0)
        return node
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

    // MARK: - 车轮

    private static func wheelNode(radius: CGFloat, at position: SCNVector3) -> SCNNode {
        let wheel = SCNNode()
        wheel.position = position

        let tyre = SCNTorus(ringRadius: radius - radius * 0.16, pipeRadius: radius * 0.16)
        tyre.ringSegmentCount = 48
        tyre.pipeSegmentCount = 18
        tyre.firstMaterial = rubber()
        let tyreNode = SCNNode(geometry: tyre)
        tyreNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        wheel.addChildNode(tyreNode)

        let rim = SCNCylinder(radius: radius * 0.62, height: 0.055)
        rim.radialSegmentCount = 36
        rim.firstMaterial = chrome()
        let rimNode = SCNNode(geometry: rim)
        rimNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        wheel.addChildNode(rimNode)

        let hub = SCNCylinder(radius: radius * 0.16, height: 0.075)
        hub.firstMaterial = material(UIColor(white: 0.25, alpha: 1), metalness: 0.8, roughness: 0.35)
        let hubNode = SCNNode(geometry: hub)
        hubNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        wheel.addChildNode(hubNode)

        for index in 0..<5 {
            let spoke = SCNBox(width: radius * 0.10, height: radius * 0.92, length: 0.02, chamferRadius: 0.006)
            spoke.firstMaterial = chrome()
            let node = SCNNode(geometry: spoke)
            node.eulerAngles = SCNVector3(0, 0, Float(index) * Float.pi / 5)
            wheel.addChildNode(node)
        }
        return wheel
    }

    private static func fenderNode(center: SCNVector3, radius: CGFloat, width: CGFloat) -> SCNNode {
        let outer = radius + 0.028
        let path = UIBezierPath()
        path.addArc(
            withCenter: .zero,
            radius: outer,
            startAngle: .pi * 0.10,
            endAngle: .pi * 0.95,
            clockwise: true
        )
        path.addArc(
            withCenter: .zero,
            radius: radius,
            startAngle: .pi * 0.95,
            endAngle: .pi * 0.10,
            clockwise: false
        )
        path.close()

        let shape = SCNShape(path: path, extrusionDepth: width)
        shape.chamferRadius = 0.01
        shape.firstMaterial = material(UIColor(white: 0.11, alpha: 1), metalness: 0.2, roughness: 0.7)

        let node = SCNNode(geometry: shape)
        node.position = SCNVector3(center.x, center.y, -Float(width) / 2)
        return node
    }

    // MARK: - 前叉 / 车把

    private static func forkNode(paint: UIColor) -> SCNNode {
        let group = SCNNode()
        let metal = material(UIColor(white: 0.35, alpha: 1), metalness: 0.9, roughness: 0.25)
        for z in [-0.10, 0.10] {
            group.addChildNode(
                strut(
                    from: SCNVector3(0.64, 0.72, Float(z)),
                    to: SCNVector3(0.56, 0.30, Float(z)),
                    radius: 0.026,
                    material: metal
                )
            )
        }
        let brace = SCNBox(width: 0.05, height: 0.05, length: 0.24, chamferRadius: 0.02)
        brace.firstMaterial = material(paint, metalness: 0.6, roughness: 0.35)
        let braceNode = SCNNode(geometry: brace)
        braceNode.position = SCNVector3(0.60, 0.52, 0)
        braceNode.eulerAngles = SCNVector3(0, 0, -0.28)
        group.addChildNode(braceNode)
        return group
    }

    private static func handlebarNode() -> SCNNode {
        let group = SCNNode()
        let bar = SCNCylinder(radius: 0.020, height: 0.54)
        bar.radialSegmentCount = 20
        bar.firstMaterial = chrome()
        let barNode = SCNNode(geometry: bar)
        barNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        barNode.position = SCNVector3(0.62, 0.92, 0)
        group.addChildNode(barNode)

        for z in [-0.235, 0.235] {
            let grip = SCNCylinder(radius: 0.032, height: 0.13)
            grip.radialSegmentCount = 20
            grip.firstMaterial = rubber()
            let node = SCNNode(geometry: grip)
            node.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            node.position = SCNVector3(0.62, 0.92, Float(z))
            group.addChildNode(node)
        }

        // 前风挡
        let screen = SCNBox(width: 0.30, height: 0.26, length: 0.012, chamferRadius: 0.03)
        screen.firstMaterial = material(
            UIColor(white: 0.85, alpha: 0.28),
            metalness: 0.0,
            roughness: 0.08
        )
        screen.firstMaterial?.isDoubleSided = true
        let screenNode = SCNNode(geometry: screen)
        screenNode.position = SCNVector3(0.60, 1.02, 0)
        screenNode.eulerAngles = SCNVector3(0, 0, -0.30)
        group.addChildNode(screenNode)
        return group
    }

    // MARK: - 灯组 / 后视镜

    private static func headlightNode() -> SCNNode {
        let group = SCNNode()
        let housing = SCNSphere(radius: 0.115)
        housing.segmentCount = 24
        housing.firstMaterial = material(UIColor(white: 0.10, alpha: 1), metalness: 0.4, roughness: 0.35)
        let housingNode = SCNNode(geometry: housing)
        housingNode.scale = SCNVector3(0.55, 1, 1)
        housingNode.position = SCNVector3(0.74, 0.76, 0)
        group.addChildNode(housingNode)

        let lens = SCNSphere(radius: 0.082)
        lens.segmentCount = 24
        lens.firstMaterial = material(
            UIColor(white: 1.0, alpha: 1),
            metalness: 0.2,
            roughness: 0.12,
            emission: UIColor(hex: 0xEAF4FF)
        )
        lens.firstMaterial?.emission.intensity = 1.6
        let lensNode = SCNNode(geometry: lens)
        lensNode.scale = SCNVector3(0.45, 1, 1)
        lensNode.position = SCNVector3(0.79, 0.76, 0)
        group.addChildNode(lensNode)
        return group
    }

    private static func tailLightNode() -> SCNNode {
        let box = SCNBox(width: 0.035, height: 0.055, length: 0.24, chamferRadius: 0.015)
        box.firstMaterial = material(
            UIColor(hex: 0x3A0A0A),
            metalness: 0.1,
            roughness: 0.4,
            emission: UIColor(hex: 0xFF2A2A)
        )
        box.firstMaterial?.emission.intensity = 1.4
        let node = SCNNode(geometry: box)
        node.position = SCNVector3(-0.68, 0.56, 0)
        return node
    }

    private static func mirrorNodes() -> SCNNode {
        let group = SCNNode()
        let stem = material(UIColor(white: 0.22, alpha: 1), metalness: 0.85, roughness: 0.3)
        for z in [-0.20, 0.20] {
            group.addChildNode(
                strut(
                    from: SCNVector3(0.62, 0.94, Float(z) * 0.55),
                    to: SCNVector3(0.58, 1.14, Float(z)),
                    radius: 0.013,
                    material: stem
                )
            )
            let glass = SCNBox(width: 0.035, height: 0.075, length: 0.11, chamferRadius: 0.025)
            glass.firstMaterial = material(UIColor(white: 0.55, alpha: 1), metalness: 1.0, roughness: 0.1)
            let node = SCNNode(geometry: glass)
            node.position = SCNVector3(0.57, 1.16, Float(z))
            group.addChildNode(node)
        }
        return group
    }

    // MARK: - 灯光 / 相机

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
        key.color = UIColor(hex: 0xFFFFFF)
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

    static func cameraOrbit() -> SCNNode {
        let orbit = SCNNode()
        orbit.name = "orbit"
        orbit.position = SCNVector3(0, 0.46, 0)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.01
        camera.zFar = 40
        camera.wantsHDR = true
        camera.bloomIntensity = 0.28
        camera.bloomThreshold = 0.85
        camera.bloomBlurRadius = 6

        let cameraNode = SCNNode()
        cameraNode.camera = camera

        let rig = SCNNode()
        rig.name = "rig"
        rig.position = SCNVector3(0, sin(0.15) * 2.5, cos(0.15) * 2.5)
        rig.addChildNode(cameraNode)

        orbit.addChildNode(rig)
        return orbit
    }

    // MARK: - 工具

    private static func strut(
        from a: SCNVector3,
        to b: SCNVector3,
        radius: CGFloat,
        material: SCNMaterial
    ) -> SCNNode {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        let length = (dx * dx + dy * dy + dz * dz).squareRoot()
        guard length > 0 else { return SCNNode() }

        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        cylinder.radialSegmentCount = 16
        cylinder.firstMaterial = material

        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: SIMD3<Float>(dx / length, dy / length, dz / length)
        )
        return node
    }

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

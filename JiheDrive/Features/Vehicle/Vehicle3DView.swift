import SceneKit
import SwiftUI
import UIKit

/// 用 SceneKit 基础几何体拼出的极核踏板车模型：可拖动旋转、双指缩放
struct Vehicle3DView: UIViewRepresentable {
    var paint: UIColor = UIColor(red: 0.10, green: 0.45, blue: 0.92, alpha: 1)

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.allowsCameraControl = true
        view.isPlaying = true
        view.autoenablesDefaultLighting = false
        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = true
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.updatePaint(paint)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(paint: paint)
    }

    final class Coordinator {
        let scene = SCNScene()

        private let paintMaterial: SCNMaterial
        private let bodyNode = SCNNode()

        init(paint: UIColor) {
            paintMaterial = Coordinator.makeMaterial(
                color: paint,
                metalness: 0.62,
                roughness: 0.34
            )
            build()
        }

        func updatePaint(_ color: UIColor) {
            paintMaterial.diffuse.contents = color
        }

        // MARK: - 场景

        private func build() {
            scene.background.contents = UIColor.clear
            bodyNode.position = SCNVector3(0, 0, 0)
            scene.rootNode.addChildNode(bodyNode)
            addScooter(to: bodyNode)
            addLights()
            addCamera()
            spin()
        }

        /// 环顾一圈，慢速自转
        private func spin() {
            let rotate = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 30)
            bodyNode.runAction(.repeatForever(rotate))
        }

        private func addScooter(to root: SCNNode) {
            let rubber = Coordinator.makeMaterial(color: UIColor(white: 0.10, alpha: 1), metalness: 0.05, roughness: 0.95)
            let metal = Coordinator.makeMaterial(color: UIColor(white: 0.72, alpha: 1), metalness: 0.92, roughness: 0.28)
            let seat = Coordinator.makeMaterial(color: UIColor(white: 0.13, alpha: 1), metalness: 0.10, roughness: 0.80)
            let darkTrim = Coordinator.makeMaterial(color: UIColor(white: 0.20, alpha: 1), metalness: 0.40, roughness: 0.55)

            // 后轮 + 前轮
            root.addChildNode(wheel(at: SCNVector3(-0.62, 0.26, 0), rubber: rubber, metal: metal))
            root.addChildNode(wheel(at: SCNVector3(0.72, 0.26, 0), rubber: rubber, metal: metal))

            // 踏板
            let floor = box(0.86, 0.06, 0.32, chamfer: 0.02, material: darkTrim)
            floor.position = SCNVector3(-0.04, 0.31, 0)
            root.addChildNode(floor)

            // 车身后半段
            let rear = box(0.72, 0.30, 0.38, chamfer: 0.12, material: paintMaterial)
            rear.position = SCNVector3(-0.44, 0.55, 0)
            root.addChildNode(rear)

            let tail = box(0.26, 0.20, 0.30, chamfer: 0.08, material: paintMaterial)
            tail.position = SCNVector3(-0.80, 0.62, 0)
            root.addChildNode(tail)

            // 座垫
            let saddle = box(0.60, 0.09, 0.32, chamfer: 0.04, material: seat)
            saddle.position = SCNVector3(-0.46, 0.75, 0)
            root.addChildNode(saddle)

            let backrest = box(0.06, 0.16, 0.28, chamfer: 0.03, material: seat)
            backrest.position = SCNVector3(-0.76, 0.85, 0)
            root.addChildNode(backrest)

            // 前腿部挡板
            let shield = box(0.10, 0.56, 0.34, chamfer: 0.05, material: paintMaterial)
            shield.position = SCNVector3(0.26, 0.68, 0)
            shield.eulerAngles = SCNVector3(0, 0, 0.20)
            root.addChildNode(shield)

            // 前叉
            for z in [-0.11, 0.11] {
                let fork = cylinder(radius: 0.018, height: 0.52, material: metal)
                fork.position = SCNVector3(0.66, 0.50, Float(z))
                fork.eulerAngles = SCNVector3(0, 0, 0.28)
                root.addChildNode(fork)
            }

            // 前挡泥板
            let fender = box(0.30, 0.05, 0.20, chamfer: 0.02, material: paintMaterial)
            fender.position = SCNVector3(0.70, 0.47, 0)
            root.addChildNode(fender)

            // 转向柱
            let column = cylinder(radius: 0.032, height: 0.60, material: metal)
            column.position = SCNVector3(0.50, 0.86, 0)
            column.eulerAngles = SCNVector3(0, 0, 0.22)
            root.addChildNode(column)

            // 车把 + 握把
            let bar = cylinder(radius: 0.022, height: 0.60, material: metal)
            bar.position = SCNVector3(0.57, 1.06, 0)
            bar.eulerAngles = SCNVector3(.pi / 2, 0, 0)
            root.addChildNode(bar)

            for z in [-0.28, 0.28] {
                let grip = cylinder(radius: 0.032, height: 0.13, material: seat)
                grip.position = SCNVector3(0.57, 1.06, Float(z))
                grip.eulerAngles = SCNVector3(.pi / 2, 0, 0)
                root.addChildNode(grip)
            }

            // 仪表
            let dash = box(0.14, 0.03, 0.20, chamfer: 0.02, material: darkTrim)
            dash.position = SCNVector3(0.52, 1.10, 0)
            dash.eulerAngles = SCNVector3(0, 0, 0.20)
            root.addChildNode(dash)

            // 大灯
            let headlight = SCNNode(geometry: SCNSphere(radius: 0.075))
            headlight.geometry?.firstMaterial = Coordinator.emissionMaterial(
                color: UIColor(red: 1.0, green: 0.96, blue: 0.86, alpha: 1),
                intensity: 1.6
            )
            headlight.position = SCNVector3(0.60, 0.90, 0)
            headlight.scale = SCNVector3(1, 0.8, 1)
            root.addChildNode(headlight)

            // 尾灯
            let tailLight = box(0.03, 0.07, 0.20, chamfer: 0.01, material: Coordinator.emissionMaterial(
                color: UIColor(red: 1.0, green: 0.18, blue: 0.18, alpha: 1),
                intensity: 1.2
            ))
            tailLight.position = SCNVector3(-0.93, 0.66, 0)
            root.addChildNode(tailLight)

            // 侧撑
            let stand = cylinder(radius: 0.012, height: 0.34, material: metal)
            stand.position = SCNVector3(-0.30, 0.16, 0.16)
            stand.eulerAngles = SCNVector3(0.35, 0, 0.25)
            root.addChildNode(stand)
        }

        private func wheel(at position: SCNVector3, rubber: SCNMaterial, metal: SCNMaterial) -> SCNNode {
            let node = SCNNode()
            node.position = position

            let tyre = SCNTorus(ringRadius: 0.20, pipeRadius: 0.062)
            tyre.firstMaterial = rubber
            tyre.radialSegmentCount = 48
            let tyreNode = SCNNode(geometry: tyre)
            tyreNode.eulerAngles = SCNVector3(.pi / 2, 0, 0)
            node.addChildNode(tyreNode)

            let rim = SCNCylinder(radius: 0.145, height: 0.075)
            rim.firstMaterial = metal
            let rimNode = SCNNode(geometry: rim)
            rimNode.eulerAngles = SCNVector3(.pi / 2, 0, 0)
            node.addChildNode(rimNode)

            for index in 0..<5 {
                let spoke = SCNBox(width: 0.022, height: 0.26, length: 0.018, chamferRadius: 0.008)
                spoke.firstMaterial = metal
                let spokeNode = SCNNode(geometry: spoke)
                spokeNode.eulerAngles = SCNVector3(0, 0, Float(index) * .pi / 5)
                node.addChildNode(spokeNode)
            }

            let spin = SCNAction.rotateBy(x: 0, y: 0, z: -.pi * 2, duration: 2.2)
            node.runAction(.repeatForever(spin))
            return node
        }

        private func box(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat, chamfer: CGFloat, material: SCNMaterial) -> SCNNode {
            let geometry = SCNBox(width: width, height: height, length: length, chamferRadius: chamfer)
            geometry.firstMaterial = material
            return SCNNode(geometry: geometry)
        }

        private func cylinder(radius: CGFloat, height: CGFloat, material: SCNMaterial) -> SCNNode {
            let geometry = SCNCylinder(radius: radius, height: height)
            geometry.firstMaterial = material
            geometry.radialSegmentCount = 32
            return SCNNode(geometry: geometry)
        }

        // MARK: - 灯光 / 相机

        private func addLights() {
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = UIColor(white: 0.55, alpha: 1)
            ambient.light?.intensity = 420
            scene.rootNode.addChildNode(ambient)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.color = UIColor.white
            key.light?.intensity = 900
            key.light?.castsShadow = true
            key.light?.shadowMode = .deferred
            key.light?.shadowRadius = 8
            key.light?.shadowColor = UIColor.black.withAlphaComponent(0.35)
            key.eulerAngles = SCNVector3(-0.85, 0.65, 0)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.color = UIColor(red: 0.55, green: 0.75, blue: 1.0, alpha: 1)
            fill.light?.intensity = 620
            fill.position = SCNVector3(-2.0, 1.6, -2.2)
            scene.rootNode.addChildNode(fill)

            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light?.type = .omni
            rim.light?.color = UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1)
            rim.light?.intensity = 520
            rim.position = SCNVector3(2.2, 0.9, 1.8)
            scene.rootNode.addChildNode(rim)
        }

        private func addCamera() {
            let cameraNode = SCNNode()
            let camera = SCNCamera()
            camera.fieldOfView = 42
            camera.zNear = 0.05
            camera.zFar = 40
            camera.wantsHDR = true
            camera.bloomIntensity = 0.25
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(2.05, 1.18, 2.35)

            let target = SCNNode()
            target.position = SCNVector3(0, 0.52, 0)
            scene.rootNode.addChildNode(target)

            let lookAt = SCNLookAtConstraint(target: target)
            lookAt.isGimbalLockEnabled = true
            cameraNode.constraints = [lookAt]
            scene.rootNode.addChildNode(cameraNode)
        }

        // MARK: - 材质

        static func makeMaterial(color: UIColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = color
            material.metalness.contents = metalness
            material.roughness.contents = roughness
            material.isDoubleSided = false
            return material
        }

        static func emissionMaterial(color: UIColor, intensity: CGFloat) -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = color
            material.emission.contents = color
            material.emission.intensity = intensity
            return material
        }
    }
}

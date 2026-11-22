import ModelIO
import SceneKit
import SceneKit.ModelIO
import UIKit

/// 把官方车模收成地图用的立体场景：贴地、略俯视、可按航向绕 Y 转。
enum ReplayMapModel {
    private static var fileCache: [String: SCNScene] = [:]

    static func prepared(from source: SCNScene) -> SCNScene {
        makeMapScene(from: source)
    }

    static func scene(from file: URL) -> SCNScene? {
        if let cached = fileCache[file.path] { return cached }
        guard let loaded = load(file), hasMesh(loaded) else { return nil }
        let ready = makeMapScene(from: loaded)
        fileCache[file.path] = ready
        return ready
    }

    private static func load(_ file: URL) -> SCNScene? {
        let options: [SCNSceneSource.LoadingOption: Any] = [
            .createNormalsIfAbsent: true,
            .convertToYUp: true,
            .checkConsistency: false
        ]
        if let scene = try? SCNScene(url: file, options: options), hasMesh(scene) {
            return scene
        }
        let asset = MDLAsset(url: file)
        asset.loadTextures()
        guard asset.count > 0 else { return nil }
        let scene = SCNScene(mdlAsset: asset)
        return hasMesh(scene) ? scene : nil
    }

    private static func hasMesh(_ scene: SCNScene) -> Bool {
        var found = false
        scene.rootNode.enumerateChildNodes { node, stop in
            if node.geometry != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func makeMapScene(from source: SCNScene) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        scene.lightingEnvironment.contents = VehicleSceneBuilder.skyTexture()
        scene.lightingEnvironment.intensity = 1.05

        let yaw = SCNNode()
        yaw.name = "replay-yaw"

        for child in source.rootNode.childNodes {
            if child.camera != nil { continue }
            if child.light != nil { continue }
            if child.name == "orbit" { continue }
            if child.geometry is SCNPlane { continue }
            let clone = child.clone()
            stripCameras(clone)
            yaw.addChildNode(clone)
        }

        fit(yaw)
        scene.rootNode.addChildNode(yaw)

        let shadow = VehicleSceneBuilder.groundNode()
        shadow.scale = SCNVector3(0.55, 0.55, 0.55)
        scene.rootNode.addChildNode(shadow)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 780
        sun.light?.color = UIColor.white
        sun.eulerAngles = SCNVector3(-0.85, 0.55, 0)
        scene.rootNode.addChildNode(sun)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 420
        fill.light?.color = UIColor.white
        scene.rootNode.addChildNode(fill)

        let camera = SCNNode()
        camera.name = "replay-cam"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 28
        camera.camera?.zNear = 0.05
        camera.camera?.zFar = 40
        camera.position = SCNVector3(1.55, 1.28, 2.15)
        camera.look(at: SCNVector3(0, 0.30, 0))
        scene.rootNode.addChildNode(camera)
        return scene
    }

    private static func stripCameras(_ node: SCNNode) {
        if node.camera != nil || node.light != nil {
            node.removeFromParentNode()
            return
        }
        for child in node.childNodes {
            stripCameras(child)
        }
    }

    private static func fit(_ node: SCNNode) {
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        node.enumerateHierarchy { child, _ in
            guard child.geometry != nil else { return }
            let (low, high) = child.boundingBox
            for x in [low.x, high.x] {
                for y in [low.y, high.y] {
                    for z in [low.z, high.z] {
                        let point = child.convertPosition(SCNVector3(x, y, z), to: node)
                        minX = min(minX, point.x)
                        minY = min(minY, point.y)
                        minZ = min(minZ, point.z)
                        maxX = max(maxX, point.x)
                        maxY = max(maxY, point.y)
                        maxZ = max(maxZ, point.z)
                    }
                }
            }
        }

        guard maxX > minX, maxY > minY else { return }
        let longest = max(maxX - minX, max(maxY - minY, max(maxZ - minZ, 0.001)))
        guard longest > 0 else { return }
        let scale = 1.7 / longest
        node.scale = SCNVector3(scale, scale, scale)
        node.position = SCNVector3(
            -(minX + maxX) / 2 * scale,
            -minY * scale,
            -(minZ + maxZ) / 2 * scale
        )
    }
}

import SceneKit
import SwiftUI

/// 官方 3D 模型加载：下载 → 归一化 → 配轨道相机与灯光。
/// 接口没给模型地址时保持 idle，调用方回退到内置模型。
@MainActor
final class VehicleModelLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(SCNScene)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var currentURL: URL?
    private static var cache: [String: SCNScene] = [:]

    var scene: SCNScene? {
        if case .ready(let scene) = state { return scene }
        return nil
    }

    func load(_ url: URL?) {
        guard let url else {
            state = .idle
            currentURL = nil
            return
        }
        if currentURL == url, case .ready = state { return }
        currentURL = url

        if let cached = Self.cache[url.absoluteString] {
            state = .ready(cached)
            return
        }

        state = .loading
        Task {
            do {
                let local = try await Self.download(url)
                let scene = try SCNScene(
                    url: local,
                    options: [
                        .createNormalsIfAbsent: true,
                        .convertToYUp: true,
                        .checkConsistency: false
                    ]
                )
                let ready = Self.normalized(scene)
                Self.cache[url.absoluteString] = ready
                state = .ready(ready)
            } catch {
                state = .failed(Self.message(for: error))
            }
        }
    }

    // MARK: - 下载

    enum ModelError: Error {
        case unsupported(String)
        case empty

        var text: String {
            switch self {
            case .unsupported(let ext): return "接口返回 .\(ext) 格式，iOS 原生只能加载 USDZ / USD"
            case .empty: return "模型文件为空"
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ModelError { return error.text }
        return error.localizedDescription
    }

    nonisolated private static func download(_ url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        if !["usdz", "usd", "scn", "dae", "obj", "ply"].contains(ext) {
            throw ModelError.unsupported(ext.isEmpty ? "bin" : ext)
        }
        if url.isFileURL { return url }

        let (temp, _) = try await URLSession.shared.download(from: url)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vehicle-model-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    // MARK: - 归一化

    private static func normalized(_ scene: SCNScene) -> SCNScene {
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        scene.rootNode.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            let (low, high) = node.boundingBox
            for x in [low.x, high.x] {
                for y in [low.y, high.y] {
                    for z in [low.z, high.z] {
                        let point = node.convertPosition(SCNVector3(x, y, z), to: nil)
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

        guard maxX > minX, maxY > minY else { return scene }

        let width = maxX - minX
        let height = maxY - minY
        let depth = max(maxZ - minZ, 0.001)
        let longest = max(width, max(height, depth))
        guard longest > 0 else { return scene }

        let scale = 1.9 / longest
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let centerZ = (minZ + maxZ) / 2

        let container = SCNNode()
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            container.addChildNode(child)
        }
        container.scale = SCNVector3(scale, scale, scale)
        // 底部贴地，水平居中
        container.position = SCNVector3(
            -centerX * scale,
            -minY * scale,
            -centerZ * scale
        )

        let root = SCNScene()
        root.background.contents = UIColor.clear
        root.lightingEnvironment.contents = VehicleSceneBuilder.skyTexture()
        root.lightingEnvironment.intensity = 1.05

        let stage = SCNNode()
        stage.addChildNode(container)
        root.rootNode.addChildNode(stage)
        root.rootNode.addChildNode(VehicleSceneBuilder.groundNode())
        root.rootNode.addChildNode(VehicleSceneBuilder.lightRig())

        let orbit = VehicleSceneBuilder.cameraOrbit()
        orbit.position = SCNVector3(0, 0.6, 0)
        root.rootNode.addChildNode(orbit)
        return root
    }
}

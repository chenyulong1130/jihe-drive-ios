import SceneKit
import SwiftUI
import UIKit

struct Vehicle3DSheet: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = ModelLoader()

    private var hasModel: Bool { vehicle.model3DURL != nil }

    var body: some View {
        SheetShell(title: "3D 看车", subtitle: vehicle.name, onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    stage

                    AppleCard {
                        VStack(spacing: 12) {
                            InfoRow(title: "车型", value: vehicle.name)
                            HairLine()
                            InfoRow(title: "VIN", value: vehicle.vinNo, mono: true)
                            HairLine()
                            InfoRow(
                                title: "车锁",
                                value: vehicle.isLocked ? "已上锁" : "未上锁",
                                valueColor: vehicle.isLocked ? Theme.label : Theme.orange
                            )
                            HairLine()
                            InfoRow(title: "电量", value: "\(vehicle.soc)%")
                        }
                    }

                    Text(hasModel ? "拖动旋转、双指缩放，查看整车姿态。" : "该车型暂未提供 3D 模型，左右拖动可查看车身姿态。")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 32)
            }
        }
        .onAppear {
            if let url = vehicle.model3DURL { loader.load(url) }
        }
    }

    // MARK: - 展示台

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0C1520), Color(hex: 0x18293C), Color(hex: 0x09131D)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.5), Color.black.opacity(0)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 130
                    )
                )
                .frame(width: 290, height: 52)
                .offset(y: 104)
                .blur(radius: 8)

            content

            VStack {
                HStack(spacing: 5) {
                    Image(systemName: hasModel ? "move.3d" : "hand.draw.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text(hasModel ? "可旋转 · 可缩放" : "左右拖动")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(10)

                Spacer(minLength: 0)
            }
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 8)
    }

    @ViewBuilder
    private var content: some View {
        if hasModel {
            switch loader.state {
            case .ready(let scene):
                ModelStage(scene: scene)
                    .frame(height: 340)
            case .failed(let message):
                VStack(spacing: 8) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 26, weight: .light))
                    Text("模型加载失败")
                        .font(Theme.footnote)
                    Text(message)
                        .font(.system(size: 10))
                        .opacity(0.7)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                }
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            default:
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在加载车辆模型")
                        .font(Theme.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        } else {
            PhotoTurntableStage(url: vehicle.imageURL)
                .frame(height: 300)
        }
    }
}

// MARK: - 官方模型

@MainActor
final class ModelLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(SCNScene)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func load(_ url: URL) {
        guard case .idle = state else { return }
        state = .loading

        Task {
            do {
                let local = try await Self.download(url)
                let scene = try SCNScene(url: local, options: nil)
                state = .ready(Self.normalized(scene))
            } catch {
                state = .failed(message(for: error))
            }
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? ModelError { return error.text }
        return error.localizedDescription
    }

    enum ModelError: Error {
        case unsupported(String)
        case empty

        var text: String {
            switch self {
            case .unsupported(let ext): return "暂不支持 .\(ext) 格式"
            case .empty: return "模型文件为空"
            }
        }
    }

    nonisolated private static func download(_ url: URL) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        if !["usdz", "usd", "scn", "dae", "obj"].contains(ext) {
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

    /// 统一模型尺寸与位置，避免不同车型比例差异导致看不见
    private static func normalized(_ scene: SCNScene) -> SCNScene {
        var minX = Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        var maxZ = -Float.greatestFiniteMagnitude

        scene.rootNode.enumerateChildNodes { node, _ in
            guard node.geometry != nil else { return }
            let (bMin, bMax) = node.boundingBox
            for x in [bMin.x, bMax.x] {
                for y in [bMin.y, bMax.y] {
                    for z in [bMin.z, bMax.z] {
                        let point = node.convertPosition(SCNVector3(x, y, z), to: nil)
                        if point.x < minX { minX = point.x }
                        if point.y < minY { minY = point.y }
                        if point.z < minZ { minZ = point.z }
                        if point.x > maxX { maxX = point.x }
                        if point.y > maxY { maxY = point.y }
                        if point.z > maxZ { maxZ = point.z }
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

        let scale = 1.7 / longest
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let centerZ = (minZ + maxZ) / 2

        let container = SCNNode()
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            container.addChildNode(child)
        }
        container.scale = SCNVector3(scale, scale, scale)
        container.position = SCNVector3(-centerX * scale, -centerY * scale, -centerZ * scale)

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 60
        camera.fieldOfView = 42
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0.35, 2.55)
        cameraNode.eulerAngles = SCNVector3(-0.1, 0, 0)

        let root = SCNScene()
        root.rootNode.addChildNode(container)
        root.rootNode.addChildNode(cameraNode)
        return root
    }
}

struct ModelStage: UIViewRepresentable {
    let scene: SCNScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true

        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.inertiaEnabled = true
        controller.maximumVerticalAngle = 72
        controller.minimumVerticalAngle = -18
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== scene { view.scene = scene }
    }
}

// MARK: - 无模型时的车图展示

private struct PhotoTurntableStage: View {
    let url: URL?

    @State private var drag: CGSize = .zero

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFit()
                            .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 12)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.car.fill")
                        .font(.system(size: 52, weight: .light))
                    Text("暂无车辆图片")
                        .font(Theme.footnote)
                }
                .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .rotation3DEffect(
            .degrees(Double(drag.width) / 16),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.6
        )
        .rotation3DEffect(
            .degrees(Double(-drag.height) / 34),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.6
        )
        .gesture(
            DragGesture()
                .onChanged { value in
                    drag = CGSize(
                        width: max(-120, min(120, value.translation.width)),
                        height: max(-60, min(60, value.translation.height))
                    )
                }
                .onEnded { _ in
                    withAnimation(Motion.spring) { drag = .zero }
                }
        )
        .padding(.horizontal, 26)
    }
}

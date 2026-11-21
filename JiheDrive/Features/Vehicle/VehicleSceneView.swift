import SceneKit
import SwiftUI
import UIKit

/// SceneKit 舞台：轨道相机 + 手势 + 自动缓慢自转。
/// 场景里需要一个名为 orbit → rig → camera 的节点链，由构建器负责。
struct VehicleSceneView: UIViewRepresentable {
    let scene: SCNScene
    var interactive: Bool = true
    var autoSpin: Bool = false
    var spinSpeed: Float = 0.22
    var onDrag: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.backgroundColor = .clear
        // 4x MSAA + 持续 60 帧会和录屏抢 GPU，空闲时 30 帧、关掉多重采样
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = interactive
        view.allowsCameraControl = false
        view.rendersContinuously = autoSpin
        view.isPlaying = true
        view.isJitteringEnabled = false

        context.coordinator.onDrag = onDrag
        context.coordinator.attach(view: view, autoSpin: autoSpin, speed: spinSpeed)
        if interactive { context.coordinator.installGestures() }
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onDrag = onDrag
        if view.scene !== scene {
            view.scene = scene
            context.coordinator.attach(view: view, autoSpin: autoSpin, speed: spinSpeed)
            if interactive { context.coordinator.installGestures() }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        var onDrag: ((Bool) -> Void)?
        private weak var view: SCNView?
        private var orbit: SCNNode?
        private var rig: SCNNode?
        private var display: CADisplayLink?
        private var lastTick: CFTimeInterval = 0
        private var azimuth: Float = 0
        private var elevation: Float = 0.15
        private var distance: Float = 2.5
        private var autoSpin = false
        private var spinSpeed: Float = 0.22
        private var idleUntil: CFTimeInterval = 0

        func attach(view: SCNView, autoSpin: Bool, speed: Float) {
            self.view = view
            self.autoSpin = autoSpin
            self.spinSpeed = speed
            orbit = view.scene?.rootNode.childNode(withName: "orbit", recursively: true)
            rig = orbit?.childNode(withName: "rig", recursively: false)
            azimuth = (orbit?.eulerAngles.y ?? 0) + 0.18
            apply()
            if autoSpin {
                start()
            } else {
                stop()
                view.rendersContinuously = false
                view.preferredFramesPerSecond = 30
            }
        }

        func installGestures() {
            guard let view else { return }
            view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = true
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(pinch)
        }

        func stop() {
            display?.invalidate()
            display = nil
        }

        private func start() {
            stop()
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            display = link
            lastTick = CACurrentMediaTime()
        }

        @objc private func tick(_ link: CADisplayLink) {
            let now = CACurrentMediaTime()
            let delta = min(now - lastTick, 0.05)
            lastTick = now
            guard autoSpin, now > idleUntil else { return }
            azimuth += spinSpeed * Float(delta)
            apply()
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            idleUntil = CACurrentMediaTime() + 4

            switch gesture.state {
            case .began:
                view.rendersContinuously = true
                view.preferredFramesPerSecond = 60
                onDrag?(true)
            case .changed:
                let move = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                azimuth -= Float(move.x) * 0.012
                elevation += Float(move.y) * 0.008
                elevation = min(max(elevation, -0.06), 0.62)
                apply()
            case .ended, .cancelled:
                onDrag?(false)
                let velocity = Float(gesture.velocity(in: view).x) * 0.0012
                guard abs(velocity) > 0.02 else {
                    view.rendersContinuously = autoSpin
                    view.preferredFramesPerSecond = 30
                    return
                }
                var step = velocity
                Task { @MainActor in
                    for _ in 0..<18 {
                        step *= 0.88
                        azimuth -= step
                        apply()
                        try? await Task.sleep(nanoseconds: 16_000_000)
                    }
                    view.rendersContinuously = autoSpin
                    view.preferredFramesPerSecond = 30
                }
            default:
                break
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            idleUntil = CACurrentMediaTime() + 4
            guard gesture.state == .changed else { return }
            distance /= Float(gesture.scale)
            distance = min(max(distance, 1.5), 4.6)
            gesture.scale = 1
            apply()
        }

        private func apply() {
            guard let orbit, let rig else { return }
            orbit.eulerAngles = SCNVector3(0, azimuth, 0)

            let height = sin(elevation) * distance
            let radius = cos(elevation) * distance
            rig.position = SCNVector3(0, height, radius)
            rig.look(
                at: SCNVector3(0, 0, 0),
                up: SCNVector3(0, 1, 0),
                localFront: SCNVector3(0, 0, -1)
            )
        }
    }
}

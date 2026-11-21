import SwiftUI
import UIKit
import WebKit

/// 用 model-viewer 渲染 GLB 车模（与安卓版同一套资源与相机参数）。
/// GLB 通过自定义 scheme 提供，避免 file:// 的跨域限制。
struct ModelViewerWebView: UIViewRepresentable {
    let glbFile: URL
    var reuseKey: String = ""
    var interactive: Bool = true
    var autoRotate: Bool = false
    var resetToken: Int = 0
    var onDrag: ((Bool) -> Void)? = nil
    var onOrbitChanged: ((Bool) -> Void)? = nil
    var onReady: (() -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.reuseKey = reuseKey
        context.coordinator.onDrag = onDrag
        context.coordinator.onOrbitChanged = onOrbitChanged
        context.coordinator.onReady = onReady
        context.coordinator.resetToken = resetToken

        if let pooled = ModelViewerPool.view(for: reuseKey) {
            pooled.removeFromSuperview()
            bind(pooled, context: context)
            if pooled.url != nil {
                context.coordinator.markLoaded(glbFile, interactive: interactive)
                DispatchQueue.main.async { context.coordinator.onReady?() }
            } else {
                context.coordinator.load(into: pooled, glbFile: glbFile, interactive: interactive, autoRotate: autoRotate)
            }
            return pooled
        }

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.add(context.coordinator, name: "orbit")
        configuration.setURLSchemeHandler(context.coordinator.scheme, forURLScheme: ModelSchemeHandler.scheme)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clipsToBounds = false
        view.scrollView.backgroundColor = .clear
        view.scrollView.clipsToBounds = false
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.delaysContentTouches = false
        view.scrollView.canCancelContentTouches = false
        view.isUserInteractionEnabled = interactive
        view.navigationDelegate = context.coordinator
        installGestures(on: view, coordinator: context.coordinator)
        context.coordinator.load(into: view, glbFile: glbFile, interactive: interactive, autoRotate: autoRotate)
        ModelViewerPool.store(view, for: reuseKey)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.isUserInteractionEnabled = interactive
        context.coordinator.reuseKey = reuseKey
        context.coordinator.onDrag = onDrag
        context.coordinator.onOrbitChanged = onOrbitChanged
        context.coordinator.onReady = onReady
        if view.url == nil {
            context.coordinator.load(into: view, glbFile: glbFile, interactive: interactive, autoRotate: autoRotate)
        } else {
            context.coordinator.markLoaded(glbFile, interactive: interactive)
        }
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            view.evaluateJavaScript("window.jhResetOrbit && window.jhResetOrbit()", completionHandler: nil)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.removeFromSuperview()
        ModelViewerPool.store(uiView, for: coordinator.reuseKey)
    }

    private func bind(_ view: WKWebView, context: Context) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "orbit")
        view.configuration.userContentController.add(context.coordinator, name: "orbit")
        view.navigationDelegate = context.coordinator
        view.isUserInteractionEnabled = interactive
        installGestures(on: view, coordinator: context.coordinator)
    }

    private func installGestures(on view: WKWebView, coordinator: Coordinator) {
        view.gestureRecognizers?.forEach { rec in
            if rec is UIPanGestureRecognizer || rec is UITapGestureRecognizer {
                view.removeGestureRecognizer(rec)
            }
        }
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleOuterPan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = coordinator
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        tap.numberOfTapsRequired = 2
        tap.cancelsTouchesInView = false
        tap.delegate = coordinator
        view.addGestureRecognizer(tap)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
        let scheme = ModelSchemeHandler()
        var onDrag: ((Bool) -> Void)?
        var onOrbitChanged: ((Bool) -> Void)?
        var onReady: (() -> Void)?
        var resetToken = 0
        var reuseKey = ""
        private var loadedFile: URL?

        private var loadedInteractive: Bool?

        func markLoaded(_ glbFile: URL, interactive: Bool) {
            loadedFile = glbFile
            loadedInteractive = interactive
        }

        @objc func handleOuterPan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                onDrag?(true)
            default:
                onDrag?(false)
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? WKWebView else { return }
            view.evaluateJavaScript("window.jhResetOrbit && window.jhResetOrbit()", completionHandler: nil)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func load(into view: WKWebView, glbFile: URL, interactive: Bool, autoRotate: Bool) {
            guard loadedFile != glbFile || loadedInteractive != interactive else { return }
            guard let data = try? Data(contentsOf: glbFile), data.count > 1024 else { return }
            guard let script = ModelViewerAsset.shared.scriptData else { return }

            loadedFile = glbFile
            loadedInteractive = interactive
            scheme.replace(glb: data, script: script)

            let html = ModelViewerAsset.html(interactive: interactive, autoRotate: autoRotate)
            let base = URL(string: "\(ModelSchemeHandler.scheme)://local/index.html")!
            view.loadHTMLString(html, baseURL: base)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.onReady?()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "orbit" else { return }
            let rotated: Bool
            if let flag = message.body as? Bool {
                rotated = flag
            } else if let map = message.body as? [String: Any], let flag = map["rotated"] as? Bool {
                rotated = flag
            } else {
                rotated = true
            }
            DispatchQueue.main.async { [weak self] in
                self?.onOrbitChanged?(rotated)
            }
        }
    }
}

/// 同一 VIN 复用 WKWebView，切页/刷新不再重新解析 GLB
enum ModelViewerPool {
    private static var views: [String: WKWebView] = [:]

    static func view(for key: String) -> WKWebView? {
        guard !key.isEmpty else { return nil }
        return views[key]
    }

    static func store(_ view: WKWebView, for key: String) {
        guard !key.isEmpty else { return }
        views[key] = view
    }
}

// MARK: - 资源

enum ModelViewerAsset {
    static let shared = ScriptStore()

    final class ScriptStore {
        let scriptData: Data?

        init() {
            scriptData = Bundle.main.url(forResource: "model-viewer.min", withExtension: "js")
                .flatMap { try? Data(contentsOf: $0) }
        }
    }

    /// 与安卓版 VehicleModelCamera 对齐的相机参数；interactive 时开 camera-controls 可拖拽
    static func html(interactive: Bool, autoRotate: Bool) -> String {
        let orbit = "-6.5deg 75deg 5.15m"
        let target = "0.02m 0.58m auto"
        let minOrbit = interactive ? "auto 70deg 2.8m" : "auto 80deg 4.8m"
        let maxOrbit = interactive ? "auto 95deg 7.2m" : "auto 80deg 5.4m"
        let rotation = autoRotate ? "auto-rotate rotation-per-second=\"14deg\"" : ""
        let controls = interactive ? "camera-controls touch-action=\"none\"" : "interaction-prompt=\"none\""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <script type="module" src="model-viewer.min.js"></script>
        <style>
          html, body {
            margin: 0; padding: 0; width: 100%; height: 100%;
            background: transparent; overflow: hidden;
            touch-action: none;
          }
          model-viewer {
            width: 100%; height: 100%;
            background: transparent;
            --progress-bar-height: 0px;
            --progress-bar-color: transparent;
            touch-action: none;
          }
          model-viewer::part(default-progress-bar) { display: none; }
        </style>
        </head>
        <body>
        <model-viewer
          id="viewer"
          src="model.glb"
          loading="eager"
          camera-orbit="\(orbit)"
          camera-target="\(target)"
          field-of-view="26deg"
          min-camera-orbit="\(minOrbit)"
          max-camera-orbit="\(maxOrbit)"
          shadow-intensity="0"
          exposure="1.05"
          environment-image="neutral"
          reveal="auto"
          disable-pan
          minimum-render-scale="0.5"
          interpolation-decay="40"
          \(controls)
          \(rotation)>
        </model-viewer>
        <script>
          const viewer = document.getElementById('viewer');
          const DEFAULT_ORBIT = '\(orbit)';
          const DEFAULT_TARGET = '\(target)';
          let resetFrame = 0;
          viewer.addEventListener('load', () => {
            if (!viewer.hasAttribute('auto-rotate') && viewer.pause) viewer.pause();
          });
          viewer.addEventListener('camera-change', (ev) => {
            const source = ev && ev.detail && ev.detail.source;
            if (source === 'user-interaction') {
              if (resetFrame) { cancelAnimationFrame(resetFrame); resetFrame = 0; }
              if (window.webkit && window.webkit.messageHandlers.orbit) {
                window.webkit.messageHandlers.orbit.postMessage({ rotated: true });
              }
            }
          });
          viewer.addEventListener('dblclick', () => {
            if (window.jhResetOrbit) window.jhResetOrbit();
          });
          function parseOrbit(text) {
            const p = String(text).trim().split(' ').filter(Boolean);
            const toRad = (v) => {
              const x = parseFloat(v);
              if (!isFinite(x)) return 0;
              return String(v).indexOf('rad') >= 0 ? x : x * Math.PI / 180;
            };
            const toM = (v) => {
              const x = parseFloat(v);
              return isFinite(x) ? x : 0;
            };
            return { theta: toRad(p[0]), phi: toRad(p[1]), radius: toM(p[2]) };
          }
          function shortest(from, to) {
            let d = to - from;
            while (d > Math.PI) d -= Math.PI * 2;
            while (d < -Math.PI) d += Math.PI * 2;
            return d;
          }
          window.jhResetOrbit = () => {
            if (resetFrame) cancelAnimationFrame(resetFrame);
            const live = viewer.getCameraOrbit && viewer.getCameraOrbit();
            const start = (live && isFinite(live.theta) && isFinite(live.phi) && isFinite(live.radius))
              ? { theta: live.theta, phi: live.phi, radius: live.radius }
              : parseOrbit(DEFAULT_ORBIT);
            const goal = parseOrbit(DEFAULT_ORBIT);
            const dTheta = shortest(start.theta, goal.theta);
            const dPhi = goal.phi - start.phi;
            const dRadius = goal.radius - start.radius;
            const dur = 680;
            const t0 = performance.now();
            const tick = (now) => {
              const t = Math.min(1, (now - t0) / dur);
              const e = 1 - Math.pow(1 - t, 3);
              viewer.cameraOrbit = (start.theta + dTheta * e) + 'rad ' + (start.phi + dPhi * e) + 'rad ' + (start.radius + dRadius * e) + 'm';
              viewer.cameraTarget = DEFAULT_TARGET;
              if (viewer.jumpCameraToGoal) viewer.jumpCameraToGoal();
              if (t < 1) {
                resetFrame = requestAnimationFrame(tick);
                return;
              }
              resetFrame = 0;
              viewer.cameraOrbit = DEFAULT_ORBIT;
              viewer.cameraTarget = DEFAULT_TARGET;
              if (viewer.jumpCameraToGoal) viewer.jumpCameraToGoal();
              if (window.webkit && window.webkit.messageHandlers.orbit) {
                window.webkit.messageHandlers.orbit.postMessage({ rotated: false });
              }
            };
            resetFrame = requestAnimationFrame(tick);
          };
        </script>
        </body>
        </html>
        """
    }
}

// MARK: - 本地资源服务

final class ModelSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "jhmodel"

    private var files: [String: (data: Data, mime: String)] = [:]
    private let lock = NSLock()

    func replace(glb: Data, script: Data) {
        lock.lock()
        files["/model.glb"] = (glb, "model/gltf-binary")
        files["/model-viewer.min.js"] = (script, "text/javascript")
        files["/index.html"] = (Data(), "text/html")
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        lock.lock()
        let entry = files[url.path]
        lock.unlock()

        guard let entry else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let headers = [
            "Content-Type": entry.mime,
            "Content-Length": "\(entry.data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ]
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            urlSchemeTask.didFailWithError(URLError(.badServerResponse))
            return
        }

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(entry.data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

// MARK: - GLB 下载缓存

enum GLBModelStore {
    /// 缓存名带 strip 版本号，节点清洗规则变更时自动换文件
    private static let stripTag = "s2"

    static func existing(for remote: URL) -> URL? {
        let target = destination(for: remote)
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
           size > 1024 {
            return target
        }
        return nil
    }

    private static func destination(for remote: URL) -> URL {
        let dir = ResourceCache.directory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = ResourceCache.hash(remote.absoluteString)
        return dir.appendingPathComponent("\(key)-\(stripTag).glb")
    }

    static func localFile(for remote: URL) async throws -> URL {
        let target = destination(for: remote)
        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
           size > 1024 {
            return target
        }

        guard let source = await ResourceCache.file(for: remote, folder: "models") else {
            throw URLError(.cannotOpenFile)
        }
        let raw = try Data(contentsOf: source)
        let cleaned = GLBNodeStripper.strip(raw)
        try? FileManager.default.removeItem(at: target)
        try cleaned.write(to: target, options: .atomic)
        return target
    }
}

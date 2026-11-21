import SwiftUI
import UIKit
import WebKit

/// 用 model-viewer 渲染 GLB 车模（与安卓版同一套资源与相机参数）。
/// GLB 通过自定义 scheme 提供，避免 file:// 的跨域限制。
struct ModelViewerWebView: UIViewRepresentable {
    let glbFile: URL
    var interactive: Bool = true
    var autoRotate: Bool = false
    var onDrag: ((Bool) -> Void)? = nil
    var onReady: (() -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.setURLSchemeHandler(context.coordinator.scheme, forURLScheme: ModelSchemeHandler.scheme)

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.delaysContentTouches = false
        view.scrollView.canCancelContentTouches = false
        view.isUserInteractionEnabled = interactive
        view.navigationDelegate = context.coordinator

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleOuterPan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        context.coordinator.onDrag = onDrag
        context.coordinator.onReady = onReady
        context.coordinator.load(into: view, glbFile: glbFile, interactive: interactive, autoRotate: autoRotate)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.isUserInteractionEnabled = interactive
        context.coordinator.onDrag = onDrag
        context.coordinator.onReady = onReady
        context.coordinator.load(into: view, glbFile: glbFile, interactive: interactive, autoRotate: autoRotate)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
        let scheme = ModelSchemeHandler()
        var onDrag: ((Bool) -> Void)?
        var onReady: (() -> Void)?
        private var loadedFile: URL?

        private var loadedInteractive: Bool?

        @objc func handleOuterPan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                onDrag?(true)
            default:
                onDrag?(false)
            }
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
        let orbit = "-6.5deg 83.06deg 3.086m"
        let target = "-0.02m auto auto"
        // 可拖拽时放宽方位角；仰角仍锁在约 83°，避免翻车底
        let minOrbit = interactive ? "auto 70deg 2.2m" : "auto 83.06deg 2.53m"
        let maxOrbit = interactive ? "auto 95deg 4.2m" : "auto 83.06deg 3.86m"
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
            width: 100%; height: 100%; background: transparent;
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
          field-of-view="28deg"
          min-camera-orbit="\(minOrbit)"
          max-camera-orbit="\(maxOrbit)"
          shadow-intensity="0"
          exposure="1.05"
          environment-image="neutral"
          reveal="auto"
          disable-pan
          minimum-render-scale="0.5"
          \(controls)
          \(rotation)>
        </model-viewer>
        <script>
          const viewer = document.getElementById('viewer');
          viewer.addEventListener('load', () => {
            if (!viewer.hasAttribute('auto-rotate') && viewer.pause) viewer.pause();
          });
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

    static func localFile(for remote: URL) async throws -> URL {
        let dir = ResourceCache.directory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = ResourceCache.hash(remote.absoluteString)
        let target = dir.appendingPathComponent("\(key)-\(stripTag).glb")

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

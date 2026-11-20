import SwiftUI
import UIKit
import WebKit

/// 用 model-viewer 渲染 GLB 车模（与安卓版同一套资源与相机参数）。
/// GLB 通过自定义 scheme 提供，避免 file:// 的跨域限制。
struct ModelViewerWebView: UIViewRepresentable {
    let glbFile: URL
    var interactive: Bool = true
    var autoRotate: Bool = false

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
        view.isUserInteractionEnabled = interactive
        view.navigationDelegate = context.coordinator

        context.coordinator.load(into: view, glbFile: glbFile, autoRotate: autoRotate)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.isUserInteractionEnabled = interactive
        context.coordinator.load(into: view, glbFile: glbFile, autoRotate: autoRotate)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let scheme = ModelSchemeHandler()
        private var loadedFile: URL?

        func load(into view: WKWebView, glbFile: URL, autoRotate: Bool) {
            guard loadedFile != glbFile else { return }
            guard let data = try? Data(contentsOf: glbFile), data.count > 1024 else { return }
            guard let script = ModelViewerAsset.shared.scriptData else { return }

            loadedFile = glbFile
            scheme.replace(glb: data, script: script)

            let html = ModelViewerAsset.html(autoRotate: autoRotate)
            let base = URL(string: "\(ModelSchemeHandler.scheme)://local/index.html")!
            view.loadHTMLString(html, baseURL: base)
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

    /// 与安卓版 VehicleModelCamera 对齐的相机参数
    static func html(autoRotate: Bool) -> String {
        let orbit = "0.28deg 83.06deg 3.086m"
        let target = "-0.02m auto auto"
        let minOrbit = "auto 83.06deg 2.53m"
        let maxOrbit = "auto 83.06deg 3.86m"
        let rotation = autoRotate ? "auto-rotate rotation-per-second=\"14deg\"" : ""

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
          }
          model-viewer {
            width: 100%; height: 100%; background: transparent;
            --progress-bar-height: 0px;
            --progress-bar-color: transparent;
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
          \(rotation)>
        </model-viewer>
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
        let name = "vehicle-\(abs(remote.absoluteString.hashValue))-\(stripTag).glb"
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let target = directory.appendingPathComponent(name)

        if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
           size > 1024 {
            return target
        }

        let (temp, response) = try await URLSession.shared.download(from: remote)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }

        let raw = try Data(contentsOf: temp)
        let cleaned = GLBNodeStripper.strip(raw)
        try? FileManager.default.removeItem(at: target)
        try cleaned.write(to: target, options: .atomic)
        try? FileManager.default.removeItem(at: temp)
        return target
    }
}

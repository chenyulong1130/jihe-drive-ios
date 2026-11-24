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
    /// 页面不在前台时置 false：暂停渲染，翻页不吃 WebGL
    var active: Bool = true
    var lightsOn: Bool? = nil        // 全车灯（不含转向灯）：深色主题 true / 浅色 false
    var onDrag: ((Bool) -> Void)? = nil
    var onOrbitChanged: ((Bool) -> Void)? = nil
    var onReady: (() -> Void)? = nil
    var seatOpen: Bool = false       // 坐垫目标状态
    var seatToken: Int = 0           // 每次变更 +1 触发下发
    var onSeatDebug: ((String) -> Void)? = nil        // 坐垫挂载诊断（真机排查"点了没反应"）
    var onSeatChange: ((Bool) -> Void)? = nil        // JS 即时回传坐垫开关状态
    var onSeatProgress: ((Double) -> Void)? = nil    // 0~1 开合进度

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.reuseKey = reuseKey
        context.coordinator.onDrag = onDrag
        context.coordinator.onOrbitChanged = onOrbitChanged
        context.coordinator.onReady = onReady
        context.coordinator.onSeatDebug = onSeatDebug
        context.coordinator.onSeatChange = onSeatChange
        context.coordinator.onSeatProgress = onSeatProgress
        context.coordinator.resetToken = resetToken
        context.coordinator.active = active
        context.coordinator.desiredLightsOn = lightsOn
        context.coordinator.desiredSeatOpen = seatOpen
        context.coordinator.desiredSeatToken = seatToken

        if let pooled = ModelViewerPool.view(for: reuseKey) {
            pooled.removeFromSuperview()
            bind(pooled, context: context)
            if !ModelViewerPool.isStale(reuseKey),
               pooled.url != nil, ModelViewerPool.file(for: reuseKey) == glbFile {
                context.coordinator.markLoaded(glbFile, interactive: interactive)
                context.coordinator.applyDesired(pooled, force: true) // 复用页补发坐垫/灯光状态
                DispatchQueue.main.async { context.coordinator.onReady?() }
            } else {
                context.coordinator.load(into: pooled, glbFile: glbFile, interactive: interactive, autoRotate: autoRotate, force: true)
            }
            ModelViewerPool.clearStale(reuseKey)
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
        ModelViewerPool.store(view, for: reuseKey, file: glbFile)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.isUserInteractionEnabled = interactive
        context.coordinator.reuseKey = reuseKey
        context.coordinator.onDrag = onDrag
        context.coordinator.onOrbitChanged = onOrbitChanged
        context.coordinator.onReady = onReady
        context.coordinator.onSeatDebug = onSeatDebug
        context.coordinator.onSeatChange = onSeatChange
        context.coordinator.onSeatProgress = onSeatProgress
        context.coordinator.desiredLightsOn = lightsOn
        context.coordinator.desiredSeatOpen = seatOpen
        context.coordinator.desiredSeatToken = seatToken
        context.coordinator.applyDesired(view, force: false) // 状态变化即时下发（token 变化触发）
        if context.coordinator.processDied
            || ModelViewerPool.file(for: reuseKey) != glbFile
            || (view.url == nil && context.coordinator.currentFile == nil) {
            // 进程被杀 / 页面失效时强制重载，否则一直白屏。
            // currentFile 只在 load() 里同步赋值，用它区分「首次创建还没提交」和「真失效」。
            context.coordinator.processDied = false
            ModelViewerPool.clearStale(reuseKey)
            context.coordinator.load(into: view, glbFile: glbFile, interactive: interactive, autoRotate: autoRotate, force: true)
        } else {
            context.coordinator.markLoaded(glbFile, interactive: interactive)
        }
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            view.evaluateJavaScript("window.jhResetOrbit && window.jhResetOrbit()", completionHandler: nil)
        }
        if context.coordinator.active != active {
            context.coordinator.active = active
            applyActive(view, active: active)
        }
    }

    /// 暂停/恢复 model-viewer 渲染；页面还没就绪时是空操作，didFinish 会再补一次
    private func applyActive(_ view: WKWebView, active: Bool) {
        view.evaluateJavaScript(
            "window.jhSetPaused && window.jhSetPaused(\(active ? "false" : "true"))",
            completionHandler: nil
        )
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.removeFromSuperview()
        ModelViewerPool.store(uiView, for: coordinator.reuseKey, file: coordinator.currentFile)
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
        var onSeatDebug: ((String) -> Void)?
        var onSeatChange: ((Bool) -> Void)?
        var onSeatProgress: ((Double) -> Void)?
        var resetToken = 0
        var active = true
        var reuseKey = ""
        var desiredLightsOn: Bool?
        var desiredSeatOpen: Bool = false
        var desiredSeatToken: Int = 0
        private var appliedLights: Bool?
        private var appliedSeatToken: Int?
        private var loadedFile: URL?
        private var loadedInteractive: Bool?
        var processDied = false
        var currentFile: URL? { loadedFile }

        /// 坐垫/灯光状态即时下发；force=true 用于页面就绪/复用后补发
        func applyDesired(_ view: WKWebView, force: Bool) {
            if force || appliedLights != desiredLightsOn {
                appliedLights = desiredLightsOn
                if let on = desiredLightsOn {
                    view.evaluateJavaScript("window.jhSetLights && window.jhSetLights(\(on))", completionHandler: nil)
                }
            }
            if force || appliedSeatToken != desiredSeatToken {
                appliedSeatToken = desiredSeatToken
                view.evaluateJavaScript("window.jhSetSeat && window.jhSetSeat(\(desiredSeatOpen))", completionHandler: nil)
                reportSeatDebug(view)
            }
        }

        /// 回读坐垫挂载状态（pivot 是否建立、命中哪个节点）
        func reportSeatDebug(_ view: WKWebView) {
            guard let onSeatDebug else { return }
            view.evaluateJavaScript(
                "JSON.stringify(window.jhSeatDebug ? window.jhSeatDebug() : {pivot:false,node:'no-fn'})"
            ) { value, _ in
                if let text = value as? String { onSeatDebug(text) }
            }
        }

        func markLoaded(_ glbFile: URL, interactive: Bool) {
            loadedFile = glbFile
            loadedInteractive = interactive
            ModelViewerPool.remember(file: glbFile, for: reuseKey)
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

        func load(into view: WKWebView, glbFile: URL, interactive: Bool, autoRotate: Bool, force: Bool = false) {
            guard force || loadedFile != glbFile || loadedInteractive != interactive else { return }
            guard let data = try? Data(contentsOf: glbFile), data.count > 1024 else { return }
            guard let script = ModelViewerAsset.shared.scriptData else { return }

            loadedFile = glbFile
            loadedInteractive = interactive
            ModelViewerPool.remember(file: glbFile, for: reuseKey)
            var extra: [String: (data: Data, mime: String)] = [:]
            if let d = ModelViewerAsset.shared.threeData { extra["/three.module.min.js"] = (d, "text/javascript") }
            if let d = ModelViewerAsset.shared.gltfLoaderData { extra["/GLTFLoader.js"] = (d, "text/javascript") }
            if let d = ModelViewerAsset.shared.orbitControlsData { extra["/OrbitControls.js"] = (d, "text/javascript") }
            if let d = ModelViewerAsset.shared.roomEnvironmentData { extra["/RoomEnvironment.js"] = (d, "text/javascript") }
            if let d = ModelViewerAsset.shared.bufferUtilsData { extra["/BufferGeometryUtils.js"] = (d, "text/javascript") }
            // 每次加载用唯一 token 子路径：所有页面曾经共用 jhmodel://local/model.glb，
            // WKWebView 的 URL 缓存跨实例共享，切车后新页面拉 model.glb 会命中
            // 上一台车的缓存响应——表现为"切车后 3D 还是第一台车的模型"。
            // token 化后每台车的资源 URL 都不同，缓存永不串台。
            let token = String(UUID().uuidString.prefix(8)).lowercased()
            scheme.replace(token: token, glb: data, script: script, extra: extra)

            let html = ModelViewerAsset.html(interactive: interactive, autoRotate: autoRotate)
            let base = URL(string: "\(ModelSchemeHandler.scheme)://local/\(token)/index.html")!
            view.loadHTMLString(html, baseURL: base)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            processDied = false
            ModelViewerPool.clearStale(reuseKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.applyDesired(webView, force: true) // 页面就绪后补发当前坐垫/灯光状态
                if !self.active {
                    webView.evaluateJavaScript("window.jhSetPaused && window.jhSetPaused(true)", completionHandler: nil)
                }
            }
            // 正常情况由 JS 的 ready 消息揭 loading；这里兜底防止消息丢失一直转圈
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.onReady?()
            }
        }

        /// 挂后台久了 WebContent 进程被系统回收，页面只剩白底；
        /// 直接 reload 自救（此时往往不在 SwiftUI 更新周期里），并标记 stale 兜底
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            processDied = true
            ModelViewerPool.markStale(reuseKey)
            webView.reload()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "orbit" else { return }
            var rotated: Bool?
            var seatOpen: Bool?
            var seatProgress: Double?
            var modelReady = false
            if let map = message.body as? [String: Any] {
                rotated = map["rotated"] as? Bool
                seatOpen = map["seatOpen"] as? Bool
                seatProgress = map["progress"] as? Double
                modelReady = (map["ready"] as? Bool) == true
            } else if let flag = message.body as? Bool {
                rotated = flag
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if modelReady {
                    self.onReady?()
                    // 模型就绪后回读坐垫挂载状态（真机排查"点了模型不动"）
                    if let view = message.webView { self.reportSeatDebug(view) }
                }
                if let seatProgress { self.onSeatProgress?(seatProgress) }
                if let seatOpen { self.onSeatChange?(seatOpen) }
                if let rotated { self.onOrbitChanged?(rotated) }
            }
        }
    }
}

/// 同一 VIN 复用 WKWebView，切页/刷新不再重新解析 GLB
enum ModelViewerPool {
    private static var views: [String: WKWebView] = [:]
    private static var files: [String: URL] = [:]
    /// WebContent 进程被回收的复用视图，取出时必须强制重载
    private static var staleKeys: Set<String> = []

    static func view(for key: String) -> WKWebView? {
        guard !key.isEmpty else { return nil }
        return views[key]
    }

    static func file(for key: String) -> URL? {
        guard !key.isEmpty else { return nil }
        return files[key]
    }

    static func markStale(_ key: String) {
        guard !key.isEmpty else { return }
        staleKeys.insert(key)
    }

    static func isStale(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return staleKeys.contains(key)
    }

    static func clearStale(_ key: String) {
        guard !key.isEmpty else { return }
        staleKeys.remove(key)
    }

    static func remember(file: URL, for key: String) {
        guard !key.isEmpty else { return }
        files[key] = file
    }

    static func store(_ view: WKWebView, for key: String, file: URL? = nil) {
        guard !key.isEmpty else { return }
        views[key] = view
        if let file {
            files[key] = file
        }
    }
}

// MARK: - 资源

enum ModelViewerAsset {
    static let shared = ScriptStore()

    final class ScriptStore {
        let scriptData: Data?              // model-viewer.min.js（地图回放仍用）
        let threeData: Data?               // three.js 自绘 viewer（看车/首页 3D）
        let gltfLoaderData: Data?
        let orbitControlsData: Data?
        let roomEnvironmentData: Data?
        let bufferUtilsData: Data?

        init() {
            func load(_ name: String, _ ext: String) -> Data? {
                Bundle.main.url(forResource: name, withExtension: ext)
                    .flatMap { try? Data(contentsOf: $0) }
            }
            scriptData = load("model-viewer.min", "js")
            threeData = load("three.module.min", "js")
            gltfLoaderData = load("GLTFLoader", "js")
            orbitControlsData = load("OrbitControls", "js")
            roomEnvironmentData = load("RoomEnvironment", "js")
            bufferUtilsData = load("BufferGeometryUtils", "js")
        }
    }

    /// three.js 自绘 viewer（three r160 + GLTFLoader + OrbitControls + RoomEnvironment）。
    /// 相机参数与原 model-viewer 对齐：orbit 0deg 90deg 4.35m / target 0.02 0.74 / fov 26。
    /// JS 桥：jhSetSeat(坐垫开合) / jhSeatState / jhSetLights(全车灯自发光+近光侧散光扇,不含转向灯) / jhResetOrbit。
    static func html(interactive: Bool, autoRotate: Bool) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <script type="importmap">
        {"imports": {"three": "./three.module.min.js"}}
        </script>
        <style>
          html, body {
            margin: 0; padding: 0; width: 100%; height: 100%;
            background: transparent; overflow: hidden;
            touch-action: none;
          }
          #viewer { width: 100%; height: 100%; }
          #viewer canvas { display: block; touch-action: none; }
        </style>
        </head>
        <body>
        <div id="viewer"></div>
        <script type="module">
        import * as THREE from 'three';
        import { GLTFLoader } from './GLTFLoader.js';
        import { OrbitControls } from './OrbitControls.js';

        const INTERACTIVE = \(interactive);
        const AUTO_ROTATE = \(autoRotate);
        const host = document.getElementById('viewer');
        const scene = new THREE.Scene();
        scene.background = null; // 透明，露出 SwiftUI 渐变舞台

        const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
        renderer.setClearColor(0x000000, 0);
        renderer.toneMapping = THREE.ACESFilmicToneMapping;
        renderer.toneMappingExposure = 1.05;
        renderer.outputColorSpace = THREE.SRGBColorSpace;
        host.appendChild(renderer.domElement);

        // 金属漆车身（metalness 高）的颜色几乎全靠环境反射成像，漫射灯（方向光/半球光）
        // 对它基本无效——这就是之前怎么加补光都治不了"侧边死黑"的原因。
        // RoomEnvironment 自带窗户与明暗面，车侧转到背对亮窗的方向就反射出深色。
        // 换成四面均匀的渐变摄影棚环境球：顶部白 1.0 → 底部灰 0.45，
        // 任何朝向都有反射光，无方向性阴影（对齐 model-viewer neutral 的观感）。
        const pmrem = new THREE.PMREMGenerator(renderer);
        const envGeo = new THREE.SphereGeometry(10, 32, 16);
        const envPos = envGeo.attributes.position;
        const envColors = [];
        for (let i = 0; i < envPos.count; i++) {
          const t = (envPos.getY(i) / 10 + 1) / 2; // 0=底部 → 1=顶部
          const v = 0.45 + 0.55 * t;
          envColors.push(v, v, v);
        }
        envGeo.setAttribute('color', new THREE.Float32BufferAttribute(envColors, 3));
        const envScene = new THREE.Scene();
        envScene.add(new THREE.Mesh(envGeo,
          new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.BackSide })));
        scene.environment = pmrem.fromScene(envScene, 0.04).texture;
        pmrem.dispose();
        // 半球光只提供上下过渡（顶白地灰），不放任何方向光——方向光必然造成明暗面
        scene.add(new THREE.HemisphereLight(0xffffff, 0x555555, 1.2));

        // 相机与视点同时抬高 0.14：模型在画面里整体下移，避免车顶贴着上边缘
        const DEFAULT_POS = new THREE.Vector3(0.02, 0.88, 4.35);
        const DEFAULT_TARGET = new THREE.Vector3(0.02, 0.88, 0);
        const camera = new THREE.PerspectiveCamera(26, 1, 0.1, 100);
        camera.position.copy(DEFAULT_POS);

        const controls = new OrbitControls(camera, renderer.domElement);
        controls.target.copy(DEFAULT_TARGET);
        controls.enableDamping = true;
        controls.dampingFactor = 0.08;
        controls.enablePan = false;
        controls.enableRotate = INTERACTIVE;
        controls.enableZoom = INTERACTIVE;
        const D2R = Math.PI / 180;
        controls.minPolarAngle = 84 * D2R;
        controls.maxPolarAngle = 94 * D2R;
        controls.minDistance = INTERACTIVE ? 2.5 : 4.1;
        controls.maxDistance = INTERACTIVE ? 6.6 : 4.7;
        controls.autoRotate = AUTO_ROTATE;
        controls.autoRotateSpeed = 2.33; // ≈14°/s，对齐原 rotation-per-second

        function post(msg) {
          if (window.webkit && window.webkit.messageHandlers.orbit) {
            window.webkit.messageHandlers.orbit.postMessage(msg);
          }
        }

        let needsRender = true;
        controls.addEventListener('change', () => { needsRender = true; });
        controls.addEventListener('start', () => { if (INTERACTIVE) post({ rotated: true }); });

        function resize() {
          const w = host.clientWidth || 1;
          const h = host.clientHeight || 1;
          // 先设像素比再 setSize：setSize 默认更新 canvas 的 CSS 尺寸为 w×h，
          // 否则 canvas 按「属性像素数」显示，3x 屏上被放大 2 倍——车又大又糊
          renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 3));
          renderer.setSize(w, h);
          camera.aspect = w / h;
          camera.updateProjectionMatrix();
          needsRender = true;
        }
        window.addEventListener('resize', resize);
        // 容器尺寸变化（弹层档位、首帧布局）也要重排，只靠 window.resize 不够
        if (window.ResizeObserver) new ResizeObserver(resize).observe(host);
        resize();

        // ---------- 坐垫：挂 SeatPivot 铰链节点，0.6s 缓动开合 ----------
        // 节点名随车型：AE4=FR-Seat-T；AE8=SEAT-Seat-T（与 SEAT-SeatTex-T 同挂 SEAT 组，转父组才整体掀）
        // 车头朝 -x（AE4/AE8 世界坐标实测：大灯/前轮 x<0，尾灯/后轮 x>0），坐垫沿 x 长 0.7~0.8m，
        // 铰链 = 坐垫包围盒前缘(min.x) + 底部(min.y) + 横向中点(z)，绕 z 轴正转尾部上抬。
        const OPEN_ANGLE = 38 * D2R; // 55° 时尾巴前扫过大，观感像坐垫往前飞
        let pivot = null;
        let seatAnim = null;
        let seatTarget = false; // 最近一次 jhSetSeat 的目标，模型就绪前先记下
        let seatNodeName = '';  // 命中的坐垫节点名，空=没找到（诊断用）

        // 兜底搜索：精确名都没有时，取名字含 seat 且体积最大的部件（排除贴图/材质节点）
        function findSeatNode(root) {
          const exact = root.getObjectByName('FR-Seat-T') || root.getObjectByName('SEAT-Seat-T');
          if (exact) return exact;
          let best = null, bestVol = 0;
          root.traverse((o) => {
            const n = String(o.name || '');
            if (!/seat/i.test(n)) return;
            if (/tex|texture|material|mat$|light/i.test(n)) return;
            const box = new THREE.Box3().setFromObject(o);
            if (box.isEmpty()) return;
            const sz = box.getSize(new THREE.Vector3());
            const vol = sz.x * sz.y * sz.z;
            if (vol > bestVol) { bestVol = vol; best = o; }
          });
          return best;
        }

        function setupSeat(root) {
          const node = findSeatNode(root);
          if (!node) { seatNodeName = ''; return; }
          seatNodeName = node.name || '?'
          const seat = (node.name === 'SEAT-Seat-T' && node.parent) ? node.parent : node;
          seat.updateWorldMatrix(true, false);
          const box = new THREE.Box3().setFromObject(seat);
          // 铰链不能放在 bbox 最前缘：坐垫总成前缘伸进踏板区，绕它转整块坐垫会往前扫
          // 30cm+（用户看到"向前移动"）。收到 15% 长度处，前扫收敛到 ~12cm，观感贴近真车。
          const hingeWorld = new THREE.Vector3(
            box.min.x + (box.max.x - box.min.x) * 0.15,
            box.min.y,
            (box.min.z + box.max.z) / 2);
          pivot = new THREE.Object3D();
          pivot.name = 'SeatPivot';
          const parent = seat.parent;
          pivot.position.copy(parent.worldToLocal(hingeWorld.clone()));
          parent.add(pivot);
          parent.remove(seat);
          pivot.add(seat);
          seat.position.sub(pivot.position);
        }

        function applySeat(progress) {
          const t = Math.min(Math.max(progress, 0), 1);
          const e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
          pivot.rotation.z = OPEN_ANGLE * e;
          needsRender = true;
        }
        function driveSeat(want) {
          const from = pivot.rotation.z / OPEN_ANGLE;
          if ((from > 0.05) === want && !seatAnim) return; // 状态一致不重复播
          seatAnim = { from: from, target: want ? 1 : 0, t: 0, report: 0 };
          post({ seatOpen: want, progress: want ? 1 : 0, phase: 'start' }); // 目标状态即时上报
        }
        window.jhSetSeat = (open) => {
          seatTarget = !!open;
          if (!pivot) return; // 模型未就绪：记下目标，setupSeat 后补挂
          driveSeat(seatTarget);
        };
        // 诊断：坐垫是否挂上、命中哪个节点、当前角度，便于真机定位"点了没反应"
        window.jhSeatDebug = () => ({
          pivot: !!pivot,
          node: seatNodeName,
          target: seatTarget,
          degrees: pivot ? +(pivot.rotation.z * 180 / Math.PI).toFixed(1) : null,
          modelReady: !!window.__jhModelReady
        });
        window.jhSeatState = () => {
          if (!pivot) return { ready: false };
          const p = Math.min(Math.max(pivot.rotation.z / OPEN_ANGLE, 0), 1);
          return { ready: true, open: p > 0.05, progress: p };
        };

        // ---------- 灯光：全车灯（不含转向灯）。灯面改自发光 + 近光投真实光域 ----------
        // AE4 / AE8 车模已解包核对，灯节点命名一致：L-LowBeam / L-HighBeam /
        //   L-TailLight / L-BrakeLight / L-TurnSignal-L / L-TurnSignal-R，AE8 另有 L-LightBar / K-Light。
        // 只认真实灯节点名，不用裸 brake/light 关键词猜——旧逻辑会把 FW/RW-BrakeFlange-T（刹车盘）
        //   当成刹车灯，深色主题点灯时刹车盘发红光。刹车盘(flange)与转向灯(turn)一律排除。
        function lampSpec(nodeName) {
          const n = String(nodeName || '').toLowerCase().replace(/[^a-z0-9]/g, '');
          if (!n) return null;
          // 灯节点以 L- / K- 开头；刹车盘 FW/RW-BrakeFlange、转向灯 L-TurnSignal 都不是灯
          if (n.charAt(0) !== 'l' && n.charAt(0) !== 'k') return null;
          if (n.indexOf('flange') >= 0 || n.indexOf('turn') >= 0) return null;
          if (n.indexOf('lightbar') >= 0) return [0xfff2d0, 10];
          if (n.indexOf('brakelight') >= 0) return [0xff1a00, 14];
          if (n.indexOf('taillight') >= 0 || n === 'klight') return [0xff1a00, 8];
          if (n.indexOf('highbeam') >= 0) return [0xffffff, 14];
          if (n.indexOf('lowbeam') >= 0) return [0xfff2d0, 10];
          return null;
        }
        // ---------- 大灯光域：近光"往两边散"光扇 + 远光细长平射 ----------
        // 车头朝 -x（AE4 世界坐标实测：大灯 x≈-0.5、尾灯 x≈+0.8）。
        // 灯口取 L-HighBeam/L-LowBeam 包围盒中心——节点原点≠灯面中心（灯节点位移挂在父级上）。
        // 近光（用户指定效果）：中间一束宽短锥 + 左右两束斜向锥，铺成往两边散的光扇；
        // 远光：单束细长锥平射。画布是透明背景（露出 SwiftUI 舞台渐变），
        // AdditiveBlending 会被 alpha 合成吃掉，必须用普通混合。
        const NEAR_DIR   = new THREE.Vector3(-1, -0.22, 0);    // 近光：中间下压
        const NEAR_DIR_L = new THREE.Vector3(-1, -0.30, 0.95); // 近光：向左散
        const NEAR_DIR_R = new THREE.Vector3(-1, -0.30, -0.95); // 近光：向右散
        const FAR_DIR    = new THREE.Vector3(-1, -0.08, 0);    // 远光：平射
        let beamGroup = null;
        let beamOrigin = null;
        const beams = { near: [], far: null };
        let beamSpot = null;
        function makeBeamCone() {
          const g = new THREE.ConeGeometry(1, 1, 32, 1, true);
          g.translate(0, -0.5, 0); // 锥顶移到原点
          const m = new THREE.MeshBasicMaterial({
            color: 0xfff2d0, transparent: true, opacity: 0.22,
            blending: THREE.NormalBlending, side: THREE.DoubleSide, depthWrite: false
          });
          return new THREE.Mesh(g, m);
        }
        function aimBeam(cone, from, dir, len, radius) {
          cone.scale.set(radius, len, radius);
          cone.position.copy(from);
          cone.quaternion.setFromUnitVectors(new THREE.Vector3(0, -1, 0), dir.clone().normalize());
        }
        function buildBeam(root) {
          const lampNode = root.getObjectByName('L-HighBeam') || root.getObjectByName('L-LowBeam');
          if (!lampNode) return;
          root.updateMatrixWorld(true);
          beamOrigin = new THREE.Box3().setFromObject(lampNode).getCenter(new THREE.Vector3());
          if (beamGroup) { // 复用页换模型：只更新灯口
            applyBeam();
            return;
          }
          beamGroup = new THREE.Group();
          beamGroup.name = 'HeadBeamFX';

          beams.near = [makeBeamCone(), makeBeamCone(), makeBeamCone()];
          beams.far = makeBeamCone();
          beams.near.forEach((c) => beamGroup.add(c));
          beamGroup.add(beams.far);

          beamSpot = new THREE.SpotLight(0xfff2d0, 0, 12, 0.4, 0.5, 1.4);
          beamSpot.visible = false;
          beamGroup.add(beamSpot, beamSpot.target);
          beamGroup.visible = false;
          scene.add(beamGroup);
        }
        function applyBeam() {
          needsRender = true;
          if (!beamGroup || !beamOrigin) return;
          const on = lightsState;
          beamGroup.visible = on;
          // 开灯不压暗环境光：日间观感一致，光锥靠普通混合保证可见
          if (!on) return;
          aimBeam(beams.near[0], beamOrigin, NEAR_DIR, 3.0, 0.70);  // 近光中间束：宽短
          aimBeam(beams.near[1], beamOrigin, NEAR_DIR_L, 2.4, 0.50); // 近光左散
          aimBeam(beams.near[2], beamOrigin, NEAR_DIR_R, 2.4, 0.50); // 近光右散
          beams.near.forEach((c) => { c.visible = true; });
          aimBeam(beams.far, beamOrigin, FAR_DIR, 6.5, 0.75);        // 远光：细长平射
          beams.far.visible = true;
          // 聚光灯取远光参数（app 全车灯含远光，对齐 demo onFar 分支）
          beamSpot.color.setHex(0xffffff);
          beamSpot.angle = 0.32;
          beamSpot.distance = 16;
          beamSpot.intensity = 300;
          beamSpot.visible = true;
          beamSpot.position.copy(beamOrigin);
          beamSpot.target.position.copy(beamOrigin.clone().add(FAR_DIR.clone().multiplyScalar(14)));
          beamSpot.target.updateMatrixWorld();
        }
        const lampMats = [];
        let lightsState = false; // 最近一次 jhSetLights 的目标状态，模型就绪后立即补挂
        function applyLights(on) {
          for (const m of lampMats) {
            if (on) {
              m.emissive.setHex(m.userData.onColor);
              m.emissiveIntensity = m.userData.onInt;
            } else {
              m.emissive.setHex(0x000000);
              m.emissiveIntensity = 0;
            }
          }
          applyBeam();
        }
        window.jhSetLights = (on) => {
          lightsState = !!on;
          applyLights(lightsState);
        };
        // 调试用：jhLampInfo() 看收集到了哪些灯材质、当前开关状态
        window.jhLampInfo = () => ({ mats: lampMats.map((m) => m.name || 'unnamed'), lights: lightsState });

        new GLTFLoader().load('model.glb', (gltf) => {
          scene.add(gltf.scene);
          setupSeat(gltf.scene);
          // 模型加载晚于页面下发：补挂最近的坐垫目标状态（灯光同理见下方 applyLights）
          if (pivot && ((pivot.rotation.z / OPEN_ANGLE) > 0.05) !== seatTarget) {
            driveSeat(seatTarget);
          }
          // 统一收集灯材质：只按真实灯节点名（lampSpec），不再用材质名/裸关键词兜底。
          // 材质可能是数组；unlit 材质没有 emissive，要换成标准材质，否则点灯无效。
          gltf.scene.traverse((o) => {
            if (!o.isMesh) return;
            const isArray = Array.isArray(o.material);
            const list = isArray ? o.material : [o.material];
            let replaced = false;
            const processed = [];
            for (const mat of list) {
              if (!mat) { processed.push(mat); continue; }
              const spec = lampSpec(o.name);
              if (!spec) { processed.push(mat); continue; }
              let m = mat;
              if (!m.emissive) {
                const std = new THREE.MeshStandardMaterial({
                  color: m.color ? m.color.getHex() : 0xffffff,
                  map: m.map || null,
                  transparent: !!m.transparent,
                  opacity: m.opacity != null ? m.opacity : 1,
                  side: m.side
                });
                std.name = m.name || '';
                m = std;
                replaced = true;
              }
              if (lampMats.indexOf(m) < 0) {
                m.toneMapped = false;
                m.userData.onColor = spec[0];
                m.userData.onInt = spec[1];
                m.emissive.setHex(0x000000);
                m.emissiveIntensity = 0;
                lampMats.push(m);
              }
              processed.push(m);
            }
            if (replaced) o.material = isArray ? processed : processed[0];
          });
          // 模型加载晚于页面就绪：补挂最近的灯光/坐垫目标状态
          if (lampMats.length > 0) applyLights(lightsState);
          // 对齐 model-viewer 的 camera-target auto 语义：把包围盒中心挪到
          // 相机 target（0.02, 0.74, 0），模型不再依赖原始坐标摆放
          const box = new THREE.Box3().setFromObject(gltf.scene);
          const center = box.getCenter(new THREE.Vector3());
          gltf.scene.position.x += 0.02 - center.x;
          gltf.scene.position.z += 0 - center.z;
          gltf.scene.position.y += 0.74 - center.y;
          buildBeam(gltf.scene);
          needsRender = true;
          window.__jhModelReady = true;
          readyPending = true; // 首帧渲染完成后再上报 ready，避免揭掉 loading 后还有空窗
        });

        // ---------- 主循环：按需渲染，静止时不耗 CPU（低配机友好） ----------
        // 页面切走时 jhSetPaused(true)：跳过渲染与动画推进，只留 rAF 空转
        const pausedBox = { value: false };
        let readyPending = false;
        window.jhSetPaused = (p) => {
          pausedBox.value = !!p;
          if (!pausedBox.value) needsRender = true;
        };
        const clock = new THREE.Clock();
        function loop() {
          requestAnimationFrame(loop);
          const dt = clock.getDelta();
          if (pausedBox.value) return;
          controls.update();
          if (seatAnim) {
            seatAnim.t += dt / 0.6;
            const done = seatAnim.t >= 1;
            const raw = done ? seatAnim.target
                             : seatAnim.from + (seatAnim.target - seatAnim.from) * seatAnim.t;
            applySeat(raw);
            const openNow = seatAnim.target === 1;
            seatAnim.report -= dt;
            if (done || seatAnim.report <= 0) {
              seatAnim.report = 0.1; // 动画期间每 100ms 上报一次进度
              post({ seatOpen: openNow, progress: Math.round(Math.min(Math.max(raw,0),1) * 1000) / 1000, phase: done ? 'done' : 'moving' });
            }
            if (done) seatAnim = null;
          }
          if (needsRender) {
            renderer.render(scene, camera);
            if (readyPending) { readyPending = false; post({ ready: true }); }
            needsRender = controls.autoRotate; // 自动旋转时持续重绘
          }
        }
        loop();

        // ---------- 相机复位（原生双击 / resetToken 触发） ----------
        let resetFrame = 0;
        window.jhResetOrbit = () => {
          if (resetFrame) cancelAnimationFrame(resetFrame);
          const startPos = camera.position.clone();
          const startTarget = controls.target.clone();
          const t0 = performance.now();
          const dur = 680;
          const tick = (now) => {
            const t = Math.min(1, (now - t0) / dur);
            const e = 1 - Math.pow(1 - t, 3);
            camera.position.lerpVectors(startPos, DEFAULT_POS, e);
            controls.target.lerpVectors(startTarget, DEFAULT_TARGET, e);
            needsRender = true;
            if (t < 1) { resetFrame = requestAnimationFrame(tick); return; }
            resetFrame = 0;
            camera.position.copy(DEFAULT_POS);
            controls.target.copy(DEFAULT_TARGET);
            post({ rotated: false });
          };
          resetFrame = requestAnimationFrame(tick);
        };
        </script>
        </body>
        </html>
        """
    }

    /// 轨迹回放地图上的立体车模：略俯视、带接地阴影，靠 orientation 跟着航向转。
    static func mapHTML() -> String {
        let orbit = "180deg 65deg 5.8m"
        let target = "0m 0.38m 0m"
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
            width: 100%; height: 100%;
            background: transparent;
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
          field-of-view="26deg"
          shadow-intensity="1.2"
          shadow-softness="0.75"
          exposure="1.05"
          environment-image="neutral"
          orientation="0deg 0deg 0deg"
          reveal="auto"
          interaction-prompt="none"
          disable-pan
          disable-tap
          interpolation-decay="50"
          minimum-render-scale="0.5">
        </model-viewer>
        <script>
          const viewer = document.getElementById('viewer');
          viewer.addEventListener('load', () => {
            if (viewer.pause) viewer.pause();
          });
          window.jhSetYaw = (deg) => {
            if (!viewer) return;
            let x = Number(deg);
            if (!isFinite(x)) return;
            while (x < 0) x += 360;
            while (x >= 360) x -= 360;
            viewer.orientation = '0deg 0deg ' + x + 'deg';
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

    func replace(token: String, glb: Data, script: Data, extra: [String: (data: Data, mime: String)] = [:]) {
        lock.lock()
        // 先清空：上一份 glb 有 6~8MB，不清理会随每次切车线性吃内存
        files.removeAll()
        let prefix = "/\(token)"
        files["\(prefix)/model.glb"] = (glb, "model/gltf-binary")
        files["\(prefix)/model-viewer.min.js"] = (script, "text/javascript")
        files["\(prefix)/index.html"] = (Data(), "text/html")
        for (path, entry) in extra { files["\(prefix)\(path)"] = entry }
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
            // no-store：彻底禁止 WebKit 缓存自定义 scheme 响应（token 路径是双保险）
            "Cache-Control": "no-store"
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

extension ModelViewerWebView {
    /// 后台预热 3D 弹层网页：提前创建 WKWebView 并加载车模（首帧渲染后即空闲），
    /// 打开弹层时直接从池里取现成页面——首次打开不再有 1~2 秒的解析等待。
    /// 注意必须 interactive:true：弹层复用此页面时不会重新 load，交互开关在 JS 里是模块级常量。
    static func prewarm(reuseKey key: String, glbFile: URL) {
        guard !key.isEmpty else { return }
        if let existing = ModelViewerPool.view(for: key),
           ModelViewerPool.file(for: key) == glbFile,
           !ModelViewerPool.isStale(key) {
            return // 已预热且文件没变
        }
        let configuration = WKWebViewConfiguration()
        let coordinator = Coordinator()
        configuration.userContentController.add(coordinator, name: "orbit")
        configuration.setURLSchemeHandler(coordinator.scheme, forURLScheme: ModelSchemeHandler.scheme)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        coordinator.load(into: view, glbFile: glbFile, interactive: true, autoRotate: false)
        ModelViewerPool.store(view, for: key, file: glbFile)
    }
}

enum GLBModelStore {
    /// 缓存名带 strip 版本号，节点清洗规则变更时自动换文件
    private static let stripTag = "s2"

    static func cached(vin: String, remote: URL?) -> URL? {
        if let file = HeroAssetCache.glb(for: vin) { return file }
        if let remote, let file = existing(for: remote) {
            HeroAssetCache.rememberGLB(file, vin: vin)
            return file
        }
        return nil
    }

    static func existing(for remote: URL) -> URL? {
        for target in destinations(for: remote) {
            if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int,
               size > 1024 {
                return target
            }
        }
        return nil
    }

    private static func destination(for remote: URL) -> URL {
        destinations(for: remote)[0]
    }

    private static func destinations(for remote: URL) -> [URL] {
        let dir = ResourceCache.directory.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stable = ResourceCache.hash(ResourceCache.stableIdentity(remote))
        let full = ResourceCache.hash(remote.absoluteString)
        var urls = [dir.appendingPathComponent("\(stable)-\(stripTag).glb")]
        if stable != full {
            urls.append(dir.appendingPathComponent("\(full)-\(stripTag).glb"))
        }
        return urls
    }

    static func localFile(for remote: URL, vin: String? = nil) async throws -> URL {
        if let vin, let cached = cached(vin: vin, remote: remote) {
            return cached
        }
        if let hit = existing(for: remote) {
            if let vin { HeroAssetCache.rememberGLB(hit, vin: vin) }
            return hit
        }

        guard let source = await ResourceCache.file(for: remote, folder: "models") else {
            throw URLError(.cannotOpenFile)
        }
        let target = destination(for: remote)
        let raw = try Data(contentsOf: source)
        let cleaned = GLBNodeStripper.strip(raw)
        try? FileManager.default.removeItem(at: target)
        try cleaned.write(to: target, options: .atomic)
        if let vin {
            HeroAssetCache.rememberGLB(target, vin: vin)
        }
        return target
    }
}

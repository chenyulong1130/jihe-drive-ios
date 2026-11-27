import MapKit
import SceneKit
import SwiftUI
import UIKit
import WebKit

/// 轨迹回放地图：按速度分段着色（低蓝 → 高红），无光环。
/// 标记在两个采样点之间插值，回放时是平滑移动而不是逐点跳。
struct ReplayMap: UIViewRepresentable {
    let points: [CLLocationCoordinate2D]
    var speeds: [Double] = []
    /// 相对行程起点的秒，与 points 等长；有值则按真实时间插值
    var times: [TimeInterval] = []
    var duration: TimeInterval = 0
    let progress: Double
    let follow: Bool
    /// 回放时切 3D 地形 + 追车相机
    var cinematic: Bool = false
    /// SceneKit 立体车模（USDZ / 能转的 GLB）
    var modelScene: SCNScene? = nil
    /// GLB 本地文件，SceneKit 吃不了时用 model-viewer 铺到地图上
    var glbFile: URL? = nil
    /// true 显示立体车模，false 显示车辆图片
    var use3D: Bool = false
    /// 全览边距。卡片/全屏都不跟车时用均匀边距，露出整段轨迹。
    var edgePadding: UIEdgeInsets = UIEdgeInsets(top: 52, left: 40, bottom: 52, right: 40)
    /// 多段合并回放时的分段断点（points 下标）：断点处不与上一段连线，
    /// 否则两段骑行的起终点之间会横穿城市画出一条假路线
    var breaks: [Int] = []

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        MapAppearance.apply(to: map)
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.backgroundColor = UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        map.register(ReplayCursorView.self, forAnnotationViewWithReuseIdentifier: ReplayCursorView.reuseID)
        context.coordinator.edgePadding = edgePadding
        context.coordinator.times = times
        context.coordinator.duration = duration
        context.coordinator.modelScene = modelScene
        context.coordinator.glbFile = glbFile
        context.coordinator.use3D = use3D
        context.coordinator.configure(map: map, points: points, speeds: speeds, breaks: breaks)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.edgePadding = edgePadding
        context.coordinator.times = times
        context.coordinator.duration = duration
        context.coordinator.modelScene = modelScene
        context.coordinator.glbFile = glbFile
        context.coordinator.use3D = use3D
        context.coordinator.update(map: map, progress: progress, follow: follow, cinematic: cinematic)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let palette: [UIColor] = [
            UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1),
            UIColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1),
            UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1),
            UIColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1),
            UIColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)
        ]

        private var allPoints: [CLLocationCoordinate2D] = []
        private var speeds: [Double] = []
        private var maxSpeed: Double = 40
        private var lineColors: [ObjectIdentifier: UIColor] = [:]
        private var lineWidths: [ObjectIdentifier: CGFloat] = [:]
        private var marker: ReplayCursorAnnotation?
        private var didFit = false
        private var didZoomFollow = false
        private var followEnabled = false
        private var lerpUntil: CFTimeInterval = 0
        private var displayLink: CADisplayLink?
        private let tickProxy = TickProxy()
        private weak var mapView: MKMapView?
        var edgePadding = UIEdgeInsets(top: 52, left: 40, bottom: 52, right: 40)
        var times: [TimeInterval] = []
        var duration: TimeInterval = 0
        var modelScene: SCNScene?
        var glbFile: URL?
        var use3D = false
        private var modelPoints: [Coordinate] = []
        private var progress: Double = 0
        private var progressVelocity: Double = 0
        private var lastProgressStamp: CFTimeInterval = 0
        private var cinematicEnabled = false
        private var displayHeading: CLLocationDirection = 0
        private var lastCourse: CLLocationDirection = 0
        /// 上一帧 onTick 时刻：平滑系数按真实帧间隔算，掉帧时不再放大滞后
        private var lastTickTime: CFTimeInterval = 0

        deinit {
            displayLink?.invalidate()
        }

        func configure(map: MKMapView, points: [CLLocationCoordinate2D], speeds: [Double], breaks: [Int] = []) {
            mapView = map
            tickProxy.owner = self
            allPoints = points
            modelPoints = points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            self.speeds = speeds.count == points.count ? speeds : Array(repeating: 0, count: points.count)
            guard points.count > 1 else { return }

            maxSpeed = max(self.speeds.max() ?? 0, 1)

            // 按断点拆链：每段骑行独立做速度着色分段，段与段之间不连线
            let chainStarts = ([0] + breaks.filter { $0 > 0 && $0 < points.count }).sorted()
            for (i, chainStart) in chainStarts.enumerated() {
                let chainEnd = (i + 1 < chainStarts.count) ? chainStarts[i + 1] : points.count
                var index = chainStart
                while index < chainEnd - 1 {
                    let tone = toneIndex(speed(at: index))
                    var end = index + 1
                    while end < chainEnd - 1, toneIndex(speed(at: end)) == tone {
                        end += 1
                    }
                    let slice = Array(points[index...end])
                    addLine(map, slice, color: Self.palette[tone], width: 5)
                    index = end
                }
            }

            let start = MKPointAnnotation()
            start.coordinate = points[0]
            start.title = "起"
            map.addAnnotation(start)

            if let last = points.last {
                let end = MKPointAnnotation()
                end.coordinate = last
                end.title = "终"
                map.addAnnotation(end)
            }

            let current = ReplayCursorAnnotation()
            current.coordinate = points[0]
            current.speed = speeds.first ?? 0
            marker = current
            map.addAnnotation(current)

            fit(map: map, points: points)
        }

        private func addLine(
            _ map: MKMapView,
            _ coordinates: [CLLocationCoordinate2D],
            color: UIColor,
            width: CGFloat
        ) {
            guard coordinates.count > 1 else { return }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            lineColors[ObjectIdentifier(line)] = color
            lineWidths[ObjectIdentifier(line)] = width
            map.addOverlay(line, level: .aboveRoads)
        }

        private func speed(at index: Int) -> Double {
            guard index >= 0, index < speeds.count else { return 0 }
            let next = min(index + 1, speeds.count - 1)
            return max(speeds[index], speeds[next])
        }

        private func toneIndex(_ value: Double) -> Int {
            let ratio = min(max(value / maxSpeed, 0), 1)
            if ratio < 0.22 { return 0 }
            if ratio < 0.42 { return 1 }
            if ratio < 0.62 { return 2 }
            if ratio < 0.82 { return 3 }
            return 4
        }

        private func fit(map: MKMapView, points: [CLLocationCoordinate2D]) {
            guard !didFit, points.count > 1 else { return }
            didFit = true
            var rect = MKMapRect.null
            for coordinate in points {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            map.setVisibleMapRect(
                rect,
                edgePadding: edgePadding,
                animated: false
            )
        }

        func update(map: MKMapView, progress: Double, follow: Bool, cinematic: Bool) {
            mapView = map
            map.isZoomEnabled = true
            map.isScrollEnabled = true
            applyStyle(map: map, cinematic: cinematic)
            refreshCursor(on: map)
            guard allPoints.count > 1 else { return }

            let now = CACurrentMediaTime()
            if lastProgressStamp > 0 {
                let dt = now - lastProgressStamp
                let delta = progress - self.progress
                // 只接受正常播放的小幅前进：循环重开/拖动的大跳不外推，避免光标猛甩一下
                if dt > 0.002, dt < 0.25, delta >= 0, delta < 0.05 {
                    progressVelocity = delta / dt
                }
            } else {
                progressVelocity = 0
            }
            self.progress = progress
            lastProgressStamp = now

            let pose = applyPose(progress: progress, on: map)

            if !follow {
                followEnabled = false
                progressVelocity = 0
                stopLink()
                if progress < 0.02, didZoomFollow {
                    didZoomFollow = false
                    didFit = false
                    fit(map: map, points: allPoints)
                }
                return
            }

            followEnabled = true
            startLink()
            if !didZoomFollow {
                didZoomFollow = true
                lerpUntil = now + (cinematic ? 0.55 : 0.16)
                let heading = cinematicEnabled ? displayHeading : 0
                let camera = MKMapCamera(
                    lookingAtCenter: pose,
                    // 距离拉远：太近瓦片每帧重绘卡顿，也太压迫；电影 950 / 平面 1800
                    fromDistance: cinematicEnabled ? 950 : 1800,
                    pitch: cinematicEnabled ? 58 : 0,
                    heading: heading
                )
                map.setCamera(camera, animated: true)
            }
        }

        private func applyStyle(map: MKMapView, cinematic: Bool) {
            if cinematic == cinematicEnabled { return }
            cinematicEnabled = cinematic
            didZoomFollow = false
            if cinematic {
                displayHeading = lastCourse
                MapAppearance.applyCinematic(to: map)
            } else {
                MapAppearance.apply(to: map)
                didFit = false
                fit(map: map, points: allPoints)
            }
            refreshCursor(on: map)
        }

        func refreshCursor(on map: MKMapView) {
            guard let marker, let view = map.view(for: marker) as? ReplayCursorView else { return }
            applyCursor(view, speed: marker.speed, heading: marker.heading, map: map)
        }

        private func applyCursor(
            _ view: ReplayCursorView,
            speed: Double,
            heading: CLLocationDirection,
            map: MKMapView
        ) {
            view.apply(
                speed: speed,
                modelScene: modelScene,
                glbFile: glbFile,
                use3D: use3D,
                heading: heading,
                mapHeading: map.camera.heading
            )
        }

        @discardableResult
        private func applyPose(progress: Double, on map: MKMapView) -> CLLocationCoordinate2D {
            let sample = ReplayClock.interpolate(
                points: modelPoints,
                speeds: speeds,
                times: times,
                duration: duration,
                progress: progress
            )
            let current = CLLocationCoordinate2D(
                latitude: sample.point.latitude,
                longitude: sample.point.longitude
            )
            let heading = course(at: progress, from: current)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            marker?.coordinate = current
            CATransaction.commit()
            marker?.speed = sample.speed
            marker?.heading = heading
            if let marker, let view = map.view(for: marker) as? ReplayCursorView {
                applyCursor(view, speed: sample.speed, heading: heading, map: map)
            }
            return current
        }

        private func course(at progress: Double, from current: CLLocationCoordinate2D) -> CLLocationDirection {
            let look = min(1, progress + 0.014)
            let ahead = ReplayClock.interpolate(
                points: modelPoints,
                speeds: speeds,
                times: times,
                duration: duration,
                progress: look
            ).point
            let dest = CLLocationCoordinate2D(latitude: ahead.latitude, longitude: ahead.longitude)
            let dLat = abs(dest.latitude - current.latitude)
            let dLng = abs(dest.longitude - current.longitude)
            if dLat < 0.00002, dLng < 0.00002 {
                return lastCourse
            }
            lastCourse = bearing(from: current, to: dest)
            return lastCourse
        }

        private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
            let lat1 = a.latitude * .pi / 180
            let lat2 = b.latitude * .pi / 180
            let dLon = (b.longitude - a.longitude) * .pi / 180
            let y = sin(dLon) * cos(lat2)
            let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
            let deg = atan2(y, x) * 180 / .pi
            return (deg + 360).truncatingRemainder(dividingBy: 360)
        }

        private func blendHeading(to next: CLLocationDirection, k: Double) -> CLLocationDirection {
            var delta = next - displayHeading
            while delta > 180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            displayHeading += delta * k
            if displayHeading < 0 { displayHeading += 360 }
            if displayHeading >= 360 { displayHeading -= 360 }
            return displayHeading
        }

        private func startLink() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: tickProxy, selector: #selector(TickProxy.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 55, maximum: 120, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        fileprivate func onTick(_ link: CADisplayLink) {
            guard followEnabled, let map = mapView else { return }
            if isUserGesture(on: map) { return }

            let now = CACurrentMediaTime()
            let dt = max(0, now - lastProgressStamp)
            let predicted = min(1, max(0, progress + progressVelocity * dt))
            let target = applyPose(progress: predicted, on: map)
            if now < lerpUntil { return }

            // 平滑系数按真实帧间隔算：CADisplayLink.duration 是屏幕刷新周期，
            // 掉帧时按它算会让相机/光标滞后放大——转弯时车模看起来歪就是这个
            let frame = lastTickTime > 0 ? min(0.1, now - lastTickTime) : (link.duration > 0 ? link.duration : 1.0 / 60.0)
            lastTickTime = now
            if cinematicEnabled {
                let heading = blendHeading(to: lastCourse, k: min(1, 1 - exp(-frame / 0.18)))
                let camera = MKMapCamera(
                    lookingAtCenter: target,
                    fromDistance: 950,
                    pitch: 58,
                    heading: heading
                )
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                map.camera = camera
                CATransaction.commit()
                return
            }

            let current = map.centerCoordinate
            let dLat = abs(current.latitude - target.latitude)
            let dLng = abs(current.longitude - target.longitude)
            let next: CLLocationCoordinate2D
            if dLat > 0.012 || dLng > 0.012 {
                next = target
            } else {
                let k = 1 - exp(-frame / 0.065)
                next = CLLocationCoordinate2D(
                    latitude: current.latitude + (target.latitude - current.latitude) * k,
                    longitude: current.longitude + (target.longitude - current.longitude) * k
                )
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            map.centerCoordinate = next
            CATransaction.commit()
        }

        /// 用户手势是否进行中：只查浅层子视图，不递归整棵视图树。
        /// GLB 车模路径下地图里挂着 WKWebView（层级极深），每帧全树递归很伤主线程
        private func isUserGesture(on map: MKMapView) -> Bool {
            func active(_ view: UIView, depth: Int) -> Bool {
                if view.gestureRecognizers?.contains(where: {
                    $0.state == .began || $0.state == .changed
                }) == true {
                    return true
                }
                guard depth > 0 else { return false }
                return view.subviews.contains(where: { active($0, depth: depth - 1) })
            }
            return active(map, depth: 5)
        }

        private final class TickProxy: NSObject {
            weak var owner: Coordinator?
            @objc func tick(_ link: CADisplayLink) {
                owner?.onTick(link)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = lineColors[ObjectIdentifier(line)] ?? UIColor.systemBlue
            renderer.lineWidth = lineWidths[ObjectIdentifier(line)] ?? 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cursor = annotation as? ReplayCursorAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: ReplayCursorView.reuseID,
                    for: cursor
                ) as? ReplayCursorView
                    ?? ReplayCursorView(annotation: cursor, reuseIdentifier: ReplayCursorView.reuseID)
                view.annotation = cursor
                applyCursor(view, speed: cursor.speed, heading: cursor.heading, map: mapView)
                return view
            }
            guard let point = annotation as? MKPointAnnotation else { return nil }
            let kind = point.title ?? ""
            let identifier = "replay-\(kind)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: point, reuseIdentifier: identifier)
            view.annotation = point
            view.canShowCallout = false
            view.image = markerImage(for: kind)
            view.centerOffset = CGPoint(x: 0, y: -14)
            view.zPriority = MKAnnotationViewZPriority(rawValue: 750)
            return view
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for (index, view) in views.enumerated() {
                guard !(view.annotation is ReplayCursorAnnotation) else { continue }
                let end = view.frame
                view.frame.origin.y -= 36
                view.alpha = 0
                UIView.animate(
                    withDuration: 0.45,
                    delay: 0.06 * Double(index),
                    usingSpringWithDamping: 0.72,
                    initialSpringVelocity: 0.4,
                    options: [.curveEaseOut]
                ) {
                    view.frame = end
                    view.alpha = 1
                }
            }
        }

        private func markerImage(for title: String) -> UIImage {
            switch title {
            case "起": return pinImage(fill: UIColor(red: 0.20, green: 0.78, blue: 0.45, alpha: 1), label: "起")
            case "终": return pinImage(fill: UIColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 1), label: "终")
            default: return fallbackVehicleDot()
            }
        }

        /// 起终点：水滴针 + 白字
        private func pinImage(fill: UIColor, label: String) -> UIImage {
            let size = CGSize(width: 36, height: 44)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let cg = ctx.cgContext
                let head = CGRect(x: 4, y: 2, width: 28, height: 28)

                cg.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: UIColor.black.withAlphaComponent(0.28).cgColor)

                let path = UIBezierPath()
                path.addArc(
                    withCenter: CGPoint(x: head.midX, y: head.midY),
                    radius: 13,
                    startAngle: .pi * 0.75,
                    endAngle: .pi * 0.25,
                    clockwise: true
                )
                path.addLine(to: CGPoint(x: head.midX, y: size.height - 3))
                path.close()
                fill.setFill()
                path.fill()

                cg.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.withAlphaComponent(0.92).setFill()
                cg.fillEllipse(in: head.insetBy(dx: 7, dy: 7))

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: fill
                ]
                let text = label as NSString
                let textSize = text.size(withAttributes: attrs)
                text.draw(
                    at: CGPoint(x: head.midX - textSize.width / 2, y: head.midY - textSize.height / 2 - 0.5),
                    withAttributes: attrs
                )
            }
        }

        /// 当前车：外圈光晕 + 白环 + 品牌蓝实心
        private func fallbackVehicleDot() -> UIImage {
            let size = CGSize(width: 44, height: 44)
            let brand = UIColor(red: 0.12, green: 0.48, blue: 1.0, alpha: 1)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let cg = ctx.cgContext
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                cg.setShadow(offset: .zero, blur: 10, color: brand.withAlphaComponent(0.55).cgColor)
                brand.withAlphaComponent(0.25).setFill()
                cg.fillEllipse(in: CGRect(x: 2, y: 2, width: 40, height: 40))
                cg.setShadow(offset: .zero, blur: 0, color: nil)

                UIColor.white.setFill()
                cg.fillEllipse(in: CGRect(x: 10, y: 10, width: 24, height: 24))

                brand.setFill()
                cg.fillEllipse(in: CGRect(x: 14, y: 14, width: 16, height: 16))

                // 中心小白点
                UIColor.white.setFill()
                cg.fillEllipse(in: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
            }
        }
    }
}

// MARK: - 回放光标：速度气泡，0 显示「静止」

final class ReplayCursorAnnotation: MKPointAnnotation {
    var speed: Double = 0
    var heading: CLLocationDirection = 0
}

final class ReplayCursorView: MKAnnotationView {
    static let reuseID = "replay-cursor"
    private static let dotSize: CGFloat = 14
    private static let model3DSize = CGSize(width: 132, height: 96)
    /// GLB 默认车头朝右；再加 180° 后车头对准行驶方向（上次 -90° 会前后反）
    private static let modelYawBias: CLLocationDirection = 90

    private let bubble = UILabel()
    private let dot = UIView()
    private let sceneView = SCNView()
    private var web: ReplayMapGLBView?
    private var yawNode: SCNNode?
    private var attachedScene: SCNScene?
    private var shownHeading: CLLocationDirection?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        clipsToBounds = false
        zPriority = .max
        displayPriority = .required
        collisionMode = .none
        frame = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        centerOffset = .zero

        bubble.font = .systemFont(ofSize: 11, weight: .bold)
        bubble.textColor = .white
        bubble.textAlignment = .center
        bubble.layer.cornerRadius = 8
        bubble.layer.masksToBounds = true

        dot.backgroundColor = UIColor(red: 0.12, green: 0.48, blue: 1.0, alpha: 1)
        dot.layer.cornerRadius = Self.dotSize / 2
        dot.layer.borderWidth = 2.5
        dot.layer.borderColor = UIColor.white.cgColor
        dot.frame = bounds

        sceneView.backgroundColor = .clear
        sceneView.isOpaque = false
        sceneView.layer.isOpaque = false
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling2X
        sceneView.allowsCameraControl = false
        sceneView.isUserInteractionEnabled = false
        sceneView.rendersContinuously = true
        sceneView.preferredFramesPerSecond = 30
        sceneView.isHidden = true

        addSubview(dot)
        addSubview(sceneView)
        addSubview(bubble)
        apply(speed: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        speed: Double,
        modelScene: SCNScene? = nil,
        glbFile: URL? = nil,
        use3D: Bool = false,
        heading: CLLocationDirection = 0,
        mapHeading: CLLocationDirection = 0
    ) {
        let idle = speed < 0.5
        bubble.text = idle ? "静止" : String(format: "%.0f km/h", speed)
        bubble.backgroundColor = idle
            ? UIColor(red: 0.39, green: 0.45, blue: 0.53, alpha: 0.94)
            : UIColor(red: 0.12, green: 0.48, blue: 1.0, alpha: 0.94)
        let textSize = bubble.sizeThatFits(CGSize(width: 120, height: 20))
        let width = max(44, textSize.width + 14)

        let live3D = use3D && (modelScene != nil || glbFile != nil)
        dot.isHidden = live3D
        sceneView.rendersContinuously = live3D && modelScene != nil

        if live3D {
            bounds = CGRect(origin: .zero, size: Self.model3DSize)
            if let modelScene {
                attachScene(modelScene)
                sceneView.isHidden = false
                sceneView.frame = bounds
                web?.isHidden = true
                sceneView.isPlaying = true
                pointScene(heading: heading, mapHeading: mapHeading)
            } else if let glbFile {
                sceneView.isHidden = true
                sceneView.isPlaying = false
                attachGLB(glbFile)
                web?.isHidden = false
                web?.frame = bounds
                pointGLB(heading: heading, mapHeading: mapHeading)
            }
            bubble.frame = CGRect(
                x: (Self.model3DSize.width - width) / 2,
                y: -26,
                width: width,
                height: 20
            )
            centerOffset = CGPoint(x: 0, y: -22)
        } else {
            // 2D 回放统一用圆点：官方车图每帧旋转重绘，低端机上太卡
            shownHeading = nil
            sceneView.isHidden = true
            sceneView.isPlaying = false
            web?.isHidden = true
            bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
            dot.frame = bounds
            bubble.frame = CGRect(
                x: (Self.dotSize - width) / 2,
                y: -24,
                width: width,
                height: 20
            )
            centerOffset = .zero
        }
    }

    private func attachScene(_ scene: SCNScene) {
        guard attachedScene !== scene else { return }
        attachedScene = scene
        sceneView.scene = scene
        yawNode = scene.rootNode.childNode(withName: "replay-yaw", recursively: false)
        sceneView.pointOfView = scene.rootNode.childNode(withName: "replay-cam", recursively: false)
    }

    private func attachGLB(_ file: URL) {
        if web == nil {
            let view = ReplayMapGLBView.make()
            view.isHidden = true
            insertSubview(view, belowSubview: bubble)
            web = view
        }
        web?.loadGLB(file)
    }

    private func screenHeading(heading: CLLocationDirection, mapHeading: CLLocationDirection) -> CLLocationDirection {
        var screen = heading - mapHeading
        while screen < 0 { screen += 360 }
        while screen >= 360 { screen -= 360 }

        let from = shownHeading ?? screen
        var delta = screen - from
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        let next = from + delta * (shownHeading == nil ? 1 : 0.45)
        var wrapped = next
        while wrapped < 0 { wrapped += 360 }
        while wrapped >= 360 { wrapped -= 360 }
        shownHeading = wrapped
        return wrapped
    }

    /// 车头对准轨迹方向；气泡不转。地图旋转时扣掉相机朝向。
    private func pointScene(heading: CLLocationDirection, mapHeading: CLLocationDirection) {
        let wrapped = screenHeading(heading: heading, mapHeading: mapHeading) + Self.modelYawBias
        yawNode?.eulerAngles.y = -Float(wrapped * .pi / 180)
    }

    private func pointGLB(heading: CLLocationDirection, mapHeading: CLLocationDirection) {
        let wrapped = screenHeading(heading: heading, mapHeading: mapHeading) + Self.modelYawBias
        web?.setYaw(wrapped)
    }
}

/// 地图标注里的 GLB 立体车：独立 scheme，不和车辆页 model-viewer 抢缓存。
final class ReplayMapGLBView: WKWebView {
    private static let mapScheme = "jhmap3d"

    private let schemeHandler: ModelSchemeHandler
    private var loadedFile: URL?
    private var lastYaw = Double.nan
    private var lastYawSent = TimeInterval(0)

    static func make() -> ReplayMapGLBView {
        let handler = ModelSchemeHandler.shared
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: mapScheme)
        return ReplayMapGLBView(handler: handler, configuration: config)
    }

    private init(handler: ModelSchemeHandler, configuration: WKWebViewConfiguration) {
        self.schemeHandler = handler
        super.init(frame: .zero, configuration: configuration)
        isOpaque = false
        backgroundColor = .clear
        underPageBackgroundColor = .clear
        isUserInteractionEnabled = false
        scrollView.isScrollEnabled = false
        scrollView.backgroundColor = .clear
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadGLB(_ file: URL) {
        guard loadedFile != file else { return }
        guard let data = try? Data(contentsOf: file), data.count > 1024 else { return }
        guard let script = ModelViewerAsset.shared.scriptData else { return }
        loadedFile = file
        lastYaw = .nan
        // token 化路径：与车辆页同理，避免 WKWebView 共享缓存串台（换车后地图车模不变）
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        schemeHandler.replace(token: token, glb: data, script: script)
        let html = ModelViewerAsset.mapHTML()
        let base = URL(string: "\(Self.mapScheme)://local/\(token)/index.html")!
        loadHTMLString(html, baseURL: base)
    }

    func setYaw(_ degrees: Double) {
        // WKWebView 桥是最贵的进程间调用：转向 >2° 才发，且限 20Hz
        let now = CACurrentMediaTime()
        guard abs(degrees - lastYaw) > 2 || lastYaw.isNaN, now - lastYawSent > 0.05 else { return }
        lastYaw = degrees
        lastYawSent = now
        evaluateJavaScript("window.jhSetYaw && window.jhSetYaw(\(degrees))", completionHandler: nil)
    }

    /// 挂后台 WebContent 进程被回收时，地图上的立体车会消失；回来立即重载
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let file = loadedFile else { return }
        loadedFile = nil
        loadGLB(file)
    }
}

import MapKit
import SwiftUI
import UIKit

/// 轨迹回放地图：按速度分段着色（低蓝 → 高红）+ 发光底衬，
/// 标记在两个采样点之间插值，回放时是平滑移动而不是逐点跳。
struct ReplayMap: UIViewRepresentable {
    let points: [CLLocationCoordinate2D]
    var speeds: [Double] = []
    let progress: Double
    let follow: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        context.coordinator.configure(map: map, points: points, speeds: speeds)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(map: map, progress: progress, follow: follow)
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
        private var marker: MKPointAnnotation?
        private var didFit = false
        private var didZoomFollow = false
        private var lastCenterAt: CFTimeInterval = 0

        func configure(map: MKMapView, points: [CLLocationCoordinate2D], speeds: [Double]) {
            allPoints = points
            self.speeds = speeds.count == points.count ? speeds : Array(repeating: 0, count: points.count)
            guard points.count > 1 else { return }

            maxSpeed = max(self.speeds.max() ?? 0, 1)

            var index = 0
            while index < points.count - 1 {
                let tone = toneIndex(speed(at: index))
                var end = index + 1
                while end < points.count - 1, toneIndex(speed(at: end)) == tone {
                    end += 1
                }
                let slice = Array(points[index...end])
                let color = Self.palette[tone]
                addLine(map, slice, color: color.withAlphaComponent(0.22), width: 14)
                addLine(map, slice, color: color, width: 5)
                index = end
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

            let current = MKPointAnnotation()
            current.coordinate = points[0]
            current.title = "车"
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
            // 底部留给速度面板，顶部留给工具条；整体再近一点
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 88, left: 36, bottom: 260, right: 36),
                animated: false
            )
        }

        func update(map: MKMapView, progress: Double, follow: Bool) {
            guard allPoints.count > 1 else { return }
            let clamped = min(max(progress, 0), 1)
            let raw = clamped * Double(allPoints.count - 1)
            let index = min(allPoints.count - 2, max(0, Int(raw)))
            let fraction = raw - Double(index)

            let a = allPoints[index]
            let b = allPoints[index + 1]
            let current = CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: a.longitude + (b.longitude - a.longitude) * fraction
            )
            marker?.coordinate = current

            guard follow else {
                didZoomFollow = false
                return
            }

            let now = CACurrentMediaTime()
            // 更近的跟随视角（约 250–300m 视口）
            let span = MKCoordinateSpan(latitudeDelta: 0.0028, longitudeDelta: 0.0028)
            if !didZoomFollow {
                didZoomFollow = true
                lastCenterAt = now
                map.setRegion(MKCoordinateRegion(center: current, span: span), animated: true)
            } else if now - lastCenterAt > 0.2 {
                lastCenterAt = now
                map.setCenter(current, animated: false)
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
            guard let point = annotation as? MKPointAnnotation else { return nil }
            let kind = point.title ?? ""
            let identifier = "replay-\(kind)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: point, reuseIdentifier: identifier)
            view.annotation = point
            view.canShowCallout = false
            view.image = markerImage(for: kind)
            view.centerOffset = CGPoint(x: 0, y: kind == "车" ? 0 : -14)
            // MKAnnotationView.ZPriority 只有 min / max，中间用数值
            view.zPriority = kind == "车" ? .max : MKAnnotationView.ZPriority(rawValue: 750)
            return view
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for (index, view) in views.enumerated() {
                guard (view.annotation as? MKPointAnnotation)?.title != "车" else { continue }
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
            default: return vehicleImage()
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
        private func vehicleImage() -> UIImage {
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

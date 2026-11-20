import MapKit
import SwiftUI
import UIKit

/// 轨迹回放地图：按速度分段着色（低蓝 → 高红）+ 发光底衬，
/// 标记在两个采样点之间插值，回放时是平滑移动而不是逐点跳。
/// 分段只跟速度档位变化次数有关，通常十几条 overlay，比每帧重建整条线轻得多。
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

            // 按速度档位切段，同档合并
            var index = 0
            while index < points.count - 1 {
                let tone = toneIndex(speed(at: index))
                var end = index + 1
                while end < points.count - 1, toneIndex(speed(at: end)) == tone {
                    end += 1
                }
                let slice = Array(points[index...end])
                let color = Self.palette[tone]
                addLine(map, slice, color: color.withAlphaComponent(0.22), width: 13)
                addLine(map, slice, color: color, width: 4.5)
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
            map.setVisibleMapRect(
                rect,
                edgePadding: UIEdgeInsets(top: 100, left: 48, bottom: 150, right: 48),
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
            if !didZoomFollow {
                didZoomFollow = true
                lastCenterAt = now
                map.setRegion(
                    MKCoordinateRegion(
                        center: current,
                        span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                    ),
                    animated: true
                )
            } else if now - lastCenterAt > 0.25 {
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
            renderer.lineWidth = lineWidths[ObjectIdentifier(line)] ?? 4.5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }
            let identifier = "replay-\(point.title ?? "")"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: point, reuseIdentifier: identifier)
            view.annotation = point
            view.image = image(for: point.title ?? "")
            view.centerOffset = CGPoint(x: 0, y: -9)
            view.zPriority = .max
            return view
        }

        private func image(for title: String) -> UIImage {
            let size = CGSize(width: 26, height: 26)
            return UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
                let color: UIColor
                switch title {
                case "起": color = .systemGreen
                case "终": color = .systemOrange
                default: color = UIColor(red: 0.10, green: 0.45, blue: 0.98, alpha: 1)
                }

                context.cgContext.setShadow(
                    offset: .zero,
                    blur: 7,
                    color: color.withAlphaComponent(0.65).cgColor
                )
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: rect)
                context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

                context.cgContext.setFillColor(color.cgColor)
                context.cgContext.fillEllipse(in: rect.insetBy(dx: 4, dy: 4))
            }
        }
    }
}

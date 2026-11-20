import MapKit
import SwiftUI
import UIKit

/// 轨迹回放地图：底层淡色全程 + 上层高亮已行驶段 + 移动标记
struct ReplayMap: UIViewRepresentable {
    let points: [CLLocationCoordinate2D]
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
        context.coordinator.configure(map: map, points: points)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(map: map, progress: progress, follow: follow)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var allPoints: [CLLocationCoordinate2D] = []
        private var traveled: MKPolyline?
        private var remaining: MKPolyline?
        private var marker: MKPointAnnotation?
        private var lastIndex = -1
        private var didFit = false

        func configure(map: MKMapView, points: [CLLocationCoordinate2D]) {
            allPoints = points
            guard points.count > 1 else { return }

            let remainingLine = MKPolyline(coordinates: points, count: points.count)
            remaining = remainingLine
            map.addOverlay(remainingLine, level: .aboveRoads)

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

        private func fit(map: MKMapView, points: [CLLocationCoordinate2D]) {
            guard !didFit, points.count > 1 else { return }
            didFit = true
            var rect = MKMapRect.null
            for coordinate in points {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            let padding = UIEdgeInsets(top: 120, left: 48, bottom: 260, right: 48)
            map.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        }

        func update(map: MKMapView, progress: Double, follow: Bool) {
            guard allPoints.count > 1 else { return }
            let clamped = min(max(progress, 0), 1)
            let index = min(allPoints.count - 1, max(0, Int((Double(allPoints.count - 1) * clamped).rounded())))
            guard index != lastIndex else { return }
            lastIndex = index

            if let old = traveled { map.removeOverlay(old) }
            if index >= 1 {
                let slice = Array(allPoints[0...index])
                let line = MKPolyline(coordinates: slice, count: slice.count)
                traveled = line
                map.addOverlay(line, level: .aboveRoads)
            } else {
                traveled = nil
            }

            marker?.coordinate = allPoints[index]

            if follow {
                let region = MKCoordinateRegion(
                    center: allPoints[index],
                    span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
                )
                map.setRegion(region, animated: false)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: line)
            if line === traveled {
                renderer.strokeColor = UIColor(red: 0.10, green: 0.45, blue: 0.98, alpha: 1)
                renderer.lineWidth = 6
                renderer.lineCap = .round
                renderer.lineJoin = .round
            } else {
                renderer.strokeColor = UIColor(white: 0.35, alpha: 0.55)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? MKPointAnnotation else { return nil }
            let identifier = "replay-\(point.title ?? "")"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: point, reuseIdentifier: identifier)
            view.annotation = point
            view.image = image(for: point.title ?? "")
            view.centerOffset = CGPoint(x: 0, y: -10)
            return view
        }

        private func image(for title: String) -> UIImage {
            let size = CGSize(width: 26, height: 26)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
                let color: UIColor
                switch title {
                case "起": color = UIColor.systemGreen
                case "终": color = UIColor.systemOrange
                default: color = UIColor(red: 0.10, green: 0.45, blue: 0.98, alpha: 1)
                }

                context.cgContext.setShadow(offset: .zero, blur: 6, color: color.withAlphaComponent(0.6).cgColor)
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: rect)
                context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

                let dot = rect.insetBy(dx: 4, dy: 4)
                context.cgContext.setFillColor(color.cgColor)
                context.cgContext.fillEllipse(in: dot)
            }
        }
    }
}

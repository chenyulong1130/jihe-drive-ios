import MapKit
import SwiftUI
import UIKit

/// MapKit 容器。
///
/// 只在数据真正变化时刷新标注与轨迹，避免每次 SwiftUI 重绘都把用户拖动过的地图弹回原位。
/// `interactive = false` 用于车辆页的内嵌预览卡。
struct VehicleMapView: UIViewRepresentable {
    let coordinate: Coordinate?
    var track: [Coordinate] = []
    var interactive: Bool = true
    /// 显示手机当前位置（全屏地图用）
    var showsUser: Bool = false
    /// 递增即重新聚焦到车辆 / 轨迹
    var recenterToken: Int = 0
    /// 车辆官方图 / 3D 截图，当作定位点
    var vehicleImage: UIImage? = nil
    var vehicleImageURL: URL? = nil
    /// 全屏位置页里，「我的位置」也用车辆 3D / 车图，不要系统蓝点
    var userUsesVehicleModel: Bool = false

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        MapAppearance.apply(to: map)
        map.showsUserLocation = showsUser
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.register(
            VehiclePinView.self,
            forAnnotationViewWithReuseIdentifier: VehiclePinView.reuseID
        )
        map.register(
            VehiclePinView.self,
            forAnnotationViewWithReuseIdentifier: VehiclePinView.userReuseID
        )
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        map.isScrollEnabled = interactive
        map.isZoomEnabled = interactive

        let sourceChanged = coordinator.lastSource != coordinate
        if sourceChanged {
            coordinator.lastSource = coordinate
            coordinator.reloadVehicle(on: map, coordinate: coordinate)
        }

        if coordinator.lastTrack != track {
            coordinator.lastTrack = track
            coordinator.reloadTrack(on: map, track: track)
        }

        coordinator.userUsesVehicleModel = userUsesVehicleModel
        if vehicleImage != nil, coordinator.markerImage !== vehicleImage {
            coordinator.markerImage = vehicleImage
            coordinator.applyMarker(on: map)
        }
        if coordinator.markerURL != vehicleImageURL {
            coordinator.markerURL = vehicleImageURL
            coordinator.loadMarker(on: map, url: vehicleImageURL, fallback: vehicleImage)
        }

        if !coordinator.didFocus || coordinator.lastRecenter != recenterToken || sourceChanged {
            coordinator.lastRecenter = recenterToken
            coordinator.focus(
                on: map,
                coordinate: coordinate,
                track: track,
                animated: coordinator.didFocus
            )
            coordinator.didFocus = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastSource: Coordinate?
        var lastTrack: [Coordinate] = []
        var lastRecenter = -1
        var didFocus = false
        var markerImage: UIImage?
        var markerURL: URL?
        var userUsesVehicleModel = false
        private var markerTask: Task<Void, Never>?

        func reloadVehicle(on map: MKMapView, coordinate: Coordinate?) {
            let existing = map.annotations.compactMap { $0 as? VehicleAnnotation }
            if !existing.isEmpty {
                map.removeAnnotations(existing as [MKAnnotation])
            }
            guard let coordinate else { return }
            map.addAnnotation(VehicleAnnotation(coordinate: coordinate.mapCoordinate))
        }

        func reloadTrack(on map: MKMapView, track: [Coordinate]) {
            if !map.overlays.isEmpty {
                map.removeOverlays(map.overlays)
            }
            guard track.count > 1 else { return }

            var coordinates = track.map { $0.mapCoordinate }
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            line.title = "line"
            map.addOverlay(line)
        }

        func focus(
            on map: MKMapView,
            coordinate: Coordinate?,
            track: [Coordinate],
            animated: Bool
        ) {
            if track.count > 1,
               let line = map.overlays.first(where: { $0.title == "line" }) {
                map.setVisibleMapRect(
                    line.boundingMapRect,
                    edgePadding: UIEdgeInsets(top: 96, left: 44, bottom: 150, right: 44),
                    animated: animated
                )
                return
            }

            guard let coordinate else { return }
            let region = MKCoordinateRegion(
                center: coordinate.mapCoordinate,
                latitudinalMeters: 720,
                longitudinalMeters: 720
            )
            map.setRegion(region, animated: animated)
        }

        func applyMarker(on map: MKMapView) {
            map.annotations.compactMap { map.view(for: $0) as? VehiclePinView }.forEach {
                $0.apply(vehicleImage: markerImage)
            }
            if userUsesVehicleModel, markerImage != nil,
               map.showsUserLocation,
               !(map.view(for: map.userLocation) is VehiclePinView) {
                map.showsUserLocation = false
                map.showsUserLocation = true
            }
        }

        func loadMarker(on map: MKMapView, url: URL?, fallback: UIImage?) {
            markerTask?.cancel()
            if let fallback {
                markerImage = fallback
                applyMarker(on: map)
            }
            guard let url else { return }
            markerTask = Task { [weak self] in
                let image = await ResourceCache.image(for: url)
                await MainActor.run {
                    guard let self, !Task.isCancelled else { return }
                    self.markerImage = image ?? fallback
                    self.applyMarker(on: map)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                guard userUsesVehicleModel, markerImage != nil else { return nil }
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: VehiclePinView.userReuseID,
                    for: annotation
                )
                view.annotation = annotation
                if let pin = view as? VehiclePinView {
                    pin.apply(vehicleImage: markerImage)
                }
                return view
            }
            guard annotation is VehicleAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: VehiclePinView.reuseID,
                for: annotation
            )
            view.annotation = annotation
            if let pin = view as? VehiclePinView {
                pin.apply(vehicleImage: markerImage)
            }
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round

            renderer.strokeColor = UIColor(red: 0.043, green: 0.42, blue: 0.796, alpha: 1)
            renderer.lineWidth = 5
            return renderer
        }
    }
}

// MARK: - 标注

final class VehicleAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(coordinate: CLLocationCoordinate2D, title: String? = nil) {
        self.coordinate = coordinate
        self.title = title
        super.init()
    }
}

final class VehiclePinView: MKAnnotationView {
    static let reuseID = "jihe-vehicle-pin"
    static let userReuseID = "jihe-user-vehicle-pin"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        image = Self.fallbackPin
        centerOffset = CGPoint(x: 0, y: -18)
        canShowCallout = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(vehicleImage: UIImage?) {
        if let vehicleImage {
            image = Self.makeVehicleMarker(vehicleImage)
            centerOffset = CGPoint(x: 0, y: -10)
        } else {
            image = Self.fallbackPin
            centerOffset = CGPoint(x: 0, y: -25)
        }
    }

    private static let fallbackPin = makePinImage()

    private static func makeVehicleMarker(_ photo: UIImage) -> UIImage {
        let size = CGSize(width: 92, height: 62)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let shadow = CGRect(x: 18, y: 50, width: 56, height: 8)
            cg.setShadow(offset: .zero, blur: 6, color: UIColor.black.withAlphaComponent(0.28).cgColor)
            UIColor.black.withAlphaComponent(0.18).setFill()
            cg.fillEllipse(in: shadow)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            let rect = CGRect(x: 4, y: 2, width: 84, height: 50)
            photo.draw(in: rect)
        }
    }

    private static func makePinImage() -> UIImage {
        let size = CGSize(width: 44, height: 54)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let cg = context.cgContext

            let tip = UIBezierPath()
            tip.move(to: CGPoint(x: 22, y: 52))
            tip.addLine(to: CGPoint(x: 10.5, y: 33))
            tip.addLine(to: CGPoint(x: 33.5, y: 33))
            tip.close()
            UIColor(red: 0.043, green: 0.42, blue: 0.796, alpha: 1).setFill()
            tip.fill()

            let circleRect = CGRect(x: 3, y: 2, width: 38, height: 38)
            let circle = UIBezierPath(ovalIn: circleRect)

            cg.saveGState()
            circle.addClip()
            let colors = [
                UIColor(red: 0.106, green: 0.541, blue: 1, alpha: 1).cgColor,
                UIColor(red: 0.043, green: 0.42, blue: 0.796, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 3, y: 2),
                    end: CGPoint(x: 41, y: 40),
                    options: []
                )
            }
            cg.restoreGState()

            UIColor.white.setStroke()
            circle.lineWidth = 2.4
            circle.stroke()

            let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            if let symbol = UIImage(systemName: "bolt.car.fill", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                symbol.draw(
                    in: CGRect(
                        x: 22 - symbol.size.width / 2,
                        y: 21 - symbol.size.height / 2,
                        width: symbol.size.width,
                        height: symbol.size.height
                    )
                )
            }
        }
    }
}

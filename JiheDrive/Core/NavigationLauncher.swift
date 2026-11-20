import CoreLocation
import MapKit
import UIKit

/// 导航跳转：优先唤起手机里已装的地图 App，最后退到苹果地图。
/// 车辆坐标是 GCJ-02，高德/腾讯直接可用，百度需要转 BD-09。
enum NavigationLauncher {

    struct Option: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let icon: String
        let action: () -> Void
    }

    static func options(lat: Double, lon: Double, name: String) -> [Option] {
        var result: [Option] = []

        if let url = URL(string: amapURL(lat: lat, lon: lon, name: name)),
           UIApplication.shared.canOpenURL(url) {
            result.append(
                Option(title: "高德地图", detail: "驾车导航", icon: "map.fill") {
                    open(url)
                }
            )
        }

        if let url = URL(string: baiduURL(lat: lat, lon: lon, name: name)),
           UIApplication.shared.canOpenURL(url) {
            result.append(
                Option(title: "百度地图", detail: "驾车导航", icon: "map.fill") {
                    open(url)
                }
            )
        }

        if let url = URL(string: tencentURL(lat: lat, lon: lon, name: name)),
           UIApplication.shared.canOpenURL(url) {
            result.append(
                Option(title: "腾讯地图", detail: "驾车导航", icon: "map.fill") {
                    open(url)
                }
            )
        }

        result.append(
            Option(title: "苹果地图", detail: "系统内置", icon: "applelogo") {
                openAppleMaps(lat: lat, lon: lon, name: name)
            }
        )
        return result
    }

    /// 直接按优先级唤起（详情页一键导航用）
    static func openBest(lat: Double, lon: Double, name: String) {
        if let first = options(lat: lat, lon: lon, name: name).first {
            first.action()
        }
    }

    // MARK: - 各 App 链接

    private static func amapURL(lat: Double, lon: Double, name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        // dev=0：lat/lon 为 GCJ-02
        return "iosamap://navi?sourceApplication=JiheDrive&poiname=\(encoded)&lat=\(lat)&lon=\(lon)&dev=0&style=2"
    }

    private static func baiduURL(lat: Double, lon: Double, name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let (bdLat, bdLon) = gcjToBD(lat: lat, lon: lon)
        return "baidumap://map/direction?destination=latlng:\(bdLat),\(bdLon)|name:\(encoded)&coord_type=bd09ll&mode=driving&src=ios.jihedrive"
    }

    private static func tencentURL(lat: Double, lon: Double, name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return "qqmap://map/routeplan?type=drive&to=\(encoded)&tocoord=\(lat),\(lon)&referer=jihedrive&policy=1"
    }

    private static func openAppleMaps(lat: Double, lon: Double, name: String) {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
        let item = MKMapItem(placemark: placemark)
        item.name = name
        item.openInMaps(
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
    }

    private static func open(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    /// GCJ-02 → BD-09
    static func gcjToBD(lat: Double, lon: Double) -> (Double, Double) {
        let xPi = Double.pi * 3000.0 / 180.0
        let x = lon
        let y = lat
        let z = (x * x + y * y).squareRoot() + 0.00002 * sin(y * xPi)
        let theta = atan2(y, x) + 0.000003 * cos(x * xPi)
        return (z * sin(theta) + 0.006, z * cos(theta) + 0.0085)
    }
}

/// 首次进入地图时申请定位权限（只用于显示“我的位置”）
final class LocationPermissionRequester: NSObject, CLLocationManagerDelegate {
    static let shared = LocationPermissionRequester()

    private let manager = CLLocationManager()

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            manager.stopUpdatingLocation()
        default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
            manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.stopUpdatingLocation()
        }
    }
}

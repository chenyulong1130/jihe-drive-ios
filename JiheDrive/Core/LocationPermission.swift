import CoreLocation
import Foundation

/// 启动时申请定位（地图上显示自己、核对车速），不强制后台定位。
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
        default:
            break
        }
    }
}

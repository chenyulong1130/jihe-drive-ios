import CoreLocation
import Foundation

/// 接口坐标的坐标系。
///
/// MapKit 在中国大陆渲染的是 GCJ-02 底图，接口若同为 GCJ-02 可直接投图；
/// 若是 WGS-84（原始 GPS），直接投图会整体偏 300–500 米。
/// 真机上如果发现车辆位置有稳定偏移，把 `api` 改成 `.wgs84`。
enum MapDatum {
    case gcj02
    case wgs84

    static let api: MapDatum = .gcj02
}

enum MapCoordinate {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    static func convert(_ coordinate: Coordinate, from datum: MapDatum) -> CLLocationCoordinate2D {
        switch datum {
        case .gcj02:
            return CLLocationCoordinate2D(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        case .wgs84:
            let converted = wgs84ToGCJ02(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            return CLLocationCoordinate2D(
                latitude: converted.latitude,
                longitude: converted.longitude
            )
        }
    }

    static func wgs84ToGCJ02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !isOutOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }
        var dLat = transformLatitude(x: longitude - 105, y: latitude - 35)
        var dLon = transformLongitude(x: longitude - 105, y: latitude - 35)

        let radLat = latitude / 180 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)

        dLat = (dLat * 180) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180) / (a / sqrtMagic * cos(radLat) * .pi)
        return (latitude + dLat, longitude + dLon)
    }

    private static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        longitude < 72.004 || longitude > 137.8347 || latitude < 0.8293 || latitude > 55.8271
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var ret = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        ret += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        ret += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return ret
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var ret = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        ret += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        ret += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return ret
    }
}

extension Coordinate {
    var mapCoordinate: CLLocationCoordinate2D {
        MapCoordinate.convert(self, from: MapDatum.api)
    }
}

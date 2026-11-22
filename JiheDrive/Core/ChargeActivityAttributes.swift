import Foundation
import ActivityKit

/// 灵动岛 / 锁屏 Live Activity：车辆充电进度（本地开启，不走 APNs）
struct ChargeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var soc: Int
        var rangeKm: Int
        var charging: Bool
        var etaText: String
        var vehicleName: String
        var batteryName: String
        var currentAmps: Double?
        var powerWatts: Double?
        var updatedAt: Date
    }

    var vin: String
}

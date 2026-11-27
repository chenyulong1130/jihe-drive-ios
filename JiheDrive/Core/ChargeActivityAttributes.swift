import Foundation
import ActivityKit

/// 灵动岛 / 锁屏 Live Activity：车辆充电进度（本地开启，不走 APNs）
struct ChargeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var soc: Int
        var rangeKm: Int
        var charging: Bool
        var etaText: String
        /// 预计充满时间点（chargeMinutes 换算）：有值时灵动岛倒计时自走，
        /// 两次本地同步之间也能实时走秒；nil 回退 etaText 静态文案
        var chargeEndTime: Date?
        var vehicleName: String
        var batteryName: String
        var currentAmps: Double?
        var powerWatts: Double?
        var updatedAt: Date
    }

    var vin: String
}

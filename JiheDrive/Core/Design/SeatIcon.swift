import SwiftUI

/// 坐垫开关图标：与小组件（JiheDriveWidget）同一套官方图标资源
/// （Assets 里的 SeatIconOpen / SeatIconClosed 模板图，随 tint 变色）。
struct SeatIcon: View {
    var size: CGFloat = 18
    /// true 显示坐垫打开态（小组件同款），默认合上态
    var open: Bool = false

    var body: some View {
        Image(open ? "SeatIconOpen" : "SeatIconClosed")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            // 小组件同款比例：23×16 槽位
            .frame(width: size, height: size * 16.0 / 23.0)
            .foregroundStyle(Theme.label)
    }
}

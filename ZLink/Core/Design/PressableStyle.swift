import SwiftUI

/// 按压反馈。
/// 默认是缩放 + 轻微提亮；传 sink 时改为整体下沉，不做回弹。
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var brightness: Double = 0.05
    var sink: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? (sink > 0 ? 1 : scale) : 1)
            .offset(y: configuration.isPressed ? sink : 0)
            .brightness(configuration.isPressed ? brightness : 0)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

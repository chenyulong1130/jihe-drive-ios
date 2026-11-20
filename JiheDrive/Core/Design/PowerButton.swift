import SwiftUI
import UIKit

/// 车辆主控按钮。
/// 锁定态：systemBlue 实心（动作：解锁）；解锁态：弱填充（动作：关锁）。
/// 用填充度区分状态，不靠红绿灯配色；按压为轻微下沉 + 触感反馈。
struct PowerButton: View {
    let locked: Bool
    let busy: Bool
    var enabled: Bool = true
    let action: () -> Void

    @State private var pressed = false

    private let height: CGFloat = 60

    private var title: String {
        if busy { return "请求中…" }
        return locked ? "一键解锁" : "一键关锁"
    }

    private var contentColor: Color {
        locked ? .white : Theme.brand
    }

    var body: some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView()
                    .tint(contentColor)
                    .scaleEffect(0.8)
            } else {
                Image(systemName: locked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }

            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(contentColor)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                .fill(locked ? Theme.brand : Theme.surfaceAlt)
        )
        .opacity(enabled ? 1 : 0.4)
        .scaleEffect(pressed ? 0.985 : 1)
        .shadow(color: locked ? Theme.brand.opacity(0.16) : .clear, radius: 16, x: 0, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, !busy, !pressed else { return }
                    withAnimation(Motion.quick) { pressed = true }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .onEnded { value in
                    let moved = abs(value.translation.width) + abs(value.translation.height)
                    withAnimation(Motion.softSpring) { pressed = false }
                    guard enabled, !busy else { return }
                    if moved < 24 { action() }
                }
        )
        .animation(Motion.spring, value: locked)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
    }
}

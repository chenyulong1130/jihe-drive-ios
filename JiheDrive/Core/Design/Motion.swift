import SwiftUI

/// 全局动效曲线，统一节奏
enum Motion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.78)
    static let softSpring = Animation.spring(response: 0.62, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.2)
    static let gauge = Animation.spring(response: 0.95, dampingFraction: 0.8)
    static let breathe = Animation.easeInOut(duration: 2.8).repeatForever(autoreverses: true)
    static let drift = Animation.easeInOut(duration: 9).repeatForever(autoreverses: true)
}

/// 错峰入场：index 越大延迟越久
struct StaggerIn: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .offset(y: shown ? 0 : 10)
            .onAppear {
                withAnimation(Motion.softSpring.delay(Double(index) * 0.06)) {
                    shown = true
                }
            }
    }
}

extension View {
    func staggerIn(_ index: Int) -> some View {
        modifier(StaggerIn(index: index))
    }
}

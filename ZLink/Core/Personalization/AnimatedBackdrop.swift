import SwiftUI
import UIKit

/// 内置动态主题：纯绘制，不占存储，不联网也能动
enum AnimatedBackdropKind: String, CaseIterable, Identifiable {
    case aurora = "a-aurora"
    case nebula = "a-nebula"
    case ember = "a-ember"
    case rain = "a-rain"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .aurora: return "极光"
        case .nebula: return "星云"
        case .ember: return "熔岩"
        case .rain: return "光雨"
        }
    }

    var desc: String {
        switch self {
        case .aurora: return "流动 · 冷光"
        case .nebula: return "呼吸 · 慢转"
        case .ember: return "上升 · 余烬"
        case .rain: return "下落 · 赛博"
        }
    }

    var baseColors: [Color] {
        switch self {
        case .aurora: return [Color(hex: 0x03121F), Color(hex: 0x07323A), Color(hex: 0x0A4A5A)]
        case .nebula: return [Color(hex: 0x0B0716), Color(hex: 0x241243), Color(hex: 0x3C1C63)]
        case .ember: return [Color(hex: 0x1A0805), Color(hex: 0x3D1206), Color(hex: 0x6B2108)]
        case .rain: return [Color(hex: 0x05070E), Color(hex: 0x0C1424), Color(hex: 0x12203A)]
        }
    }

    var accents: [Color] {
        switch self {
        case .aurora: return [Color(hex: 0x5FE3C0), Color(hex: 0x3AA0FF), Color(hex: 0x9A7BFF)]
        case .nebula: return [Color(hex: 0x8A6BFF), Color(hex: 0xE06BFF), Color(hex: 0x4A8AFF)]
        case .ember: return [Color(hex: 0xFFB347), Color(hex: 0xFF6B2C), Color(hex: 0xFF3D1F)]
        case .rain: return [Color(hex: 0x6FD3FF), Color.white]
        }
    }
}

struct AnimatedBackdrop: View {
    let kind: AnimatedBackdropKind
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isStill: Bool {
        !animated || reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: kind.baseColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if isStill {
                stillFrame
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    Canvas { context, size in
                        Self.draw(kind, context: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
    }

    /// 降级帧：不加动画，也要好看
    private var stillFrame: some View {
        RadialGradient(
            colors: [kind.accents[0].opacity(0.45), .clear],
            center: .init(x: 0.28, y: 0.3),
            startRadius: 4,
            endRadius: 260
        )
        .overlay(
            RadialGradient(
                colors: [kind.accents[1].opacity(0.35), .clear],
                center: .init(x: 0.82, y: 0.78),
                startRadius: 4,
                endRadius: 220
            )
        )
    }

    // MARK: - 绘制

    private static func draw(
        _ kind: AnimatedBackdropKind,
        context: inout GraphicsContext,
        size: CGSize,
        time: Double
    ) {
        guard size.width > 1, size.height > 1 else { return }
        let w = Double(size.width)
        let h = Double(size.height)

        switch kind {
        case .aurora:
            context.blendMode = .plusLighter
            context.addFilter(.blur(radius: size.height * 0.085))
            for band in 0..<3 {
                let color = kind.accents[band % kind.accents.count]
                let phase = time * (0.16 + Double(band) * 0.045) + Double(band) * 2.2
                let baseY = h * (0.40 + Double(band) * 0.13)
                let amp = h * 0.15

                var path = Path()
                path.move(to: CGPoint(x: -40, y: baseY))
                var x: Double = -40
                while x <= w + 40 {
                    let y = baseY
                        + sin(x / w * 3.1 + phase) * amp
                        + sin(x / w * 7.7 - phase * 1.5) * amp * 0.28
                    path.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                    x += 14
                }
                path.addLine(to: CGPoint(x: w + 40, y: h + 80))
                path.addLine(to: CGPoint(x: -40, y: h + 80))
                path.closeSubpath()

                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.5), color.opacity(0.02)]),
                        startPoint: CGPoint(x: 0, y: baseY - amp),
                        endPoint: CGPoint(x: 0, y: h)
                    )
                )
            }

        case .nebula:
            context.blendMode = .plusLighter
            context.addFilter(.blur(radius: size.height * 0.15))
            for index in 0..<4 {
                let color = kind.accents[index % kind.accents.count]
                let angle = time * 0.11 + Double(index) * 1.57
                let cx = w * (0.5 + 0.3 * cos(angle))
                let cy = h * (0.46 + 0.2 * sin(angle * 1.25))
                let radius = h * (0.32 + 0.07 * sin(angle * 0.8 + Double(index)))
                let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(0.45), color.opacity(0.0)]),
                        center: CGPoint(x: cx, y: cy),
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }

        case .ember:
            context.blendMode = .plusLighter
            context.addFilter(.blur(radius: 1.6))
            for index in 0..<28 {
                let seed = Double(index) * 1.37
                let speed = 0.07 + Double(index % 5) * 0.022
                let progress = (time * speed + seed).truncatingRemainder(dividingBy: 1)
                let baseX = (sin(seed * 3.1) * 0.5 + 0.5) * w
                let x = baseX + sin(time * 0.7 + seed) * 12
                let y = h * (1.08 - progress * 1.16)
                let radius = CGFloat(1.1 + Double(index % 4) * 0.75)
                let color = kind.accents[index % kind.accents.count]
                let alpha = 0.10 + 0.55 * sin(progress * .pi)
                context.fill(
                    Path(ellipseIn: CGRect(x: CGFloat(x) - radius, y: CGFloat(y) - radius, width: radius * 2, height: radius * 2)),
                    with: .color(color.opacity(alpha))
                )
            }

        case .rain:
            context.blendMode = .plusLighter
            for index in 0..<34 {
                let seed = Double(index) * 0.79
                let speed = 0.45 + Double(index % 6) * 0.16
                let progress = (time * speed + seed).truncatingRemainder(dividingBy: 1)
                let x = (sin(seed * 5.7) * 0.5 + 0.5) * w + progress * 34
                let y = progress * (h + 90) - 45
                let length = CGFloat(13 + Double(index % 5) * 9)
                var path = Path()
                path.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                path.addLine(to: CGPoint(x: CGFloat(x) - 5, y: CGFloat(y) + length))
                context.stroke(
                    path,
                    with: .color(Color.white.opacity(0.10 + 0.28 * sin(progress * .pi))),
                    lineWidth: CGFloat(0.8 + Double(index % 3) * 0.35)
                )
            }
        }
    }
}

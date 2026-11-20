import SwiftUI

/// 内置壁纸的绘制风格
enum WallpaperStyle {
    case mesh      // 多色柔光网格
    case horizon   // 地平线光晕
    case beams     // 斜向光柱
    case orbs      // 悬浮光球
    case grid      // 透视网格
    case rings     // 同心环
    case waves     // 层叠波纹
    case streak    // 斜切光带
    case carbon    // 碳纤维纹理
    case glow      // 中心辉光
}

struct BuiltInWallpaper: Identifiable, Hashable {
    let id: String
    let name: String
    let style: WallpaperStyle
    let colors: [Color]

    var accent: Color { colors.count > 2 ? colors[2] : (colors.first ?? Theme.brand) }

    static func == (lhs: BuiltInWallpaper, rhs: BuiltInWallpaper) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum WallpaperCatalog {
    static let all: [BuiltInWallpaper] = [
        BuiltInWallpaper(id: "w-deep", name: "深海", style: .mesh,
                         colors: [Color(hex: 0x04121F), Color(hex: 0x0A2A4A), Color(hex: 0x1D6FB8)]),
        BuiltInWallpaper(id: "w-dusk", name: "暮色", style: .horizon,
                         colors: [Color(hex: 0x1A0F2E), Color(hex: 0x4A2358), Color(hex: 0xE0703A)]),
        BuiltInWallpaper(id: "w-aurora", name: "极光", style: .beams,
                         colors: [Color(hex: 0x03150F), Color(hex: 0x0B3B33), Color(hex: 0x38E0A0)]),
        BuiltInWallpaper(id: "w-ember", name: "熔岩", style: .glow,
                         colors: [Color(hex: 0x1A0705), Color(hex: 0x5C1A0C), Color(hex: 0xFF6B2C)]),
        BuiltInWallpaper(id: "w-city", name: "夜城", style: .grid,
                         colors: [Color(hex: 0x05070F), Color(hex: 0x101C3A), Color(hex: 0x3D7BFF)]),
        BuiltInWallpaper(id: "w-orbit", name: "星轨", style: .rings,
                         colors: [Color(hex: 0x06070C), Color(hex: 0x1B1F3A), Color(hex: 0x8AA8FF)]),
        BuiltInWallpaper(id: "w-tide", name: "潮汐", style: .waves,
                         colors: [Color(hex: 0x031A24), Color(hex: 0x0A4A5C), Color(hex: 0x35C8D8)]),
        BuiltInWallpaper(id: "w-steel", name: "钢流", style: .streak,
                         colors: [Color(hex: 0x0C0E12), Color(hex: 0x232A33), Color(hex: 0x9AB4D0)]),
        BuiltInWallpaper(id: "w-carbon", name: "碳纤", style: .carbon,
                         colors: [Color(hex: 0x0A0B0D), Color(hex: 0x15181C), Color(hex: 0x4A5560)]),
        BuiltInWallpaper(id: "w-frost", name: "冰川", style: .orbs,
                         colors: [Color(hex: 0x081722), Color(hex: 0x1B4A66), Color(hex: 0x9FE4FF)]),
        BuiltInWallpaper(id: "w-plum", name: "暗紫", style: .mesh,
                         colors: [Color(hex: 0x0B0614), Color(hex: 0x2A1350), Color(hex: 0x8A5CFF)]),
        BuiltInWallpaper(id: "w-mono", name: "单色", style: .horizon,
                         colors: [Color(hex: 0x101114), Color(hex: 0x2C2F35), Color(hex: 0x7C8794)])
    ]

    static func item(id: String) -> BuiltInWallpaper? {
        all.first(where: { $0.id == id })
    }
}

/// 内置壁纸实时绘制：任何尺寸都铺满，不依赖图片资源
struct BuiltInWallpaperView: View {
    let wallpaper: BuiltInWallpaper

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                base
                decoration(size: size)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .background((wallpaper.colors.first ?? Color.black).ignoresSafeArea())
    }

    private var base: some View {
        LinearGradient(
            colors: wallpaper.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func accent(_ opacity: Double) -> Color {
        wallpaper.accent.opacity(opacity)
    }

    @ViewBuilder
    private func decoration(size: CGSize) -> some View {
        switch wallpaper.style {
        case .mesh:
            ZStack {
                blob(color: accent(0.55), diameter: size.width * 0.9)
                    .offset(x: -size.width * 0.28, y: -size.height * 0.24)
                blob(color: Color.white.opacity(0.10), diameter: size.width * 0.6)
                    .offset(x: size.width * 0.34, y: size.height * 0.20)
                blob(color: accent(0.32), diameter: size.width * 0.5)
                    .offset(x: size.width * 0.12, y: size.height * 0.42)
            }

        case .horizon:
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [accent(0.85), accent(0.0)],
                            center: .center,
                            startRadius: 2,
                            endRadius: size.width * 0.62
                        )
                    )
                    .frame(width: size.width * 1.4, height: size.height * 0.55)
                    .offset(y: size.height * 0.30)

                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 0.8)
                    .offset(y: size.height * 0.30)
            }

        case .beams:
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent(0.0), accent(0.55), accent(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: size.width * 0.16, height: size.height * 1.6)
                        .rotationEffect(.degrees(24))
                        .blur(radius: 26)
                        .offset(x: size.width * (-0.26 + 0.26 * CGFloat(index)),
                                y: size.height * (0.06 * CGFloat(index) - 0.12))
                }
            }

        case .orbs:
            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(accent(0.34))
                        .frame(width: size.width * 0.16, height: size.width * 0.16)
                        .blur(radius: 22)
                        .offset(
                            x: size.width * (-0.30 + 0.15 * CGFloat(index)),
                            y: size.height * (0.26 - 0.11 * CGFloat(index))
                        )
                }
            }

        case .grid:
            Canvas { context, canvasSize in
                let step: CGFloat = max(26, canvasSize.width / 12)
                var path = Path()
                var x: CGFloat = 0
                while x <= canvasSize.width {
                    path.move(to: CGPoint(x: x, y: canvasSize.height * 0.42))
                    path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                    x += step
                }
                var y: CGFloat = canvasSize.height * 0.42
                while y <= canvasSize.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                    y += step * 0.7
                }
                context.stroke(path, with: .color(accent(0.28)), lineWidth: 0.7)
            }

        case .rings:
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .stroke(accent(0.30 - Double(index) * 0.06), lineWidth: 1)
                        .frame(
                            width: size.width * (0.42 + CGFloat(index) * 0.20),
                            height: size.width * (0.42 + CGFloat(index) * 0.20)
                        )
                        .offset(x: size.width * 0.18, y: -size.height * 0.10)
                }
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 5, height: 5)
                    .offset(x: size.width * 0.18, y: -size.height * 0.10)
            }

        case .waves:
            Canvas { context, canvasSize in
                for index in 0..<4 {
                    var path = Path()
                    let baseY = canvasSize.height * (0.58 + 0.10 * CGFloat(index))
                    let amplitude = canvasSize.height * 0.045
                    let phase = CGFloat(index) * 0.9
                    path.move(to: CGPoint(x: 0, y: baseY))
                    var x: CGFloat = 0
                    while x <= canvasSize.width {
                        let angle = (x / canvasSize.width) * .pi * 2.4 + phase
                        path.addLine(to: CGPoint(x: x, y: baseY + sin(angle) * amplitude))
                        x += 4
                    }
                    context.stroke(
                        path,
                        with: .color(accent(0.44 - Double(index) * 0.09)),
                        lineWidth: 1.4
                    )
                }
            }

        case .streak:
            ZStack {
                ForEach(0..<4, id: \.self) { index in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.0), Color.white.opacity(0.16), Color.white.opacity(0.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: size.width * 0.9, height: size.height * 0.06)
                        .rotationEffect(.degrees(-28))
                        .offset(x: size.width * 0.10,
                                y: size.height * (-0.28 + 0.16 * CGFloat(index)))
                }
            }

        case .carbon:
            Canvas { context, canvasSize in
                let step: CGFloat = 7
                var down = Path()
                var up = Path()
                var offset: CGFloat = -canvasSize.height
                while offset < canvasSize.width {
                    down.move(to: CGPoint(x: offset, y: 0))
                    down.addLine(to: CGPoint(x: offset + canvasSize.height, y: canvasSize.height))
                    up.move(to: CGPoint(x: offset + canvasSize.height, y: 0))
                    up.addLine(to: CGPoint(x: offset, y: canvasSize.height))
                    offset += step
                }
                context.stroke(down, with: .color(Color.white.opacity(0.045)), lineWidth: 1)
                context.stroke(up, with: .color(Color.black.opacity(0.35)), lineWidth: 1)
            }

        case .glow:
            ZStack {
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [accent(0.90), accent(0.18), accent(0.0)],
                            center: .center,
                            startRadius: 4,
                            endRadius: size.width * 0.55
                        )
                    )
                    .frame(width: size.width * 1.2, height: size.height * 0.9)
                    .offset(y: size.height * 0.26)
            }
        }
    }

    private func blob(color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: 28)
    }
}

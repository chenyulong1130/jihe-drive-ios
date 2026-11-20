import SwiftUI

/// 坐垫开关图标：斜置胶囊（座垫）+ 下缘横线 + 右下螺旋钩。
/// 几何照搬安卓版 `_SeatIconPainter`（内容框 61×46）。
struct SeatIcon: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 61
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -1, y: -7)

            let lineWidth: CGFloat = 4.6
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            // 座垫：48×27 圆角胶囊，逆时针斜 42.5°
            context.drawLayer { layer in
                layer.translateBy(x: 23.5, y: 27.5)
                layer.rotate(by: .degrees(-42.5))
                let rect = CGRect(
                    x: -(48 - lineWidth) / 2,
                    y: -(27 - lineWidth) / 2,
                    width: 48 - lineWidth,
                    height: 27 - lineWidth
                )
                let capsule = Path(
                    roundedRect: rect,
                    cornerRadius: (27 - lineWidth) / 2
                )
                layer.stroke(capsule, with: .foreground, style: stroke)
            }

            // 下缘横线
            var base = Path()
            base.move(to: CGPoint(x: 7, y: 51))
            base.addLine(to: CGPoint(x: 33.5, y: 51))
            context.stroke(base, with: .foreground, style: stroke)

            // 右下螺旋钩
            var spiral = Path()
            let steps = 48
            for index in 0...steps {
                let t = Double(index) / Double(steps)
                let angle = (155 + 348 * t) * .pi / 180
                let radius = 9.6 - 5.2 * t
                let point = CGPoint(
                    x: 52.5 + radius * cos(angle),
                    y: 41.5 + radius * sin(angle)
                )
                if index == 0 {
                    spiral.move(to: point)
                } else {
                    spiral.addLine(to: point)
                }
            }
            context.stroke(spiral, with: .foreground, style: stroke)
        }
        .frame(width: size, height: size * 46 / 61)
        .foregroundStyle(Theme.label)
    }
}

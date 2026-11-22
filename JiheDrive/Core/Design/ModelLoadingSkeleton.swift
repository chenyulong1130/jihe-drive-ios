import SwiftUI

/// 3D 模型加载骨架：车形占位块 + 呼吸动效，下载完成后由调用方移除
struct ModelLoadingSkeleton: View {
    /// 1 为主视觉标准大小，缩放适配不同舞台
    var scale: CGFloat = 1

    @State private var pulse = false

    private var fill: Color { Theme.label.opacity(pulse ? 0.07 : 0.15) }

    var body: some View {
        VStack(spacing: 16 * scale) {
            carShape
            Text("正在加载 3D 模型")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var carShape: some View {
        ZStack(alignment: .bottom) {
            // 车身
            RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                .fill(fill)
                .frame(width: 248 * scale, height: 78 * scale)
            // 轮子
            HStack(spacing: 88 * scale) {
                Circle().fill(fill).frame(width: 26 * scale, height: 26 * scale)
                Circle().fill(fill).frame(width: 26 * scale, height: 26 * scale)
            }
            .offset(y: 13 * scale)
        }
        .overlay(alignment: .top) {
            // 座舱
            RoundedRectangle(cornerRadius: 15 * scale, style: .continuous)
                .fill(fill)
                .frame(width: 118 * scale, height: 40 * scale)
                .offset(y: -28 * scale)
        }
        .fixedSize()
    }
}

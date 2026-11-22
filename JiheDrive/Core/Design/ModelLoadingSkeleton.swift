import SwiftUI

/// 3D 模型加载中：转圈 + 文案，下载完成后由调用方移除
struct ModelLoadingSkeleton: View {
    /// 1 为主视觉标准大小，缩放适配不同舞台
    var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 12 * scale) {
            ProgressView()
                .scaleEffect(1.1 * scale)
                .padding(6 * scale)
            Text("正在加载 3D 模型")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

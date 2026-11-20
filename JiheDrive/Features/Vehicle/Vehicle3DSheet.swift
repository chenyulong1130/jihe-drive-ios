import SceneKit
import SwiftUI

/// 3D 看车：只用接口返回的模型，没有模型就展示官方车图。
struct Vehicle3DSheet: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = VehicleModelLoader()
    @State private var resetToken = 0

    private var modelURL: URL? { vehicle.model3DURL }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                stage(height: max(340, proxy.size.height * 0.56))
                controls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.groupedBackground.ignoresSafeArea())
        .task(id: vehicle.vinNo) {
            loader.load(modelURL)
        }
    }

    // MARK: - 舞台

    private func stage(height: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: 0x081018),
                    Color(hex: 0x122236),
                    Color(hex: 0x060B10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [Color(hex: 0x2F6FD0).opacity(0.30), Color.clear],
                center: .init(x: 0.5, y: 0.44),
                startRadius: 8,
                endRadius: 260
            )

            stageContent
                .padding(.horizontal, 12)
                .padding(.top, 46)
                .padding(.bottom, 44)

            VStack {
                header
                Spacer(minLength: 0)
                if loader.scene != nil {
                    hint
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 28,
                bottomTrailingRadius: 28,
                topTrailingRadius: 0
            )
        )
    }

    @ViewBuilder
    private var stageContent: some View {
        if let scene = loader.scene {
            VehicleSceneView(scene: scene, interactive: true, autoSpin: true)
                .id(resetToken)
        } else {
            switch loader.state {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在加载车辆模型")
                        .font(Theme.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 30, weight: .light))
                    Text("模型加载失败")
                        .font(.system(size: 15, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11.5))
                        .multilineTextAlignment(.center)
                        .opacity(0.72)
                        .padding(.horizontal, 20)
                }
                .foregroundStyle(.white.opacity(0.9))
            default:
                photoStage
            }
        }
    }

    private var photoStage: some View {
        VStack(spacing: 14) {
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 200, height: 14)
                    .blur(radius: 12)
                    .offset(y: 74)

                if let url = vehicle.imageURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFit()
                                .shadow(color: .black.opacity(0.4), radius: 18, x: 0, y: 10)
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt.car.fill")
                            .font(.system(size: 46, weight: .light))
                        Text("暂无车辆图片")
                            .font(Theme.footnote)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity)

            Text("该车型接口未返回 3D 模型")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text(loader.scene != nil ? "官方 3D 模型" : "官方车辆图片")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer(minLength: 8)

            if loader.scene != nil {
                Button {
                    withAnimation(Motion.quick) { resetToken += 1 }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 10, weight: .medium))
            Text("拖动旋转 · 双指缩放")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .padding(.bottom, 14)
    }

    // MARK: - 控制区

    private var controls: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                AppleCard(padding: 14) {
                    VStack(spacing: 12) {
                        CardTitle(text: "整车状态", icon: "cube.transparent", tint: Theme.brand)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                            spacing: 10
                        ) {
                            metric("电量", "\(vehicle.soc)%", Theme.brand)
                            metric("续航", "\(vehicle.rangeKm) km", Theme.green)
                            metric("总里程", String(format: "%.0f km", vehicle.totalMileKm), Theme.indigo)
                            metric("车锁", vehicle.isLocked ? "已上锁" : "未锁", vehicle.isLocked ? Theme.label : Theme.orange)
                            metric("状态", vehicle.isOnline ? "在线" : "离线", vehicle.isOnline ? Theme.green : Theme.secondary)
                            metric("信号", "\(vehicle.signalLevel) 级", Theme.teal)
                        }
                    }
                }

                AppleCard(padding: 14) {
                    VStack(spacing: 0) {
                        InfoRow(title: "3D 模型", value: modelURL == nil ? "接口未提供" : "已提供")
                            .padding(.bottom, 10)
                        HairLine()
                        InfoRow(title: "VIN", value: vehicle.vinNo, mono: true)
                            .padding(.top, 10)
                    }
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
    }

    private func metric(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.surfaceAlt)
        }
    }
}

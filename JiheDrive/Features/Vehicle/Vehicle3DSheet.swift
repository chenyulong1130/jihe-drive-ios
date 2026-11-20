import SceneKit
import SwiftUI

/// 3D 看车：优先加载官方模型，没有模型时用内置踏板车（可换涂装）。
struct Vehicle3DSheet: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = VehicleModelLoader()

    @State private var paintIndex = 0
    @State private var builtScene: SCNScene?
    @State private var resetToken = 0

    private var activeScene: SCNScene? { loader.scene ?? builtScene }
    private var usingOfficial: Bool { loader.scene != nil }

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
            loader.load(vehicle.model3DURL)
            if builtScene == nil {
                builtScene = VehicleSceneBuilder.build(paint: VehicleSceneBuilder.paints[paintIndex].hex)
            }
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
                center: .init(x: 0.5, y: 0.42),
                startRadius: 8,
                endRadius: 260
            )

            if let scene = activeScene {
                VehicleSceneView(scene: scene, interactive: true, autoSpin: true)
                    .id("\(resetToken)-\(usingOfficial ? "official" : "builtin-\(paintIndex)")")
                    .padding(.horizontal, 4)
            } else {
                loadingHint
            }

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(vehicle.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(usingOfficial ? "官方 3D 模型" : "内置高精度模型")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer(minLength: 8)
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

                Spacer(minLength: 0)

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

    private var loadingHint: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("正在加载车辆模型")
                .font(Theme.footnote)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: - 控制区

    private var controls: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if !usingOfficial {
                    paintRow
                }

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

                Text("VIN \(vehicle.vinNo)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
    }

    private var paintRow: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "涂装", icon: "paintpalette.fill", tint: Theme.brand, trailing: VehicleSceneBuilder.paints[paintIndex].name)

                HStack(spacing: 10) {
                    ForEach(Array(VehicleSceneBuilder.paints.enumerated()), id: \.offset) { index, item in
                        Button {
                            guard paintIndex != index else { return }
                            paintIndex = index
                            builtScene = VehicleSceneBuilder.build(paint: item.hex)
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: item.hex))
                                        .frame(width: 38, height: 38)
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                                        .frame(width: 38, height: 38)
                                    if paintIndex == index {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                Text(item.name)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(paintIndex == index ? Theme.label : Theme.tertiary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                    }
                }
            }
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

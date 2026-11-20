import SceneKit
import SwiftUI
import UIKit

/// 主视觉背景来源
enum BackdropSelection: Equatable {
    case video
    case photo
    case animated(AnimatedBackdropKind)
    case builtin(BuiltInWallpaper)
    case theme(VehicleTheme)

    var isDefault: Bool {
        if case .theme(let theme) = self { return theme.isDefault }
        return false
    }
}

/// 车辆主视觉：铺满屏幕宽度，背景走 `.background` 不参与布局测量
struct HeroStage: View {
    let vehicle: Vehicle
    let selection: BackdropSelection
    let videoURL: URL?
    let videoPoster: UIImage?
    let photo: UIImage?
    let modelScene: SCNScene?
    var topInset: CGFloat = 12
    var height: CGFloat = 420
    var cornerRadius: CGFloat = 28
    let onPickVehicle: () -> Void
    let onOpenTheme: () -> Void

    private var onDark: Bool { !selection.isDefault }

    private var primary: Color { onDark ? .white : Theme.label }
    private var secondaryText: Color { onDark ? Color.white.opacity(0.78) : Theme.secondary }

    var body: some View {
        ZStack(alignment: .bottom) {
            carLayer

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, 16)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background { backdrop }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0
            )
        )
        .overlay(alignment: .bottom) {
            if !onDark {
                Rectangle()
                    .fill(Theme.separator.opacity(0.7))
                    .frame(height: 0.5)
            }
        }
    }

    // MARK: - 背景

    @ViewBuilder
    private var backdrop: some View {
        Group {
            switch selection {
            case .video:
                if let videoURL {
                    ZStack {
                        if let videoPoster {
                            fillImage(videoPoster)
                        } else {
                            Color(hex: 0x0B1A16)
                        }
                        Color.clear.overlay {
                            LoopingVideoView(url: videoURL)
                        }
                    }
                    .overlay(scrim)
                } else {
                    placeholderBackdrop.overlay(scrim)
                }

            case .photo:
                if let photo {
                    fillImage(photo).overlay(scrim)
                } else {
                    placeholderBackdrop.overlay(scrim)
                }

            case .animated(let kind):
                AnimatedBackdrop(kind: kind).overlay(scrim)

            case .builtin(let wallpaper):
                BuiltInWallpaperView(wallpaper: wallpaper).overlay(scrim)

            case .theme(let theme):
                if theme.isDefault {
                    Color.clear
                } else {
                    themeBackground(theme).overlay(scrim)
                }
            }
        }
        .clipped()
    }

    private func fillImage(_ image: UIImage) -> some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .allowsHitTesting(false)
            }
            .clipped()
    }

    @ViewBuilder
    private func themeBackground(_ theme: VehicleTheme) -> some View {
        if let poster = theme.posterURL {
            ZStack {
                LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Color.clear.overlay {
                    AsyncImage(url: poster) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
                .clipped()
            }
        } else {
            LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var placeholderBackdrop: some View {
        LinearGradient(
            colors: [Color(hex: 0x102A38), Color(hex: 0x1E4A5A), Color(hex: 0x2C6E63)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 上暗下更暗，白字在任何背景上都读得清
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.34), location: 0),
                .init(color: Color.black.opacity(0.02), location: 0.36),
                .init(color: Color.black.opacity(0.08), location: 0.66),
                .init(color: Color.black.opacity(0.46), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 车

    @ViewBuilder
    private var carLayer: some View {
        if let modelScene {
            ZStack(alignment: .bottom) {
                VehicleSceneView(scene: modelScene, interactive: false, autoSpin: true, spinSpeed: 0.16)
                    .padding(.bottom, 34)

                modelBadge
                    .padding(.bottom, 96)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        } else {
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(Color.black.opacity(onDark ? 0.30 : 0.10))
                    .frame(width: 224, height: 16)
                    .blur(radius: 12)
                    .offset(y: 6)

                Group {
                    if let url = vehicle.imageURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                placeholder
                            }
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 224)
                .shadow(color: Color.black.opacity(onDark ? 0.34 : 0.12), radius: 18, x: 0, y: 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 54)
            .allowsHitTesting(false)
        }
    }

    private var modelBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "cube.transparent.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("3D 模型")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(primary.opacity(0.9))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(onDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Theme.surfaceAlt))
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.car.fill")
                .font(.system(size: 56, weight: .regular))
            Text("暂未获取车辆图片")
                .font(Theme.caption)
        }
        .foregroundStyle(primary.opacity(0.75))
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onPickVehicle) {
                HStack(spacing: 5) {
                    Text(vehicle.name)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(secondaryText)
                }
                .frame(minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

            Spacer(minLength: 8)

            Button(action: onOpenTheme) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primary)
                    .frame(width: 36, height: 36)
                    .background {
                        Circle()
                            .fill(onDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Theme.surface.opacity(0.9)))
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
            .accessibilityLabel("更换车辆背景")
        }
    }

    // MARK: - 底部：电量 + 数据

    private var bottomBar: some View {
        HStack(spacing: 10) {
            socRing

            Rectangle()
                .fill(primary.opacity(0.16))
                .frame(width: 0.5, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("续航")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(vehicle.rangeKm)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(primary)
                        .monospacedDigit()
                    Text("km")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
            }

            Spacer(minLength: 4)

            statusTag
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(onDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Theme.surface.opacity(0.92)))
        }
    }

    private var socRing: some View {
        HStack(spacing: 8) {
            ZStack {
                RingProgress(
                    progress: Double(min(max(vehicle.soc, 0), 100)) / 100,
                    color: socColor,
                    track: primary.opacity(0.18),
                    lineWidth: 3,
                    size: 34
                )
                Image(systemName: vehicle.isCharging ? "bolt.fill" : "battery.50percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(primary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(min(max(vehicle.soc, 0), 100))")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    private var socColor: Color {
        if vehicle.isCharging { return Theme.green }
        if vehicle.soc <= 15 { return Theme.red }
        if vehicle.soc <= 30 { return Theme.orange }
        return onDark ? .white : Theme.brand
    }

    @ViewBuilder
    private var statusTag: some View {
        let tag: (String, String, Color) = {
            if vehicle.isCharging { return ("充电中", "bolt.fill", Theme.green) }
            if !vehicle.isOnline { return ("离线", "wifi.slash", secondaryText) }
            if !vehicle.isLocked { return ("未锁车", "lock.open.fill", Theme.orange) }
            return ("已上锁", "lock.fill", primary)
        }()

        HStack(spacing: 4) {
            Image(systemName: tag.1)
                .font(.system(size: 9.5, weight: .semibold))
            Text(tag.0)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tag.2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(tag.2.opacity(onDark ? 0.22 : 0.12))
        }
    }
}

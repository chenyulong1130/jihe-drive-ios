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

/// 车辆主视觉：左右贴边铺满，背景走 `.background` 不参与布局测量
struct HeroStage: View {
    let vehicle: Vehicle
    let selection: BackdropSelection
    let videoURL: URL?
    let videoPoster: UIImage?
    let photo: UIImage?
    let modelScene: SCNScene?
    /// 接口给的是 glb 时就地渲染（与安卓版同一套 model-viewer）
    var modelGLBFile: URL? = nil
    /// 官方胎压接口读数（bar），优先于车辆详情里的字段
    var tireFrontBar: Double? = nil
    var tireRearBar: Double? = nil
    var topInset: CGFloat = 12
    var height: CGFloat = 470
    var cornerRadius: CGFloat = 30
    let onPickVehicle: () -> Void
    let onOpenWallpaper: () -> Void
    let onOpenTheme: () -> Void

    private var onDark: Bool { !selection.isDefault }

    private var primary: Color { onDark ? .white : Theme.label }
    private var secondaryText: Color { onDark ? Color.white.opacity(0.8) : Theme.secondary }
    private var glass: AnyShapeStyle {
        onDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Theme.surface)
    }

    var body: some View {
        ZStack {
            carLayer

            VStack(spacing: 0) {
                topRow
                batteryBlock
                    .padding(.top, 14)
                Spacer(minLength: 8)
                tireStrip
            }
            .padding(.horizontal, 18)
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

    // MARK: - 车 / 3D

    @ViewBuilder
    private var carLayer: some View {
        if let modelGLBFile {
            Color.clear
                .overlay {
                    ModelViewerWebView(glbFile: modelGLBFile, interactive: false, autoRotate: true)
                }
                .padding(.top, 88)
                .padding(.bottom, 96)
                .allowsHitTesting(false)
        } else if let modelScene {
            VehicleSceneView(scene: modelScene, interactive: false, autoSpin: true, spinSpeed: 0.16)
                .padding(.top, 92)
                .padding(.bottom, 96)
                .allowsHitTesting(false)
        } else {
            ZStack {
                Ellipse()
                    .fill(Color.black.opacity(onDark ? 0.28 : 0.09))
                    .frame(width: 218, height: 15)
                    .blur(radius: 12)
                    .offset(y: 10)

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
                .frame(height: 230)
                .shadow(color: Color.black.opacity(onDark ? 0.30 : 0.10), radius: 18, x: 0, y: 12)
            }
            .frame(maxWidth: .infinity)
            .offset(y: 26)
            .allowsHitTesting(false)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.car.fill")
                .font(.system(size: 54, weight: .regular))
            Text("暂未获取车辆图片")
                .font(Theme.caption)
        }
        .foregroundStyle(primary.opacity(0.7))
    }

    // MARK: - 顶部：车辆切换 + 壁纸 / 主题

    private var topRow: some View {
        HStack(spacing: 10) {
            Button(action: onPickVehicle) {
                HStack(spacing: 5) {
                    Text(vehicle.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(secondaryText)
                }
                .frame(minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

            statusTag

            Spacer(minLength: 6)

            circleAction(icon: "photo.on.rectangle.angled", label: "壁纸", action: onOpenWallpaper)
            circleAction(icon: "play.rectangle.fill", label: "主题", action: onOpenTheme)
        }
    }

    private func circleAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(glass))
                .contentShape(Circle())
                .accessibilityLabel(label)
        }
        .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
    }

    // MARK: - 电量进度条 + 续航

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(primary.opacity(0.18))
                        .frame(height: 9)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [socColor, socColor.opacity(0.78)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(9, proxy.size.width * socRatio), height: 9)
                }
            }
            .frame(height: 9)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(soc)")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)

                Text(chargeHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)

                Spacer(minLength: 8)

                Text("续航")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)
                Text("\(vehicle.rangeKm)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("km")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    private var soc: Int { min(max(vehicle.soc, 0), 100) }
    private var socRatio: CGFloat { CGFloat(soc) / 100 }

    private var socColor: Color {
        if vehicle.isCharging { return Theme.green }
        if soc <= 15 { return Theme.red }
        if soc <= 30 { return Theme.orange }
        return onDark ? .white : Theme.brand
    }

    private var chargeHint: String {
        if vehicle.isCharging { return "充电中" }
        return vehicle.isOnline ? "" : "离线"
    }

    // MARK: - 胎压

    @ViewBuilder
    private var tireStrip: some View {
        HStack(spacing: 0) {
            tireCell(title: "前轮", bar: frontBar)
            Rectangle()
                .fill(primary.opacity(0.14))
                .frame(width: 0.5, height: 34)
            tireCell(title: "后轮", bar: rearBar)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(glass)
        }
    }

    private var frontBar: Double? {
        tireFrontBar ?? vehicle.tireFrontKpa.map { $0 / 100 }
    }

    private var rearBar: Double? {
        tireRearBar ?? vehicle.tireRearKpa.map { $0 / 100 }
    }

    private func tireCell(title: String, bar: Double?) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(bar.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tireTint(bar))
                        .monospacedDigit()
                    Text("bar")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
            }

            Spacer(minLength: 4)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(primary.opacity(0.14))
                    .frame(width: 52, height: 5)
                Capsule()
                    .fill(tireTint(bar))
                    .frame(width: max(5, 52 * tireRatio(bar)), height: 5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }

    private func tireRatio(_ bar: Double?) -> CGFloat {
        guard let bar else { return 0.04 }
        return CGFloat(min(1, max(0.06, bar / 3.2)))
    }

    private func tireTint(_ bar: Double?) -> Color {
        guard let bar else { return secondaryText }
        if bar < 1.8 { return Theme.red }
        if bar < 2.1 || bar > 2.9 { return Theme.orange }
        return Theme.green
    }

    // MARK: - 状态

    private var statusTag: some View {
        let tag: (String, String, Color) = {
            if vehicle.isCharging { return ("充电中", "bolt.fill", Theme.green) }
            if !vehicle.isOnline { return ("离线", "wifi.slash", secondaryText) }
            if !vehicle.isLocked { return ("未锁", "lock.open.fill", Theme.orange) }
            return ("已锁", "lock.fill", primary)
        }()

        return HStack(spacing: 3) {
            Image(systemName: tag.1)
                .font(.system(size: 9, weight: .semibold))
            Text(tag.0)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(tag.2)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(tag.2.opacity(onDark ? 0.22 : 0.10))
        }
    }
}

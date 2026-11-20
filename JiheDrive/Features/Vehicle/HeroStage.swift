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
    let onPickVehicle: () -> Void
    /// 车机仪表壁纸（不是英雄区背景）
    let onOpenDashboardWallpaper: () -> Void
    /// 车辆页动态主题（视频背景）
    let onOpenTheme: () -> Void
    let onOpenCushion: () -> Void

    private var onDark: Bool { !selection.isDefault || videoURL != nil }

    private var primary: Color { onDark ? .white : Theme.label }
    private var secondaryText: Color { onDark ? Color.white.opacity(0.78) : Theme.secondary }

    var body: some View {
        ZStack {
            carLayer

            VStack(spacing: 0) {
                topRow
                batteryBlock
                    .padding(.top, 10)
                statusRow
                    .padding(.top, 10)
                Spacer(minLength: 8)
                tireStrip
            }
            .padding(.horizontal, 18)
            .padding(.top, topInset)
            .padding(.bottom, 28)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background { backdrop }
        .overlay(alignment: .bottom) {
            // 向下淡入内容区，避免硬切（对齐 Flutter 76%→100% 透明）
            LinearGradient(
                colors: [
                    Color.clear,
                    (onDark ? Color.black.opacity(0.22) : Theme.groupedBackground.opacity(0.55))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 72)
            .allowsHitTesting(false)
        }
        .clipped()
    }

    // MARK: - 背景

    @ViewBuilder
    private var backdrop: some View {
        Group {
            switch selection {
            case .video:
                videoBackdrop(url: videoURL, poster: videoPoster.map { .image($0) } ?? .none)

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
                } else if let remote = theme.videoURL {
                    // 云端动态主题：封面垫底 + 循环视频（以前只贴了静图）
                    videoBackdrop(url: remote, poster: .remote(theme.posterURL))
                } else {
                    themeBackground(theme).overlay(scrim)
                }
            }
        }
        .clipped()
    }

    private enum PosterSource {
        case none
        case image(UIImage)
        case remote(URL?)
    }

    @ViewBuilder
    private func videoBackdrop(url: URL?, poster: PosterSource) -> some View {
        if let url {
            ZStack {
                switch poster {
                case .image(let img):
                    fillImage(img)
                case .remote(let remote):
                    if let remote {
                        Color.clear.overlay {
                            AsyncImage(url: remote) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color(hex: 0x0B1A16)
                                }
                            }
                        }
                        .clipped()
                    } else {
                        Color(hex: 0x0B1A16)
                    }
                case .none:
                    Color(hex: 0x0B1A16)
                }

                Color.clear.overlay {
                    LoopingVideoView(url: url)
                }
                .allowsHitTesting(false)
            }
            .overlay(scrim)
        } else {
            placeholderBackdrop.overlay(scrim)
        }
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

    /// 上暗下更暗，白字在任何背景上都读得清（对齐小程序顶部压暗）
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.42), location: 0),
                .init(color: Color.black.opacity(0.04), location: 0.28),
                .init(color: Color.black.opacity(0.08), location: 0.68),
                .init(color: Color.black.opacity(0.38), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    // MARK: - 车 / 3D

    @ViewBuilder
    private var carLayer: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let modelGLBFile {
                    Color.clear
                        .overlay {
                            ModelViewerWebView(glbFile: modelGLBFile, interactive: false, autoRotate: true)
                        }
                        .padding(.top, 96)
                        .padding(.bottom, 88)
                        .allowsHitTesting(false)
                } else if let modelScene {
                    VehicleSceneView(scene: modelScene, interactive: false, autoSpin: true, spinSpeed: 0.16)
                        .padding(.top, 100)
                        .padding(.bottom, 88)
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
                        .frame(height: 210)
                        .shadow(color: Color.black.opacity(onDark ? 0.30 : 0.10), radius: 18, x: 0, y: 12)
                    }
                    .frame(maxWidth: .infinity)
                    .offset(y: 28)
                    .allowsHitTesting(false)
                }
            }

            // 坐垫：叠在车图右上（对齐 Flutter / 小程序），不进顶栏
            Button(action: onOpenCushion) {
                SeatIcon(size: 18)
                    .foregroundStyle(Theme.label)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.92))
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
            .padding(.top, 96)
            .padding(.trailing, 16)
            .accessibilityLabel("打开坐垫")
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

    // MARK: - 顶部：车名 + 主题(衣服) + 仪表壁纸 —— 对齐 Flutter

    private var topRow: some View {
        HStack(spacing: 10) {
            Button(action: onPickVehicle) {
                HStack(spacing: 5) {
                    Text(vehicle.name)
                        .font(.system(size: 19, weight: .heavy))
                        .foregroundStyle(primary)
                        .shadow(color: onDark ? Color.black.opacity(0.2) : .clear, radius: 8)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(secondaryText)
                }
                .frame(minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                // 主题：衣服图标（动态视频背景）
                frostedCircle(action: onOpenTheme, label: "主题") {
                    Image("ThemeShirt")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                }
                // 壁纸：车机仪表壁纸
                frostedCircle(action: onOpenDashboardWallpaper, label: "仪表壁纸") {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                }
            }
        }
    }

    private func frostedCircle<Content: View>(
        action: @escaping () -> Void,
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.82)))
                .shadow(color: Color.black.opacity(0.06), radius: 6, y: 1)
                .contentShape(Circle())
                .accessibilityLabel(label)
        }
        .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
    }

    // MARK: - 电量

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(soc)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryText)

                Spacer(minLength: 12)

                Text("\(vehicle.rangeKm)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text(" km")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryText)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(primary.opacity(0.18))
                        .frame(height: 4)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [socColor, socColor.opacity(0.72)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, proxy.size.width * socRatio), height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            statusChip(
                icon: vehicle.isOnline ? "wifi" : "wifi.slash",
                text: vehicle.isOnline ? "在线" : "离线",
                tint: vehicle.isOnline ? Theme.green : secondaryText
            )
            statusChip(
                icon: "cellularbars",
                text: "信号 \(vehicle.signalLevel)",
                tint: secondaryText
            )
            statusChip(
                icon: vehicle.isCharging ? "bolt.fill" : (vehicle.isLocked ? "lock.fill" : "lock.open.fill"),
                text: vehicle.isCharging ? "充电中" : (vehicle.isLocked ? "已上锁" : "未解锁"),
                tint: vehicle.isCharging
                    ? Theme.green
                    : (vehicle.isLocked ? primary.opacity(0.9) : Color(hex: 0xFF9F0A))
            )
            Spacer(minLength: 0)
        }
    }

    private func statusChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(primary.opacity(onDark ? 0.12 : 0.06))
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

    // MARK: - 胎压

    @ViewBuilder
    private var tireStrip: some View {
        let front = frontBar
        let rear = rearBar

        if front != nil || rear != nil {
            HStack(spacing: 0) {
                if let front {
                    tireCell(title: "前轮", bar: front)
                }

                if front != nil && rear != nil {
                    Rectangle()
                        .fill(primary.opacity(0.14))
                        .frame(width: 0.5, height: 30)
                }

                if let rear {
                    tireCell(title: "后轮", bar: rear)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
    }

    private var frontBar: Double? {
        tireFrontBar ?? vehicle.tireFrontKpa.map { $0 / 100 }
    }

    private var rearBar: Double? {
        tireRearBar ?? vehicle.tireRearKpa.map { $0 / 100 }
    }

    private func tireCell(title: String, bar: Double) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", bar))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tireTint(bar))
                        .monospacedDigit()
                    Text("bar")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
            }

            Spacer(minLength: 4)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(primary.opacity(0.14))
                    .frame(width: 48, height: 4)
                Capsule()
                    .fill(tireTint(bar))
                    .frame(width: max(4, 48 * tireRatio(bar)), height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
    }

    private func tireRatio(_ bar: Double) -> CGFloat {
        CGFloat(min(1, max(0.06, bar / 3.2)))
    }

    private func tireTint(_ bar: Double) -> Color {
        if bar < 1.8 { return Theme.red }
        if bar < 2.1 || bar > 2.9 { return Theme.orange }
        return Theme.green
    }
}

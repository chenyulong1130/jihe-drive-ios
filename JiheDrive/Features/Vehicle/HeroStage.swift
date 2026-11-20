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
    /// 胎压监测二级页
    var onOpenTire: (() -> Void)? = nil

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
                // 中间空白让触摸落到下方 3D 层，可拖拽旋转
                Spacer(minLength: hasTire ? 16 : 4)
                    .allowsHitTesting(false)
                tireStrip
            }
            .padding(.horizontal, 18)
            .padding(.top, topInset)
            .padding(.bottom, 18)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background {
            // 主题只淡出自身下沿，不把灰雾叠到车图上
            backdrop
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.78),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
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

                GeometryReader { geo in
                    LoopingVideoView(url: url, muted: true)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .clipped()
                .allowsHitTesting(false)
            }
            .clipped()
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

    /// 只压顶部保证车名可读；中间和车图区域不再铺黑雾
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0x080E18).opacity(0.42), location: 0),
                .init(color: Color.clear, location: 0.28)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    // MARK: - 车 / 3D

    /// 车图顶距：躲开顶栏 + 电量
    private var carTopPad: CGFloat { topInset + 96 }
    /// 有胎压时把车图抬高，避免压在读数上
    private var hasTire: Bool { validBar(frontBar) != nil || validBar(rearBar) != nil }
    private var carBottomPad: CGFloat { hasTire ? 86 : 18 }

    @ViewBuilder
    private var carLayer: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let modelGLBFile {
                    Color.clear
                        .overlay {
                            ModelViewerWebView(glbFile: modelGLBFile, interactive: true, autoRotate: false)
                        }
                        .padding(.top, carTopPad - 8)
                        .padding(.bottom, carBottomPad)
                } else if let modelScene {
                    VehicleSceneView(scene: modelScene, interactive: true, autoSpin: false, spinSpeed: 0)
                        .padding(.top, carTopPad - 8)
                        .padding(.bottom, carBottomPad)
                } else {
                    ZStack {
                        Ellipse()
                            .fill(Color.black.opacity(onDark ? 0.22 : 0.07))
                            .frame(width: 260, height: 14)
                            .blur(radius: 10)
                            .offset(y: 18)

                        Group {
                            if let url = vehicle.imageURL {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFit()
                                    } else {
                                        placeholder
                                    }
                                }
                                .id(vehicle.vinNo + (url.absoluteString))
                            } else {
                                placeholder
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity)
                        .shadow(color: Color.black.opacity(onDark ? 0.28 : 0.10), radius: 16, x: 0, y: 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, carTopPad - 8)
                    .padding(.bottom, carBottomPad)
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
            .padding(.top, carTopPad - 8)
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

    // MARK: - 电量（对齐小程序：电量% + 续航挤在左侧，短进度条 140×6）

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(soc)")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
                    .padding(.trailing, 9)

                Text("\(vehicle.rangeKm)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("km")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(primary.opacity(0.18))
                    .frame(width: 140, height: 6)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [socColor, socColor.opacity(0.75)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(5, 140 * socRatio), height: 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle()
                    .fill(vehicle.isOnline ? Theme.green : secondaryText.opacity(0.55))
                    .frame(width: 6, height: 6)
                Text(vehicle.isOnline ? "在线" : "离线")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(vehicle.isOnline ? Theme.green : secondaryText)
            }

            signalBars

            HStack(spacing: 4) {
                Image(systemName: vehicle.isCharging
                      ? "bolt.fill"
                      : (vehicle.isLocked ? "lock.fill" : "lock.open.fill"))
                    .font(.system(size: 11, weight: .semibold))
                Text(vehicle.isCharging ? "充电中" : (vehicle.isLocked ? "已关锁" : "未关锁"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(
                vehicle.isCharging
                    ? Theme.green
                    : (vehicle.isLocked ? primary.opacity(0.92) : Color(hex: 0xFF9F0A))
            )

            Spacer(minLength: 0)
        }
    }

    /// 四格信号（对齐小程序 / Flutter），用 gsmRxLevel 0–5
    private var signalBars: some View {
        let level = min(5, max(0, vehicle.signalLevel))
        let active = onDark ? Color.white : Theme.brand
        let inactive = onDark ? Color.white.opacity(0.28) : Theme.tertiary.opacity(0.45)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < level ? active : inactive)
                    .frame(width: 3.5, height: CGFloat(5 + index * 3))
            }
        }
        .accessibilityLabel(vehicle.signalText ?? "信号 \(level)")
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
        let front = validBar(frontBar)
        let rear = validBar(rearBar)

        // 无雾蒙底、无进度条；有读数才显示，整块点进详情
        if front != nil || rear != nil {
            Button {
                onOpenTire?()
            } label: {
                HStack(spacing: 0) {
                    if let front {
                        tireCell(title: "前轮", bar: front)
                            .frame(maxWidth: .infinity)
                    }
                    if front != nil && rear != nil {
                        Rectangle()
                            .fill(primary.opacity(0.28))
                            .frame(width: 1, height: 36)
                    }
                    if let rear {
                        tireCell(title: "后轮", bar: rear)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
            .disabled(onOpenTire == nil)
        }
    }

    private var frontBar: Double? {
        tireFrontBar ?? vehicle.tireFrontKpa.map { $0 / 100 }
    }

    private var rearBar: Double? {
        tireRearBar ?? vehicle.tireRearKpa.map { $0 / 100 }
    }

    /// 0 / 异常值不当成有效胎压
    private func validBar(_ value: Double?) -> Double? {
        guard let value, value > 0.3, value < 6 else { return nil }
        return value
    }

    private func tireCell(title: String, bar: Double) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryText)
                .shadow(color: Color.black.opacity(onDark ? 0.55 : 0.18), radius: 2, y: 1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", bar))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(tireTint(bar))
                    .monospacedDigit()
                    .shadow(color: Color.black.opacity(onDark ? 0.65 : 0.22), radius: 3, y: 1)
                Text("bar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .shadow(color: Color.black.opacity(onDark ? 0.55 : 0.18), radius: 2, y: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func tireTint(_ bar: Double) -> Color {
        if bar < 1.8 { return Theme.red }
        if bar < 2.1 || bar > 2.9 { return Theme.orange }
        return Theme.green
    }
}

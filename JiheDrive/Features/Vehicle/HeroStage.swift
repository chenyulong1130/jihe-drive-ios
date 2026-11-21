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
    var tireFrontTemp: Double? = nil
    var tireRearTemp: Double? = nil
    var topInset: CGFloat = 12
    var height: CGFloat = 470
    let onPickVehicle: () -> Void
    /// 车机仪表壁纸（不是英雄区背景）
    let onOpenDashboardWallpaper: () -> Void
    /// 官方消息收件箱
    var onOpenMessages: (() -> Void)? = nil
    var unreadCount: Int = 0
    /// 车辆页动态主题（视频背景）
    let onOpenTheme: () -> Void
    let onOpenCushion: () -> Void
    /// 胎压监测二级页
    var onOpenTire: (() -> Void)? = nil
    /// 电量详情
    var onOpenBattery: (() -> Void)? = nil
    /// 拖 3D 时通知外层停掉页面滚动
    var onInteract: ((Bool) -> Void)? = nil
    /// 多车才显示左上角切换箭头
    var canSwitchVehicle: Bool = true

    @State private var glbRevealed = false

    private var onDark: Bool { !selection.isDefault || videoURL != nil }

    private var primary: Color { onDark ? .white : Theme.label }
    private var secondaryText: Color { onDark ? Color.white.opacity(0.78) : Theme.secondary }

    var body: some View {
        ZStack {
            backdrop
                .allowsHitTesting(false)
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.clear, Theme.groupedBackground.opacity(0.55), Theme.groupedBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: hasTire ? 88 : 36)
                    .allowsHitTesting(false)
                }

            carLayer

            VStack(spacing: 0) {
                topRow
                batteryBlock
                    .padding(.top, 10)
                statusRow
                    .padding(.top, 10)
                Spacer(minLength: hasTire ? 12 : 0)
                    .allowsHitTesting(false)
                tireStrip
            }
            .padding(.horizontal, 18)
            .padding(.top, topInset)
            .padding(.bottom, hasTire ? 10 : 4)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
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
                    Theme.groupedBackground
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
                            CachedRemoteImage(url: remote, contentMode: .fill)
                        }
                        .clipped()
                    } else {
                        Color(hex: 0x0B1A16)
                    }
                case .none:
                    Color(hex: 0x0B1A16)
                }

                CachedLoopingVideo(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    CachedRemoteImage(url: poster, contentMode: .fill)
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

    /// 车图顶距：躲开顶栏 + 电量，把车往下压，吃掉底部空白
    private var carTopPad: CGFloat { topInset + 96 }
    /// 有胎压时把车图抬高，避免压在读数上
    private var hasTire: Bool { validBar(frontBar) != nil || validBar(rearBar) != nil }
    /// 模型和胎压重叠一段，靠底部虚化过渡，不再硬切开
    private var carBottomPad: CGFloat { hasTire ? 22 : 0 }

    @ViewBuilder
    private var carLayer: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let modelGLBFile {
                    Color.clear
                        .overlay {
                            ZStack {
                                twoDCar
                                    .opacity(glbRevealed ? 0 : 1)
                                ModelViewerWebView(
                                    glbFile: modelGLBFile,
                                    interactive: true,
                                    autoRotate: false,
                                    onDrag: onInteract,
                                    onReady: { glbRevealed = true }
                                )
                                .opacity(glbRevealed ? 1 : 0)
                            }
                        }
                        .padding(.top, carTopPad)
                        .padding(.bottom, carBottomPad)
                        .mask(carFadeMask)
                        .simultaneousGesture(heroDrag)
                        .onChange(of: modelGLBFile) { _, _ in glbRevealed = false }
                } else if let modelScene {
                    ZStack {
                        twoDCar.opacity(0.001)
                        VehicleSceneView(
                            scene: modelScene,
                            interactive: true,
                            autoSpin: false,
                            spinSpeed: 0,
                            onDrag: onInteract
                        )
                    }
                    .padding(.top, carTopPad)
                    .padding(.bottom, carBottomPad)
                    .mask(carFadeMask)
                    .simultaneousGesture(heroDrag)
                } else {
                    twoDCar
                        .padding(.top, carTopPad)
                        .padding(.bottom, carBottomPad)
                        .mask(carFadeMask)
                        .allowsHitTesting(false)
                }
            }
            .offset(x: -16)

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
            .padding(.top, carTopPad)
            .padding(.trailing, 16)
            .accessibilityLabel("打开坐垫")
        }
    }

    private var twoDCar: some View {
        ZStack {
                Ellipse()
                    .fill(Color.black.opacity(onDark ? 0.22 : 0.07))
                    .frame(width: 240, height: 12)
                    .blur(radius: 6)
                .offset(y: 16)

            if vehicle.isCharging {
                ChargingGlow()
                    .offset(y: 18)
            }

            Group {
                if let url = vehicle.imageURL {
                    CachedRemoteImage(url: url, contentMode: .fit)
                        .id(vehicle.vinNo + url.absoluteString)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 6)
            .shadow(color: Color.black.opacity(onDark ? 0.28 : 0.10), radius: 16, x: 0, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
                    if canSwitchVehicle {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(secondaryText)
                    }
                }
                .frame(minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
            .disabled(!canSwitchVehicle)

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
                if let onOpenMessages {
                    frostedCircle(action: onOpenMessages, label: "消息", badge: unreadCount) {
                        Image(systemName: unreadCount > 0 ? "bell.badge.fill" : "bell.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                    }
                }
            }
        }
    }

    private func frostedCircle<Content: View>(
        action: @escaping () -> Void,
        label: String,
        badge: Int = 0,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(0.82)))
                .shadow(color: Color.black.opacity(0.06), radius: 6, y: 1)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 9 ? "9+" : "\(badge)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.red))
                            .offset(x: 4, y: -4)
                    }
                }
                .contentShape(Circle())
                .accessibilityLabel(label)
        }
        .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
    }

    // MARK: - 电量（对齐小程序：电量% + 续航挤在左侧，短进度条 140×6）

    private var batteryBlock: some View {
        let energy = vehicle.isCharging ? Theme.green : primary
        let content = VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(soc)")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(energy)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(vehicle.isCharging ? Theme.green.opacity(0.85) : secondaryText)
                    .padding(.trailing, 9)

                Text("\(vehicle.rangeKm)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("km")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(secondaryText)
            }

            ChargingBar(
                progress: socRatio,
                charging: vehicle.isCharging,
                track: primary.opacity(0.18),
                fill: socColor
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel("电池详情")

        return Group {
            if let onOpenBattery {
                Button(action: onOpenBattery) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            signalBars

            if vehicle.isCharging {
                ChargingChip()
            }

            HStack(spacing: 4) {
                Image(systemName: vehicle.isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(vehicle.isLocked ? "已关锁" : "未关锁")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(vehicle.isLocked ? primary.opacity(0.92) : Color(hex: 0xFF9F0A))

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

    /// 车身底部虚化，和胎压条叠在一起
    private var carFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: hasTire ? 0.72 : 0.92),
                .init(color: .black.opacity(0.35), location: hasTire ? 0.88 : 0.97),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private var tireStrip: some View {
        let front = validBar(frontBar)
        let rear = validBar(rearBar)

        // 无数据整条不展示；有一侧读数时另一侧显示「未绑定」
        if front != nil || rear != nil {
            Button {
                onOpenTire?()
            } label: {
                HStack(spacing: 0) {
                    if let front {
                        tireCell(title: "前轮", bar: front, temp: tireFrontTemp)
                    } else {
                        tireUnbound(title: "前轮")
                    }
                    if let rear {
                        tireCell(title: "后轮", bar: rear, temp: tireRearTemp)
                    } else {
                        tireUnbound(title: "后轮")
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.72)
                }
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

    private func tireCell(title: String, bar: Double, temp: Double?) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(secondaryText)
                .shadow(color: Color.black.opacity(onDark ? 0.55 : 0.18), radius: 2, y: 1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", bar))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(tireTint(bar))
                    .monospacedDigit()
                    .shadow(color: Color.black.opacity(onDark ? 0.65 : 0.22), radius: 3, y: 1)
                Text("bar")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .shadow(color: Color.black.opacity(onDark ? 0.55 : 0.18), radius: 2, y: 1)
                if let temp, temp > -40, temp < 120 {
                    Text(String(format: "%.0f°", temp))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(secondaryText)
                        .monospacedDigit()
                        .shadow(color: Color.black.opacity(onDark ? 0.55 : 0.18), radius: 2, y: 1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func tireUnbound(title: String) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(secondaryText)
                .shadow(color: Color.black.opacity(onDark ? 0.55 : 0.18), radius: 2, y: 1)
            Text("未绑定")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(secondaryText.opacity(0.9))
                .shadow(color: Color.black.opacity(onDark ? 0.55 : 0.18), radius: 2, y: 1)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private func tireTint(_ bar: Double) -> Color {
        if bar < 1.8 { return Theme.red }
        if bar < 2.1 || bar > 2.9 { return Theme.orange }
        return Theme.green
    }

    private var heroDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { _ in onInteract?(true) }
            .onEnded { _ in onInteract?(false) }
    }
}

/// 车底充电光晕
private struct ChargingGlow: View {
    @State private var pulse = false

    var body: some View {
        Ellipse()
            .fill(Theme.green.opacity(pulse ? 0.38 : 0.14))
            .frame(width: 268, height: 22)
            .blur(radius: 8)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// 状态行「充电中」小标
private struct ChargingChip: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .scaleEffect(pulse ? 1.15 : 0.9)
            Text("充电中")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.green)
        .shadow(color: Theme.green.opacity(pulse ? 0.55 : 0.15), radius: 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

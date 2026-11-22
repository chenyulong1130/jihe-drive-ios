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

    /// 视频 / 壁纸主题需要和下方页面做渐隐，默认灰底不用
    var blendsIntoPage: Bool { !isDefault }
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
    /// 这份 GLB 已经展示过，切回来不要再闪 2D
    var modelGLBCached: Bool = false
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
    /// 递增后 3D 回到初始角度并重新显示胎压标注
    var cameraReset: Int = 0

    @State private var glbRevealed = false
    @State private var modelRotated = false
    @State private var localReset = 0
    private var glbVisible: Bool { glbRevealed || modelGLBCached }

    private var onDark: Bool { !selection.isDefault || videoURL != nil }

    private var primary: Color { onDark ? .white : Theme.label }
    private var secondaryText: Color { onDark ? Color.white.opacity(0.78) : Theme.secondary }

    /// 主题底边伸进内容区的渐隐高度
    static let pageBlend: CGFloat = 80

    var body: some View {
        let tail = selection.blendsIntoPage ? Self.pageBlend : 0
        return ZStack(alignment: .top) {
            backdrop
                .frame(height: height + tail)
                .mask(alignment: .top) { backdropMask(total: height + tail) }
                .allowsHitTesting(false)

            bottomWash(tail: tail)
                .frame(height: height + tail, alignment: .bottom)
                .allowsHitTesting(false)

            carLayer
                .frame(height: height)
                .clipped()

            VStack(spacing: 0) {
                topRow
                batteryBlock
                    .padding(.top, 10)
                statusRow
                    .padding(.top, 10)
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                tireBar
                    .padding(.bottom, selection.blendsIntoPage ? 6 : 2)
            }
            .padding(.horizontal, 18)
            .padding(.top, topInset)
            .background(Color.clear)
            .frame(height: height)
            .clipped()
            .allowsHitTesting(true)
        }
        .frame(height: height + tail, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func resetCamera() {
        localReset += 1
        if modelGLBFile == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.68) {
                modelRotated = false
            }
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

    private func backdropMask(total: CGFloat) -> some View {
        let fadeStart = total > 1 ? min(0.94, max(0.62, height / total)) : 1
        return LinearGradient(
            stops: selection.blendsIntoPage
                ? [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: fadeStart),
                    .init(color: Color.black.opacity(0.4), location: min(1, fadeStart + 0.2)),
                    .init(color: .clear, location: 1)
                ]
                : [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 1)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private func bottomWash(tail: CGFloat) -> some View {
        if tail > 0 {
            LinearGradient(
                stops: [
                    .init(color: Theme.groupedBackground.opacity(0), location: 0),
                    .init(color: Theme.groupedBackground.opacity(0.28), location: 0.45),
                    .init(color: Theme.groupedBackground.opacity(0.72), location: 0.78),
                    .init(color: Theme.groupedBackground.opacity(0.92), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: tail + 36)
            .allowsHitTesting(false)
        }
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

                CachedLoopingVideo(url: url, fadeBottom: selection.blendsIntoPage)
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

    /// 2D 贴底，少留空；3D 铺满英雄区（顶栏透明叠上去）
    private var carTopPad: CGFloat { topInset + 58 }
    private var hasTire: Bool { validBar(frontBar) != nil || validBar(rearBar) != nil }
    private var has3D: Bool { modelGLBFile != nil || modelScene != nil }
    private var showTireMarks: Bool { hasTire && (!has3D || !modelRotated) }

    @ViewBuilder
    private var carLayer: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let modelGLBFile {
                    Color.clear
                        .overlay {
                            ZStack {
                                twoDCar
                                    .opacity(glbVisible ? 0 : 1)
                                ModelViewerWebView(
                                    glbFile: modelGLBFile,
                                    reuseKey: "hero-\(vehicle.vinNo)-flat1",
                                    interactive: true,
                                    autoRotate: false,
                                    resetToken: cameraReset + localReset,
                                    onDrag: { dragging in
                                        if dragging { modelRotated = true }
                                        onInteract?(dragging)
                                    },
                                    onOrbitChanged: { rotated in
                                        modelRotated = rotated
                                    },
                                    onReady: { glbRevealed = true }
                                )
                                .opacity(glbVisible ? 1 : 0)
                            }
                        }
                        .simultaneousGesture(heroDrag)
                        .onTapGesture(count: 2) { resetCamera() }
                        .onAppear { if modelGLBCached { glbRevealed = true } }
                        .onChange(of: modelGLBFile) { _, _ in
                            glbRevealed = modelGLBCached
                        }
                } else if let modelScene {
                    ZStack {
                        twoDCar.opacity(0.001)
                        VehicleSceneView(
                            scene: modelScene,
                            interactive: true,
                            autoSpin: false,
                            spinSpeed: 0,
                            resetToken: cameraReset + localReset,
                            onDrag: { dragging in
                                if dragging { modelRotated = true }
                                onInteract?(dragging)
                            }
                        )
                    }
                    .simultaneousGesture(heroDrag)
                    .onTapGesture(count: 2) { resetCamera() }
                } else {
                    twoDCar
                        .padding(.top, carTopPad)
                        .padding(.horizontal, 0)
                        .padding(.bottom, showTireMarks ? 8 : 4)
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
                            .fill(Color.white.opacity(0.55))
                    )
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
            .padding(.top, topInset + 108)
            .padding(.trailing, 16)
            .accessibilityLabel("打开坐垫")
        }
    }

    private var twoDCar: some View {
        Color.clear
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    Ellipse()
                        .fill(Color.black.opacity(onDark ? 0.22 : 0.07))
                        .frame(width: 260, height: 14)
                        .blur(radius: 6)
                        .offset(y: 6)
                    if let url = vehicle.imageURL {
                        BottomFitVehicleImage(url: url)
                            .id(vehicle.vinNo + url.absoluteString)
                    } else {
                        placeholder
                    }
                }
                .padding(.horizontal, 2)
                .shadow(color: Color.black.opacity(onDark ? 0.28 : 0.10), radius: 16, x: 0, y: 10)
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
                        .fixedSize(horizontal: false, vertical: true)
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
                .background(Circle().fill(Color.white.opacity(0.55)))
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
                    .shadow(color: Color.white.opacity(0.7), radius: 8)
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
                Text(vehicle.isLocked ? "已关机" : "已开机")
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

    @ViewBuilder
    private var tireBar: some View {
        if showTireMarks {
            Button {
                onOpenTire?()
            } label: {
                HStack(spacing: 0) {
                    tireColumn(title: "前轮", bar: validBar(frontBar), temp: tireFrontTemp)
                    tireColumn(title: "后轮", bar: validBar(rearBar), temp: tireRearTemp)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(onOpenTire == nil)
        }
    }

    private func tireColumn(title: String, bar: Double?, temp: Double?) -> some View {
        let tint = tireTint(bar)
        return VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(bar.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text("bar")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint.opacity(0.9))
                if let temp, temp > -40, temp < 120 {
                    Text(String(format: "%.0f°", temp))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(tint.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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

    private func tireTint(_ bar: Double?) -> Color {
        guard let bar else { return onDark ? Color.white.opacity(0.55) : Theme.tertiary }
        if bar < 1.8 { return Theme.red }
        if bar < 2.1 || bar > 2.9 { return Theme.orange }
        return Color(hex: 0xE08A2C)
    }

    private var heroDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { _ in onInteract?(true) }
            .onEnded { _ in onInteract?(false) }
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

/// 车图贴底等比缩放，避免 fit 在高框里上下居中留白
private struct BottomFitVehicleImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: url.absoluteString) {
            image = ResourceCache.cachedImage(url)
            if image == nil {
                image = await ResourceCache.image(for: url)
            }
        }
    }
}

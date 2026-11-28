import SwiftUI
import UIKit

/// 速牛灯具调试页（仅通用 RGB 调试）：
/// 产品卡（目录识别出的产品名 + 通道 + 断开）→ 颜色调节（HSV 色轮 + 预设）
/// → 亮度/速度（0–255）→ 模式库（按产品目录，每产品独立数据，点按即下发）
/// → 底部命令状态条。通用控制走 80/81/82/85 命令映射。
struct LampDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: LampStore
    @State private var showDiagnostics = false
    @State private var brightness: Double = 0.5
    @State private var speed: Double = 0.5
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var appliedModeId: String?
    @State private var toast: String?
    @State private var copyToast = false
    /// 发送合并标记：拖动期间只排一拍，到点发最新值（不反复取消/新建 Task，避免 UI 抖动）
    @State private var colorSendScheduled = false
    @State private var levelSendScheduled = false
    /// 正在拖动的控件：设备回显不回拉本地滑块，避免打架
    @State private var colorDragging = false
    @State private var brightnessDragging = false
    @State private var speedDragging = false

    private enum LevelKind { case brightness, speed }

    private var connected: Bool { ble.isConnected(.lamp) }

    private var currentColor: Color {
        Color(hue: hue / 360, saturation: saturation, brightness: 1)
    }

    private var rgb: (r: Int, g: Int, b: Int) {
        let ui = UIColor(currentColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private var hexText: String {
        let c = rgb
        return String(format: "%02X%02X%02X", c.r, c.g, c.b)
    }

    /// 预设色板（hue, sat），HSV 色轮用
    private let presets: [(color: Color, hue: Double, sat: Double)] = [
        (Color(red: 1, green: 0, blue: 0), 0, 1),
        (Color(red: 1, green: 0.28, blue: 0), 16, 1),
        (Color(red: 1, green: 0.77, blue: 0), 46, 1),
        (Color(red: 0, green: 1, blue: 0.38), 140, 1),
        (Color(red: 0, green: 0.88, blue: 1), 187, 1),
        (Color(red: 0, green: 0.38, blue: 1), 217, 1),
        (Color(red: 0.66, green: 0.25, blue: 1), 276, 1),
        (Color(red: 1, green: 0.25, blue: 0.63), 324, 1),
        (Color(red: 1, green: 1, blue: 1), 0, 0),
    ]

    var body: some View {
        withEchoSync(
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    productCard
                    colorCard
                    levelSliderCard(icon: "sun.max.fill", title: "灯光亮度", value: $brightness,
                                    caption: "0–255；设备回报值会自动同步到滑块", kind: .brightness)
                    levelSliderCard(icon: "forward.end.fill", title: "模式速度", value: $speed,
                                    caption: "0–255；设备回报值会自动同步到滑块", kind: .speed)
                    modeCard
                    commandStatusBar
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("速牛灯具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .accessibilityLabel("诊断")
                }
            }
            .onAppear {
                store.attach(ble)
            }
            .onDisappear {
                store.deactivate()
            }
            .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(text: toast)
                        .padding(.bottom, 28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.quick, value: toast)
        )
    }

    /// 设备回显：灯具回报的状态自动同步到滑块 / 色轮（拆出 body，降低表达式复杂度）
    private func withEchoSync(_ view: some View) -> some View {
        view
            .onChange(of: store.deviceBrightness) { _, value in
                guard let value, !brightnessDragging else { return }
                brightness = Double(value) / 255.0
            }
            .onChange(of: store.deviceSpeed) { _, value in
                guard let value, !speedDragging else { return }
                speed = Double(value) / 255.0
            }
            .onChange(of: store.deviceColor) { _, color in
                syncDeviceColorEcho(color)
            }
    }

    /// 灯具回报 RGB → 同步色轮（拆成独立方法避免 onChange 链类型检查超时）
    private func syncDeviceColorEcho(_ color: LampRGBState?) {
        guard let color, !colorDragging else { return }
        let ui = UIColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                         blue: CGFloat(color.b) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h * 360)
        saturation = Double(s)
    }

    private func showToast(_ text: String) {
        withAnimation(Motion.quick) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(Motion.quick) { toast = nil }
        }
    }

    // MARK: - 产品卡（产品 + 通道 + 状态 + 断开；无大标题行）

    /// 产品卡：目录识别出的产品名（未命中显示通用 RGB）+ 通道 + 断开
    private var productCard: some View {
        AppleCard(padding: 12) {
            HStack(spacing: 12) {
                CircleIconBadge(icon: "paintpalette.fill", color: Theme.brand, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.catalogProductName ?? "通用 RGB 灯具")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(store.transport?.title ?? "未识别通道")
                        if store.catalogProductName != nil {
                            Text("· 已识别")
                                .foregroundStyle(Theme.green)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                StatusPill(
                    text: connected ? "已连接" : "未连接",
                    color: connected ? Theme.green : Theme.secondary,
                    pulsing: connected
                )
                Button {
                    ble.disconnect(.lamp)
                } label: {
                    Text("断开")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.red)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                .disabled(!connected)
            }
        }
    }

    // MARK: - 颜色调节（紧凑色轮 + 实时色块）

    private var colorCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionHeader("颜色调节", icon: "paintpalette.fill", color: Theme.brand)
                    Spacer()
                    Text("#\(hexText)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                // 左色轮右色块：色轮不再撑满整卡
                HStack(alignment: .center, spacing: 16) {
                    hsvWheel
                        .frame(width: 168, height: 168)

                    VStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(currentColor)
                            .frame(width: 84, height: 84)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white, lineWidth: 3)
                            )
                            .shadow(color: currentColor.opacity(0.5), radius: 10)
                        Text(saturation < 0.06 ? "白色" : "R\(rgb.r) G\(rgb.g) B\(rgb.b)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }

                // 预设色板
                HStack(spacing: 0) {
                    ForEach(presets.indices, id: \.self) { index in
                        let preset = presets[index]
                        let selected = abs(hue - preset.hue) < 2 && abs(saturation - preset.sat) < 0.03
                        Circle()
                            .fill(preset.color)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(selected ? Theme.label : .white, lineWidth: selected ? 3 : 2))
                            .shadow(color: preset.color.opacity(selected ? 0.55 : 0.25), radius: selected ? 9 : 4)
                            .frame(maxWidth: .infinity)
                            .onTapGesture {
                                hue = preset.hue
                                saturation = preset.sat
                                scheduleColorSend()
                            }
                    }
                }
            }
        }
    }

    /// HSV 色轮：锥形渐变（色相）+ 径向白化（饱和度），拖动取色
    private var hsvWheel: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = size / 2
            let radius = center - 6
            let angleRad = hue * .pi / 180
            let dotR = saturation * (radius - 4)
            ZStack {
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [0, 60, 120, 180, 240, 300, 360].map {
                                Color(hue: $0 / 360, saturation: 1, brightness: 1)
                            },
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360)
                        )
                    )
                    .frame(width: size - 12, height: size - 12)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, .white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                    .frame(width: size - 12, height: size - 12)
                Circle()
                    .strokeBorder(.black.opacity(0.2), lineWidth: 1)
                    .frame(width: size - 12, height: size - 12)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.3), radius: 4)
                    .overlay(Circle().fill(currentColor).frame(width: 13, height: 13))
                    .position(x: center + cos(angleRad) * dotR, y: center + sin(angleRad) * dotR)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - center
                        let dy = value.location.y - center
                        let distance = sqrt(dx * dx + dy * dy)
                        guard distance <= radius else { return }
                        var newHue = atan2(dy, dx) * 180 / .pi
                        if newHue < 0 { newHue += 360 }
                        hue = newHue
                        saturation = min(1, distance / radius)
                        colorDragging = true
                        scheduleColorSend()
                    }
                    .onEnded { _ in colorDragging = false }
            )
        }
    }

    // MARK: - 亮度 / 速度滑条卡

    /// 亮度/速度滑条：标题 + 设备回报徽标一行，滑条通栏好拖；
    /// 松手即下发（拖动期间 300ms 节流合并），不再挤在半行里难操作
    private func levelSliderCard(icon: String, title: String, value: Binding<Double>,
                                 caption: String, kind: LevelKind) -> some View {
        let deviceValue: Int?
        if kind == .brightness {
            deviceValue = store.deviceBrightness
        } else {
            deviceValue = store.deviceSpeed
        }
        return AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 8)
                    if let deviceValue {
                        Text("设备 \(deviceValue)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.green.opacity(0.10), in: Capsule())
                    }
                    Button {
                        showToast(caption)
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(caption)

                    Text("\(Int(value.wrappedValue * 255))")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                Slider(value: value, in: 0...1) { editing in
                    switch kind {
                    case .brightness: brightnessDragging = editing
                    case .speed: speedDragging = editing
                    }
                    if !editing { scheduleLevelSend(kind, immediate: true) }
                }
                .tint(Theme.brand)
                .disabled(!connected)
                .onChange(of: value.wrappedValue) { _, _ in
                    guard kind == .brightness ? brightnessDragging : speedDragging else { return }
                    scheduleLevelSend(kind)
                }

                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    // MARK: - 模式库（按产品目录，每产品独立数据，速调试同款离线库）

    /// 分组列表：保持库内原序，组内模式原序
    private var libraryGroups: [(id: String, title: String, modes: [LampLibraryMode])] {
        var order: [String] = []
        var buckets: [String: [LampLibraryMode]] = [:]
        for mode in store.libraryModes {
            if buckets[mode.groupName] == nil { order.append(mode.groupName) }
            buckets[mode.groupName, default: []].append(mode)
        }
        return order.map { key in
            let title = store.libraryModes.first { $0.groupName == key }?.groupTitle ?? key
            return (key, title, buckets[key] ?? [])
        }
    }

    private var modeCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    sectionHeader("模式库", icon: "square.grid.2x2.fill", color: Theme.brand)
                    Spacer()
                    if !store.libraryModes.isEmpty {
                        Text("\(store.libraryModes.count) 个")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.brand)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surfaceAlt, in: Capsule())
                    }
                }

                if let product = store.catalogProductName {
                    Text("产品「\(product)」的专属模式，点按即下发。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }

                if store.libraryModes.isEmpty {
                    Text(store.catalogProductName == nil
                         ? "未匹配到产品目录，暂无该产品的模式数据。"
                         : "产品目录中暂未收录该产品的模式。")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ForEach(libraryGroups, id: \.id) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(group.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Theme.label)
                                Text("\(group.modes.count) 个")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.tertiary)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                                ForEach(group.modes) { mode in
                                    libraryModeTile(mode)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 模式格：名称 + 编号，点按即下发；设备回报的当前模式号也会高亮
    private func libraryModeTile(_ mode: LampLibraryMode) -> some View {
        let selected = appliedModeId == mode.id
            || (store.deviceMode != nil && mode.number == store.deviceMode)
        return Button {
            appliedModeId = mode.id
            Task {
                await store.applyLibraryMode(mode)
                showToast(store.lastError.isEmpty
                          ? "已下发「\(mode.displayName)」"
                          : "下发失败：\(store.lastError)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.brand : Theme.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text("编号 \(mode.no)")
                    Text(mode.groupTitle)
                        .font(.system(size: 10, weight: .semibold, design: .default))
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? Theme.brand : Theme.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.brand.opacity(0.10) : Theme.surfaceAlt,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.brand.opacity(0.55) : Theme.separator.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.95, brightness: 0))
        .disabled(!connected)
    }

    // MARK: - 底部命令状态条

    private var commandStatusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: store.lastError.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(store.lastError.isEmpty ? Theme.green : Theme.red)
            Text(store.lastError.isEmpty
                 ? (connected ? "设备已就绪，可以开始调试" : "未连接设备")
                 : store.lastError)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.lastError.isEmpty ? Theme.secondary : Theme.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: - 发送合并（拖动期间 250-300ms 一拍，到点发最新值）

    /// 颜色：拖动色轮/预设期间 250ms 一拍
    private func scheduleColorSend() {
        guard !colorSendScheduled else { return }
        colorSendScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            colorSendScheduled = false
            guard connected else { return }
            let c = rgb
            await store.setColor(red: c.r, green: c.g, blue: c.b)
        }
    }

    /// 亮度/速度：拖动期间 300ms 一拍；松手立即发最终值
    private func scheduleLevelSend(_ kind: LevelKind, immediate: Bool = false) {
        guard connected else { return }
        if immediate {
            levelSendScheduled = false
            switch kind {
            case .brightness:
                Task { await store.setGeneric(LampProtocol.GenericCommand.brightness, value: Int(brightness * 255)) }
            case .speed:
                Task { await store.setGeneric(LampProtocol.GenericCommand.modeSpeed, value: Int(speed * 255)) }
            }
            return
        }
        guard !levelSendScheduled else { return }
        levelSendScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            levelSendScheduled = false
            guard connected else { return }
            switch kind {
            case .brightness:
                await store.setGeneric(LampProtocol.GenericCommand.brightness, value: Int(brightness * 255))
            case .speed:
                await store.setGeneric(LampProtocol.GenericCommand.modeSpeed, value: Int(speed * 255))
            }
        }
    }

    // MARK: - 诊断弹窗

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            ConnectionBannerTile(
                                connected: connected,
                                deviceName: ble.connectedDevice(for: .lamp)?.displayName ?? ""
                            )
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                StatusTile(icon: "cable.connector", title: "通道", value: store.transport?.title ?? "未识别")
                                StatusTile(icon: "paintpalette.fill", title: "产品",
                                           value: store.catalogProductName ?? "未匹配目录")
                                StatusTile(icon: "square.grid.2x2.fill", title: "模式库",
                                           value: "\(store.libraryModes.count) 个")
                                StatusTile(icon: "number", title: "调试协议", value: "通用 RGB")
                            }
                        }
                    }

                    LogPanel(title: "通信日志", logs: store.logs)

                    Button {
                        UIPasteboard.general.string = store.logs.joined(separator: "\n")
                        copyToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copyToast = false }
                    } label: {
                        Label("复制通信日志", systemImage: "doc.on.doc")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .foregroundStyle(Theme.brand)
                            .background(Theme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showDiagnostics = false } }
            }
            .overlay(alignment: .bottom) {
                if copyToast {
                    Text("已复制到剪贴板")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Theme.label.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: copyToast)
        }
    }

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.label)
        }
    }
}

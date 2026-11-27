import SwiftUI
import UIKit

/// 速牛灯具调试页（对齐「速调试」原版调试页结构）：
/// 产品卡（图标 + 名称 + 断开）→ 调试类型下拉（速牛·灯光角度 / AE7 恶魔眼 / M5 大灯 /
/// FX 大灯 / 通用 RGB 灯具）→ 设备参数（读取 + 状态行）→ 按类型出原版控件
/// （角度卡带 −/+ 与便捷/扩展预设；M5 远光→近光色温→恶魔眼；FX 日行开关；RGB 颜色+亮度+速度）
/// → 灯效模式 → 底部命令状态条。通用控制走 80/81/82/85 命令映射；专用参数走 1F/20 快照。
struct LampDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: LampStore
    @State private var showDiagnostics = false
    @State private var angleValue: Double = 0
    @State private var temperatureValue: Double = 50
    @State private var brightness: Double = 0.5
    @State private var speed: Double = 0.5
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var mode: Int = 1
    @State private var channel: LampChannel = .driving
    @State private var highWhite = false
    @State private var highYellow = false
    @State private var daytimeOn = false
    @State private var rgbOn = false
    @State private var snapshotHex = "FFFFFF"
    @State private var copyToast = false
    /// 发送节流：拖动色轮/滑条时合并下发，避免命令积压
    @State private var colorSendTask: Task<Void, Never>?
    @State private var levelSendTask: Task<Void, Never>?
    @State private var temperatureSendTask: Task<Void, Never>?
    @State private var angleSendTask: Task<Void, Never>?

    private var connected: Bool { ble.isConnected }
    /// 原版 canWrite 语义：已连接且（已同步或通用 RGB）
    private var canWrite: Bool { connected && (store.synced || store.profile == .rgb) }
    private var needsSnapshot: Bool { store.profile == .m5 || store.profile == .ae7 }

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

    /// 原版 8 色快板（白红橙黄绿蓝紫青，速调试同款色值）
    private let quickColors: [(name: String, hex: String)] = [
        ("白", "FFFFFF"), ("红", "FF0000"), ("橙", "FF7A00"), ("黄", "FFD400"),
        ("绿", "00D26A"), ("蓝", "0066FF"), ("紫", "8A2BE2"), ("青", "00E5FF"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                productCard
                debugTypeRow
                parameterSection
                if !store.synced && store.profile != .rgb { waitForParamsCard }
                controls
                modeCard
                commandStatusBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("灯具")
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
            angleValue = Double(store.angle)
            syncFromSnapshot()
        }
        .onDisappear {
            store.deactivate()
        }
        .onChange(of: store.synced) { _, _ in syncFromSnapshot() }
        .onChange(of: store.profile) { _, _ in syncFromSnapshot() }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
    }

    // MARK: - Header / 产品卡

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(ble.connectedDevice?.displayName ?? "灯具")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            StatusPill(
                text: connected ? "已连接" : "未连接",
                color: connected ? Theme.green : Theme.secondary,
                pulsing: connected
            )
        }
    }

    /// 产品卡：类型图标 + 名称 + 传输通道 + 断开（对齐原版 product-card）
    private var productCard: some View {
        AppleCard(padding: 12) {
            HStack(spacing: 12) {
                CircleIconBadge(icon: productIcon, color: Theme.brand, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profileName(store.profile))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(store.transport?.title ?? "未识别通道")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    ble.disconnect()
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

    private var productIcon: String {
        switch store.profile {
        case .angle: return "arrow.up.to.line"
        case .ae7: return "eye.fill"
        case .m5, .fx: return "lightbulb.fill"
        case .rgb: return "paintpalette.fill"
        }
    }

    // MARK: - 调试类型（下拉，对齐原版 profile select）

    private func profileName(_ profile: LampState.Profile) -> String {
        switch profile {
        case .angle: return "速牛 · 灯光角度"
        case .ae7: return "速牛 · AE7 恶魔眼"
        case .m5: return "速牛 · M5 大灯"
        case .fx: return "速牛 · FX 大灯"
        case .rgb: return "通用 RGB 灯具"
        }
    }

    private var profileHelper: String {
        store.profile == .rgb
            ? "通用 RGB 控件需与实际产品能力一致；专用大灯请选择对应型号"
            : "按实际产品选择调试类型；先读取实际参数，其他配置字节将原样保留"
    }

    private var debugTypeRow: some View {
        AppleCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("调试类型")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 8)
                    Menu {
                        ForEach(LampState.Profile.allCases) { profile in
                            Button {
                                store.selectProfile(profile)
                            } label: {
                                if store.profile == profile {
                                    Label(profileName(profile), systemImage: "checkmark")
                                } else {
                                    Text(profileName(profile))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(profileName(store.profile))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.brand)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceAlt, in: Capsule())
                    }
                }
                Text(profileHelper)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 设备参数（读取 + 状态行，对齐原版参数区）

    private var parameterStatusText: String {
        store.profile == .rgb
            ? "通用协议：参数写入后请观察设备状态"
            : (store.synced ? "已读取设备参数" : "请先读取设备参数")
    }

    private var parameterSection: some View {
        AppleCard(padding: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设备参数")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Text(parameterStatusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(store.synced || store.profile == .rgb ? Theme.green : Theme.orange)
                }
                Spacer()
                if store.profile != .rgb {
                    Button {
                        Task { await store.readParams() }
                    } label: {
                        Label("读取参数", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                    .disabled(!connected)
                }
            }
        }
    }

    /// 等待参数提示（对齐原版「等待设备参数」面板）
    private var waitForParamsCard: some View {
        AppleCard(padding: 12) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                Text("先读取设备实际参数，再调节下方控件；未读取前不会发送设置指令。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 控件路由（按调试类型，对齐原版 renderControls）

    @ViewBuilder
    private var controls: some View {
        switch store.profile {
        case .angle:
            angleControls
            if store.synced { anglePresetColumns }
        case .m5:
            highBeamCard
            temperatureCard
            demonEyeCard
        case .ae7:
            temperatureCard
            demonEyeCard
        case .fx:
            temperatureCard
            daytimeCard
        case .rgb:
            colorCard
            levelSliderCard(title: "亮度调节", value: $brightness,
                            caption: "写入值，不代表设备当前亮度", icon: "sun.max.fill") {
                debouncedSendLevel()
            }
            levelSliderCard(title: "速度调节", value: $speed,
                            caption: "写入值，不代表设备当前速度", icon: "forward.end.fill") {
                debouncedSendLevel()
            }
        }
    }

    // MARK: - 角度（对齐原版灯光角度卡 + 便捷/扩展预设）

    private var angleControls: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("灯光角度", icon: "arrow.up.to.line", color: Theme.orange)
                HStack {
                    Text("当前角度 \(formattedAngle(store.angle))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text("可调角度 \(store.minAngle)° ~ \(store.maxAngle)°")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                HStack(spacing: 14) {
                    Button {
                        let next = max(store.minAngle, Int(angleValue) - store.step)
                        angleValue = Double(next)
                        sendAngle(next)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.orange)
                            .frame(width: 44, height: 40)
                            .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                    .disabled(!canWrite)

                    Text(store.synced ? formattedAngle(Int(angleValue)) : "—")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                        .frame(minWidth: 76)

                    Button {
                        let next = min(store.maxAngle, Int(angleValue) + store.step)
                        angleValue = Double(next)
                        sendAngle(next)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.orange)
                            .frame(width: 44, height: 40)
                            .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                    .disabled(!canWrite)
                }
                .frame(maxWidth: .infinity)

                Slider(
                    value: $angleValue,
                    in: Double(store.minAngle)...Double(store.maxAngle),
                    step: Double(store.step)
                ) { EmptyView() } minimumValueLabel: {
                    Text("\(store.minAngle)°").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                } maximumValueLabel: {
                    Text("\(store.maxAngle)°").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                }
                .tint(Theme.orange)
                .disabled(!canWrite)
                .onChange(of: angleValue) { _, newValue in
                    sendAngleDebounced(Int(newValue))
                }

                Text(store.synced
                     ? "拖动或用 − / + 调整；读取参数后可看到范围与步进"
                     : "请先读取设备参数，再调整角度")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    /// 快照 4–8 字节推出的便捷预设（仰视/朝上/朝下/俯视，对齐原版逻辑）
    private var convenientPresets: [(label: String, value: Int, icon: String)] {
        guard let memory = store.angleMemoryValues else { return [] }
        let positive = memory.filter { $0 > 0 }.sorted(by: >)
        let negative = memory.filter { $0 < 0 }.sorted(by: >)
        let up1 = positive.first ?? store.maxAngle
        let up2 = positive.count > 1 ? positive[1] : (positive.first ?? store.maxAngle)
        let down1 = negative.first ?? store.minAngle
        let down2 = negative.count > 1 ? negative[1] : (negative.first ?? store.minAngle)
        return [("仰视", up1, "arrow.up.to.line"),
                ("朝上", up2, "arrow.up"),
                ("朝下", down1, "arrow.down"),
                ("俯视", down2, "arrow.down.to.line")]
    }

    private var anglePresetColumns: some View {
        HStack(alignment: .top, spacing: 8) {
            presetColumnCard("便捷操控", items: convenientPresets)
            presetColumnCard("扩展设置", items: extensionPresets)
        }
    }

    private var extensionPresets: [(label: String, value: Int, icon: String)] {
        var items: [(label: String, value: Int, icon: String)] = [("平视", 0, "arrow.left.and.right")]
        if let reset = store.angleResetValue {
            items.append(("复位", reset, "arrow.counterclockwise"))
        }
        return items
    }

    private func presetColumnCard(_ title: String,
                                  items: [(label: String, value: Int, icon: String)]) -> some View {
        AppleCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.label)
                let columns = items.count > 2 ? 2 : 1
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                    ForEach(items, id: \.label) { item in
                        Button {
                            sendAngle(item.value, reset: title == "扩展设置" && item.label == "复位")
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(store.angle == item.value ? Theme.orange : Theme.secondary)
                                Text(item.label)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(store.angle == item.value ? Theme.orange : Theme.label)
                                Text(formattedAngle(item.value))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.tertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                store.angle == item.value ? Theme.orange.opacity(0.12) : Theme.surfaceAlt,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                        .disabled(!canWrite)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func formattedAngle(_ value: Int) -> String {
        (value > 0 ? "+" : "") + "\(value)°"
    }

    private func sendAngle(_ value: Int, reset: Bool = false) {
        Task { await store.setAngle(value, reset: reset) }
    }

    private func sendAngleDebounced(_ value: Int) {
        guard store.synced else { return }
        angleSendTask?.cancel()
        angleSendTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await store.setAngle(value, reset: false)
        }
    }

    // MARK: - 远光（M5）

    private var highBeamCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("远光灯", icon: "sun.max.fill", color: Theme.red)
                switchRow("远光 · 白光", isOn: Binding(
                    get: { highWhite },
                    set: { highWhite = $0; Task { await store.change(kind: "highWhite", value: $0 ? 1 : 0) } }
                ), tint: Theme.red)
                switchRow("远光 · 黄光", isOn: Binding(
                    get: { highYellow },
                    set: { highYellow = $0; Task { await store.change(kind: "highYellow", value: $0 ? 1 : 0) } }
                ), tint: Color(hex: 0xF59E0B))
            }
        }
    }

    // MARK: - 近光色温（M5 / FX，对齐原版近光灯卡）

    private var temperatureCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("近光灯", icon: "thermometer.sun", color: Color(hex: 0xF59E0B))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 1, green: 0.72, blue: 0.23), Color(red: 0.97, green: 0.98, blue: 1.0)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(height: 14)
                        Circle()
                            .fill(.white)
                            .frame(width: 24, height: 24)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                            .offset(x: geo.size.width * temperatureValue / 100 - 12)
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            let ratio = value.location.x / max(CGFloat(1), geo.size.width)
                            temperatureValue = min(100, max(0, Double(ratio) * 100))
                            debouncedSendTemperature()
                        }
                    )
                }
                .frame(height: 26)
                .disabled(!canWrite)
                HStack {
                    Text("暖黄 0").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("配比 \(Int(temperatureValue))")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0xF59E0B))
                    Spacer()
                    Text("100 冷白").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 8) {
                    Text("预设色温")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                    ForEach([("黄", 0), ("暖白", 50), ("白", 100)], id: \.1) { preset in
                        Button {
                            temperatureValue = Double(preset.1)
                            Task { await store.change(kind: "temperature", value: preset.1) }
                        } label: {
                            Text(preset.0)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color(hex: 0xF59E0B))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color(hex: 0xF59E0B).opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                        .disabled(!canWrite)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - 恶魔眼（M5 / AE7，对齐原版恶魔眼卡）

    private var demonEyeCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("恶魔眼", icon: "eye.fill", color: Theme.brand)
                switchRow("RGB 开关", isOn: Binding(
                    get: { rgbOn },
                    set: { rgbOn = $0; Task { await store.change(kind: "rgbOn", value: $0 ? 1 : 0) } }
                ), tint: Theme.brand)

                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(hexString: snapshotHex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: Color(hexString: snapshotHex).opacity(0.45), radius: 5)
                    Text("#\(snapshotHex)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.label)
                    Spacer()
                }
                swatchRow

                levelSliderRow(title: "亮度调节", value: $brightness,
                               caption: "原协议亮度范围 0 – 255", icon: "sun.max.fill") {
                    debouncedSendLevel()
                }
            }
        }
    }

    /// 原版 8 色快板行（白红橙黄绿蓝紫青）
    private var swatchRow: some View {
        HStack(spacing: 0) {
            ForEach(quickColors, id: \.name) { item in
                let selected = snapshotHex == item.hex
                Circle()
                    .fill(Color(hexString: item.hex))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(selected ? Theme.label : .white, lineWidth: selected ? 3 : 1.5))
                    .shadow(color: Color(hexString: item.hex).opacity(0.3), radius: 4)
                    .frame(maxWidth: .infinity)
                    .onTapGesture {
                        snapshotHex = item.hex
                        sendSnapshotColor(item.hex)
                    }
            }
        }
        .disabled(!canWrite)
    }

    private func sendSnapshotColor(_ hex: String) {
        guard let value = UInt32(hex, radix: 16) else { return }
        let red = Int((value >> 16) & 0xFF)
        let green = Int((value >> 8) & 0xFF)
        let blue = Int(value & 0xFF)
        Task { await store.setColor(red: red, green: green, blue: blue) }
    }

    // MARK: - 日行灯（FX）

    private var daytimeCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("日行开关", icon: "sun.max.fill", color: Theme.green)
                switchRow("日行灯", isOn: Binding(
                    get: { daytimeOn },
                    set: { daytimeOn = $0; Task { await store.change(kind: "daytime", value: $0 ? 1 : 0) } }
                ), tint: Theme.green)
            }
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>, tint: Color) -> some View {
        Toggle(title, isOn: isOn)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Theme.label)
            .tint(tint)
            .disabled(!canWrite)
    }

    // MARK: - 颜色调节（RGB 通用：HSV 色轮 + 预设）

    private var colorCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    sectionHeader("颜色调节", icon: "paintpalette.fill", color: Theme.brand)
                    Spacer()
                    Circle()
                        .fill(currentColor)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: currentColor.opacity(0.45), radius: 6)
                    Text("#\(hexText)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                hsvWheel

                HStack(spacing: 0) {
                    ForEach(presets.indices, id: \.self) { index in
                        let preset = presets[index]
                        let selected = abs(hue - preset.hue) < 2 && abs(saturation - preset.sat) < 0.03
                        Circle()
                            .fill(preset.color)
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(selected ? Theme.label : .white, lineWidth: selected ? 3 : 2))
                            .shadow(color: preset.color.opacity(selected ? 0.55 : 0.25), radius: selected ? 10 : 5)
                            .frame(maxWidth: .infinity)
                            .onTapGesture {
                                hue = preset.hue
                                saturation = preset.sat
                                debouncedSendColor()
                            }
                    }
                }
            }
        }
    }

    /// HSV 色轮：锥形渐变（色相）+ 径向白化（饱和度），拖动取色
    private var hsvWheel: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, 280)
            let center = size / 2
            let radius = center - 8
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
                    .frame(width: size - 16, height: size - 16)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.white, .white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                    .frame(width: size - 16, height: size - 16)
                Circle()
                    .strokeBorder(.black.opacity(0.2), lineWidth: 1.2)
                    .frame(width: size - 16, height: size - 16)
                Circle()
                    .fill(.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 5)
                    .overlay(Circle().fill(currentColor).frame(width: 15, height: 15))
                    .position(x: center + cos(angleRad) * dotR, y: center + sin(angleRad) * dotR)
            }
            .frame(width: geo.size.width, height: geo.size.width)
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
                        debouncedSendColor()
                    }
            )
        }
        .frame(height: 280)
    }

    // MARK: - 亮度 / 速度滑条卡（RGB 通用，对齐原版 sliderCard）

    private func levelSliderCard(title: String, value: Binding<Double>,
                                 caption: String, icon: String,
                                 onChange: @escaping () -> Void) -> some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title, icon: icon, color: Theme.brand)
                HStack(spacing: 10) {
                    Slider(value: value, in: 0...1)
                        .tint(Theme.brand)
                        .disabled(!canWrite)
                        .onChange(of: value.wrappedValue) { _, _ in onChange() }
                    Text("\(Int(value.wrappedValue * 255))")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func levelSliderRow(title: String, value: Binding<Double>,
                                caption: String, icon: String,
                                onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue * 255))")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
            }
            Slider(value: value, in: 0...1)
                .tint(Theme.brand)
                .disabled(!canWrite)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - 灯效模式（行车/开机/转向通道 + 渐变模式格）

    private var modeCard: some View {
        let table = channel.modes
        let ids = table.keys.sorted()
        return AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("灯效模式")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text("\(ids.count) 个")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.brand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.surfaceAlt, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.separator.opacity(0.6), lineWidth: 1))
                }
                Text("模式名与通道绑定：同一编号在行车/转向/开机下是不同灯效。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)

                HStack(spacing: 8) {
                    ForEach(LampChannel.allCases) { item in
                        channelTab(item)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        modeTile(id: id, name: table[id] ?? "模式 \(id)", selected: mode == id)
                    }
                }
            }
        }
    }

    private func channelTab(_ item: LampChannel) -> some View {
        let selected = channel == item
        return Button {
            channel = item
            // 切通道后当前编号可能不存在，回落到该表第一个
            let ids = item.modes.keys.sorted()
            mode = ids.contains(mode) ? mode : (ids.first ?? 1)
        } label: {
            Text(item.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selected ? Theme.brand : Theme.label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    selected ? Theme.brand.opacity(0.12) : Theme.surfaceAlt,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(selected ? Theme.brand.opacity(0.55) : Theme.separator.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    /// 模式格：按模式名里的颜色词上渐变背板（对齐设计稿 _ModeTile）
    private func modeTile(id: Int, name: String, selected: Bool) -> some View {
        let (from, to) = Self.modeColors(name)
        let on: Color = {
            let luminance = (Self.luminance(from) + Self.luminance(to)) / 2
            return luminance > 0.52 ? Color(red: 0.05, green: 0.06, blue: 0.08) : .white
        }()
        return Button {
            mode = id
            Task { await store.setMode(id, channel: channel.rawValue) }
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(on)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 3)
                Text(String(format: "%03d", id))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(on.opacity(0.68))
                    .padding(3)
            }
            .frame(height: 44)
            .background(
                LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? .white : .white.opacity(0.25), lineWidth: selected ? 2.4 : 1)
            )
            .shadow(color: selected ? from.opacity(0.5) : .clear, radius: 10)
        }
        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
    }

    /// 模式名颜色词 → 代表色（主/副），双色渐变背板
    private static let modeColorWords: [(String, Color)] = [
        ("粉", Color(red: 1, green: 0.41, blue: 0.71)),
        ("黄", Color(red: 1, green: 0.78, blue: 0.12)),
        ("青", Color(red: 0.07, green: 0.79, blue: 0.81)),
        ("蓝", Color(red: 0.18, green: 0.48, blue: 0.96)),
        ("紫", Color(red: 0.55, green: 0.29, blue: 0.91)),
        ("红", Color(red: 1, green: 0.23, blue: 0.19)),
        ("绿", Color(red: 0.20, green: 0.78, blue: 0.35)),
        ("橙", Color(red: 1, green: 0.58, blue: 0)),
        ("白", Color(red: 0.91, green: 0.93, blue: 0.95)),
        ("黑", Color(red: 0.23, green: 0.23, blue: 0.24)),
    ]

    private static func modeColors(_ name: String) -> (Color, Color) {
        if name.contains("彩虹") {
            return (Color(red: 1, green: 0.37, blue: 0.36), Color(red: 0.48, green: 0.36, blue: 1))
        }
        var hits: [(Int, Color)] = []
        for (word, color) in modeColorWords {
            if let range = name.range(of: word) {
                hits.append((name.distance(from: name.startIndex, to: range.lowerBound), color))
            }
        }
        if hits.isEmpty {
            return (Color(red: 0.56, green: 0.59, blue: 0.65), Color(red: 0.76, green: 0.78, blue: 0.82))
        }
        hits.sort { $0.0 < $1.0 }
        if hits.count == 1 {
            let c = hits[0].1
            return (c, darken(c, ratio: 0.3))
        }
        return (hits[0].1, hits[1].1)
    }

    /// 线性压暗（替代不存在的 Color.mix）
    private static func darken(_ color: Color, ratio: Double) -> Color {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        let factor = CGFloat(1 - ratio)
        return Color(red: Double(r) * factor, green: Double(g) * factor, blue: Double(b) * factor)
    }

    /// 相对亮度（Rec. 601），用于决定渐变背板上的文字用黑还是白
    private static func luminance(_ color: Color) -> Double {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return Double(r) * 0.299 + Double(g) * 0.587 + Double(b) * 0.114
    }

    // MARK: - 底部命令状态条（对齐原版 command-status）

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

    // MARK: - 快照 → 视图状态（同步后刷新初值）

    private func syncFromSnapshot() {
        guard store.synced, let bytes = store.snapshotBytes else { return }
        switch store.profile {
        case .angle:
            angleValue = Double(store.angle)
        case .m5, .ae7:
            rgbOn = bytes.count > 6 && bytes[6] == 1
            highWhite = bytes.count > 4 && bytes[4] == 1
            highYellow = bytes.count > 5 && bytes[5] == 1
            if bytes.count > 10 { brightness = Double(bytes[10]) / 255 }
            let total = Int(bytes[2]) + Int(bytes[3])
            if total > 0 { temperatureValue = Double(Int(bytes[2]) * 100 / total) }
            if bytes.count > 9 {
                let value = (Int(bytes[7]) << 16) | (Int(bytes[8]) << 8) | Int(bytes[9])
                snapshotHex = String(format: "%06X", value)
            }
        case .fx:
            daytimeOn = bytes.count > 1 && bytes[1] == 1
            let total = Int(bytes[2]) + Int(bytes[3])
            if total > 0 { temperatureValue = Double(Int(bytes[2]) * 100 / total) }
        case .rgb:
            break
        }
    }

    // MARK: - 发送节流

    /// 颜色：250ms 合并（RGB 通用命令直发；M5/AE7 走快照，需要已同步）
    private func debouncedSendColor() {
        colorSendTask?.cancel()
        colorSendTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let c = rgb
            await store.setColor(red: c.r, green: c.g, blue: c.b)
        }
    }

    /// 亮度/速度：400ms 合并（RGB 通用命令；M5/AE7 走快照亮度）
    private func debouncedSendLevel() {
        levelSendTask?.cancel()
        levelSendTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let value = Int(brightness * 255)
            if store.profile == .rgb {
                await store.setGeneric(LampProtocol.GenericCommand.brightness, value: value)
                await store.setGeneric(LampProtocol.GenericCommand.modeSpeed, value: Int(speed * 255))
            } else if needsSnapshot {
                await store.change(kind: "rgbBrightness", value: value)
            }
        }
    }

    /// 色温：250ms 合并（M5/FX 快照）
    private func debouncedSendTemperature() {
        temperatureSendTask?.cancel()
        temperatureSendTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await store.change(kind: "temperature", value: Int(temperatureValue))
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
                                deviceName: ble.connectedDevice?.displayName ?? ""
                            )
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                StatusTile(icon: "cable.connector", title: "通道", value: store.transport?.title ?? "未识别")
                                StatusTile(icon: "slider.horizontal.3", title: "调试类型", value: profileName(store.profile))
                                StatusTile(icon: "checkmark.circle", title: "快照", value: store.synced ? "已同步" : "未同步",
                                           valueColor: store.synced ? Theme.green : Theme.orange)
                                StatusTile(icon: "number", title: "限位", value: "\(store.minAngle) ~ \(store.maxAngle)")
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

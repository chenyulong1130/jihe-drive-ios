import SwiftUI
import UIKit

/// 速牛灯具调试页：对齐参考调试工具的操作流程 ——
/// 选择调试类型 → 读取设备参数 → 按类型开放控件（角度 / AE7 / M5 / FX / 通用 RGB）。
/// 所有写入以设备回包快照为基础只改目标字节，未同步前控件锁定并引导先读取。
struct LampDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: LampStore
    @State private var showDiagnostics = false
    @State private var angleValue: Double = 0
    @State private var temperatureValue: Double = 50
    @State private var brightnessValue: Double = 128
    @State private var speedValue: Double = 128
    @State private var rgbColor: Color = .red
    @State private var rgbOn = true
    @State private var highWhite = false
    @State private var highYellow = false
    @State private var daytimeOn = false
    @State private var angleReset = false
    @State private var copyToast = false

    private var connected: Bool { ble.isConnected }
    /// 未同步快照时控件锁定（角度类型除外：限位未同步也无从下手）
    private var controlsEnabled: Bool { connected && (store.synced || store.profile == .rgb) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                profileCard
                syncCard
                if !store.lastError.isEmpty {
                    Text(store.lastError)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch store.profile {
                case .angle: angleSection
                case .m5: m5Section
                case .ae7: rgbControlSection
                case .fx: fxSection
                case .rgb: rgbControlSection
                }
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
        }
        .onDisappear {
            store.deactivate()
        }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(ble.connectedDevice?.displayName ?? "灯具")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let transport = store.transport {
                StatusPill(text: transport.title, color: Theme.brand, pulsing: false)
            }
            StatusPill(
                text: connected ? "已连接" : "未连接",
                color: connected ? Theme.green : Theme.secondary,
                pulsing: connected
            )
        }
    }

    // MARK: - 调试类型

    private var profileCard: some View {
        AppleCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("调试类型")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.label)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LampState.Profile.allCases) { profile in
                            profileChip(profile)
                        }
                    }
                }
                Text("切换类型会清空参数快照，重新读取后可调节。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func profileChip(_ profile: LampState.Profile) -> some View {
        let selected = store.profile == profile
        return Button {
            store.selectProfile(profile)
        } label: {
            Text(profile.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Theme.label)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Theme.brand : Theme.surfaceAlt, in: Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    // MARK: - 同步状态

    private var syncCard: some View {
        AppleCard(padding: 12) {
            HStack(spacing: 10) {
                CircleIconBadge(
                    icon: store.synced ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                    color: store.synced ? Theme.green : Theme.orange,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.synced ? "参数已同步" : "尚未读取参数")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Text(store.profile == .rgb
                         ? "通用 RGB 协议无查询指令，直接调节"
                         : store.synced ? "快照就绪，可下发调节" : "先读取设备参数再调节")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if store.profile != .rgb {
                    Button {
                        Task { await store.readParams() }
                    } label: {
                        Label("读取参数", systemImage: "arrow.down.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.brand, in: Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                    .disabled(!connected || store.profile == .rgb)
                }
            }
        }
    }

    // MARK: - 角度

    private var angleSection: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("灯光角度", icon: "arrow.triangle.swap", color: Theme.orange)

                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int(angleValue))")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.orange)
                        Text("°")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("范围 \(store.minAngle) ~ \(store.maxAngle) · 步进 \(store.step)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
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
                    .disabled(!controlsEnabled)
                }

                Toggle(isOn: $angleReset) {
                    Text("到达后复位")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.label)
                }
                .tint(Theme.orange)

                Button {
                    Task { await store.setAngle(Int(angleValue), reset: angleReset) }
                } label: {
                    Text("移动到 \(Int(angleValue))°")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Theme.orange, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                .disabled(!controlsEnabled)
            }
        }
    }

    // MARK: - M5

    private var m5Section: some View {
        VStack(spacing: 8) {
            AppleCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("近光色温", icon: "thermometer.sun", color: Color(hex: 0xF59E0B))
                    HStack(spacing: 8) {
                        Text("白").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Slider(value: $temperatureValue, in: 0...100, step: 1)
                            .tint(Color(hex: 0xF59E0B))
                            .disabled(!controlsEnabled)
                        Text("黄").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Text("当前配比 \(Int(temperatureValue))（0 全白 · 100 全黄）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                    Button {
                        Task { await store.change(kind: "temperature", value: Int(temperatureValue)) }
                    } label: {
                        Text("下发色温")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Color(hex: 0xF59E0B), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    .disabled(!controlsEnabled)
                }
            }

            AppleCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("远光通道", icon: "headlight.high.beam", color: Theme.red)
                    toggleRow("远光白", $highWhite, tint: Theme.red) {
                        Task { await store.change(kind: "highWhite", value: highWhite ? 1 : 0) }
                    }
                    toggleRow("远光黄", $highYellow, tint: Color(hex: 0xF59E0B)) {
                        Task { await store.change(kind: "highYellow", value: highYellow ? 1 : 0) }
                    }
                }
            }

            rgbControlSection
        }
    }

    // MARK: - AE7（与通用 RGB 控件共用一套：开关 / 亮度 / 颜色）

    private var ae7Section: some View {
        rgbControlSection
    }

    // MARK: - FX

    private var fxSection: some View {
        VStack(spacing: 8) {
            AppleCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("日行灯", icon: "sun.max.fill", color: Theme.green)
                    toggleRow("日行灯", $daytimeOn, tint: Theme.green) {
                        Task { await store.change(kind: "daytime", value: daytimeOn ? 1 : 0) }
                    }
                }
            }

            AppleCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("近光色温", icon: "thermometer.sun", color: Color(hex: 0xF59E0B))
                    HStack(spacing: 8) {
                        Text("白").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Slider(value: $temperatureValue, in: 0...100, step: 1)
                            .tint(Color(hex: 0xF59E0B))
                            .disabled(!controlsEnabled)
                        Text("黄").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Button {
                        Task { await store.change(kind: "temperature", value: Int(temperatureValue)) }
                    } label: {
                        Text("下发色温")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Color(hex: 0xF59E0B), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    .disabled(!controlsEnabled)
                }
            }
        }
    }

    // MARK: - RGB 控件（M5/AE7 快照 / 通用 RGB 命令共用）

    private var rgbControlSection: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("RGB 氛围灯", icon: "paintpalette.fill", color: Theme.brand)
                toggleRow("RGB 开关", $rgbOn, tint: Theme.brand) {
                    if store.profile == .rgb {
                        Task { await store.setGeneric(LampProtocol.GenericCommand.brightness, value: rgbOn ? Int(brightnessValue) : 0) }
                    } else {
                        Task { await store.change(kind: "rgbOn", value: rgbOn ? 1 : 0) }
                    }
                }
                .disabled(!connected)

                HStack(spacing: 8) {
                    Text("亮度").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    Slider(value: $brightnessValue, in: 0...255, step: 1)
                        .tint(Theme.brand)
                        .disabled(!controlsEnabled)
                    Text("\(Int(brightnessValue))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.label)
                }

                if store.profile == .rgb {
                    HStack(spacing: 8) {
                        Text("速度").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Slider(value: $speedValue, in: 0...255, step: 1)
                            .tint(Theme.orange)
                            .disabled(!connected)
                        Text("\(Int(speedValue))").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.label)
                    }
                    Button {
                        Task { await store.setGeneric(LampProtocol.GenericCommand.modeSpeed, value: Int(speedValue)) }
                    } label: {
                        Text("下发模式速度")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(Theme.orange)
                            .background(Theme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    .disabled(!connected)
                }

                HStack(spacing: 8) {
                    ForEach([Color.red, .orange, .yellow, .green, Color(hex: 0x0EA5E9), .blue, .purple, .white], id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 1))
                            .onTapGesture {
                                rgbColor = color
                                applyColor()
                            }
                    }
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    ColorPicker("自定义颜色", selection: $rgbColor, supportsOpacity: false)
                        .font(.system(size: 13))
                    Button {
                        applyColor()
                    } label: {
                        Label("下发颜色", systemImage: "paintbrush.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.brand, in: Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                    .disabled(!controlsEnabled)
                }

                if store.profile != .rgb {
                    Button {
                        Task { await store.change(kind: "rgbBrightness", value: Int(brightnessValue)) }
                    } label: {
                        Text("下发 RGB 亮度 \(Int(brightnessValue))")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(Theme.brand)
                            .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    .disabled(!controlsEnabled)
                }
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
                                deviceName: ble.connectedDevice?.displayName ?? ""
                            )
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                StatusTile(icon: "cable.connector", title: "通道", value: store.transport?.title ?? "未识别")
                                StatusTile(icon: "slider.horizontal.3", title: "调试类型", value: store.profile.title)
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

                    if let error = ble.lastError, !error.isEmpty {
                        Text(error)
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.red)
                    }
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

    // MARK: - 小件

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

    private func toggleRow(_ title: String, _ binding: Binding<Bool>, tint: Color, onChange: @escaping () -> Void) -> some View {
        Toggle(isOn: binding) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)
        }
        .tint(tint)
        .onChange(of: binding.wrappedValue) { _, _ in onChange() }
    }

    /// Color → RGB 字节下发
    private func applyColor() {
        let uiColor = UIColor(rgbColor)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        Task {
            await store.setColor(red: Int(red * 255), green: Int(green * 255), blue: Int(blue * 255))
        }
    }
}

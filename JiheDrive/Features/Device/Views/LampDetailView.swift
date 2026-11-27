import SwiftUI
import UIKit

/// 速牛灯具调试页（对齐 Flutter 灯光面板设计）：
/// 调色盘（HSV 色轮 + 预设色板，拖动即节流下发）→ 亮度/速度 → 灯效模式
/// （行车/开机/转向/急刹通道 + 渐变色模式格）→ 专用参数（角度/AE7/M5/FX）→ 连接管理。
/// 通用控制走 80/81/82/85 命令映射；专用参数走 1F/20 快照。
struct LampDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: LampStore
    @State private var showDiagnostics = false
    @State private var angleValue: Double = 0
    @State private var angleReset = false
    @State private var temperatureValue: Double = 50
    @State private var brightness: Double = 1.0
    @State private var speed: Double = 0.5
    @State private var hue: Double = 0
    @State private var saturation: Double = 1
    @State private var mode: Int = 1
    @State private var channel: LampChannel = .driving
    @State private var highWhite = false
    @State private var highYellow = false
    @State private var daytimeOn = false
    @State private var copyToast = false
    /// 发送节流：拖动色轮/滑条时合并下发，避免命令积压
    @State private var colorSendTask: Task<Void, Never>?
    @State private var levelSendTask: Task<Void, Never>?

    private var connected: Bool { ble.isConnected }
    /// 通用 RGB 控件无快照依赖；专用参数需先读取同步
    private var controlsEnabled: Bool { connected && (store.synced || store.profile == .rgb) }
    private var isColorProfile: Bool { store.profile == .rgb || store.profile == .m5 || store.profile == .ae7 }
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

    /// 预设色板（hue, sat），与设计稿一致
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
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                if isColorProfile { colorCard }
                levelCard
                modeCard
                profileCard
                connectionCard
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
            VStack(alignment: .leading, spacing: 3) {
                Text(ble.connectedDevice?.displayName ?? "灯具")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                if let transport = store.transport {
                    Text("传输通道 · \(transport.title)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 8)
            StatusPill(
                text: connected ? "已连接" : "未连接",
                color: connected ? Theme.green : Theme.secondary,
                pulsing: connected
            )
        }
    }

    // MARK: - 调色盘（HSV 色轮 + 预设）

    private var colorCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("调色盘")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
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
                // 选中点
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

    // MARK: - 亮度 / 速度

    private var levelCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("亮度 / 速度")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    if needsSnapshot { syncBadge }
                }
                levelSlider(
                    icon: "sun.max.fill", label: "亮度", value: $brightness,
                    tint: Theme.brand, disabled: !controlsEnabled
                ) {
                    debouncedSendLevel()
                }
                if store.profile == .rgb {
                    levelSlider(
                        icon: "forward.end.fill", label: "速度", value: $speed,
                        tint: Theme.orange, disabled: !connected
                    ) {
                        debouncedSendLevel()
                    }
                }
                if !store.lastError.isEmpty {
                    Text(store.lastError)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.red)
                }
            }
        }
    }

    private func levelSlider(
        icon: String, label: String, value: Binding<Double>, tint: Color,
        disabled: Bool, onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 36, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(tint)
                .disabled(disabled)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.label)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - 灯效模式（通道 + 渐变模式格）

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
            return (c, Self.darken(c, ratio: 0.3))
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

    // MARK: - 专用参数（角度 / AE7 / M5 / FX）

    private var profileCard: some View {
        VStack(spacing: 8) {
            AppleCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("专用参数")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.label)
                        Spacer()
                        syncBadge
                    }
                    HStack(spacing: 0) {
                        ForEach([LampState.Profile.angle, .ae7, .m5, .fx], id: \.self) { profile in
                            let selected = store.profile == profile
                            Button {
                                store.selectProfile(profile)
                            } label: {
                                Text(profile.title)
                                    .font(.system(size: 12.5, weight: selected ? .bold : .semibold))
                                    .foregroundStyle(selected ? Theme.brand : Theme.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .background(
                                        selected ? Theme.brand.opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    )
                            }
                            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                        }
                    }
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text("通用 RGB 控件无专用快照；切到具体型号后先「读取参数」再调节。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }

            switch store.profile {
            case .angle: angleSection
            case .m5: temperatureSection; beamSection
            case .fx: fxSection; temperatureSection
            case .ae7, .rgb: EmptyView()
            }
        }
    }

    private var syncBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: store.synced ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(store.synced ? Theme.green : Theme.orange)
            Text(store.synced ? "参数已同步" : "未读取参数")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(store.synced ? Theme.green : Theme.orange)
        }
    }

    // MARK: - 角度

    private var angleSection: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("灯光角度", icon: "arrow.triangle.swap", color: Theme.orange)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(angleValue))")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.orange)
                    Text("°")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("限位 \(store.minAngle)° ~ \(store.maxAngle)°")
                        Text("步进 \(store.step)°")
                    }
                    .font(.system(size: 11, weight: .semibold))
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
                HStack(spacing: 10) {
                    Toggle(isOn: $angleReset) {
                        Text("到位后复位")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.label)
                    }
                    .tint(Theme.orange)
                    Button {
                        Task { await store.setAngle(Int(angleValue), reset: angleReset) }
                    } label: {
                        Text("移动到 \(Int(angleValue))°")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Theme.orange, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                    .disabled(!controlsEnabled)
                }
            }
        }
    }

    // MARK: - 色温（M5 / FX）

    private var temperatureSection: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader("近光色温", icon: "thermometer.sun", color: Color(hex: 0xF59E0B))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.97, green: 0.98, blue: 1.0), Color(red: 1, green: 0.72, blue: 0.23)],
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
                            temperatureValue = min(100, max(0, value.location.x / max(1, geo.size.width) * 100))
                        }
                    )
                }
                .frame(height: 26)
                HStack {
                    Text("白").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("配比 \(Int(temperatureValue))")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(hex: 0xF59E0B))
                    Spacer()
                    Text("黄").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Button {
                    Task { await store.change(kind: "temperature", value: Int(temperatureValue)) }
                } label: {
                    Text("下发色温")
                        .font(.system(size: 14, weight: .bold))
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

    // MARK: - 远光（M5）/ 日行灯（FX）

    private var beamSection: some View {
        AppleCard(padding: 12) {
            VStack(spacing: 10) {
                sectionHeader("远光通道", icon: "headlight.high.beam", color: Theme.red)
                HStack(spacing: 10) {
                    beamToggle("远光白", isOn: $highWhite, color: Theme.red)
                    beamToggle("远光黄", isOn: $highYellow, color: Color(hex: 0xF59E0B))
                }
            }
        }
    }

    private var fxSection: some View {
        AppleCard(padding: 12) {
            HStack {
                sectionHeader("日行灯", icon: "sun.max.fill", color: Theme.green)
                Spacer()
                Toggle("", isOn: $daytimeOn)
                    .labelsHidden()
                    .tint(Theme.green)
                    .disabled(!controlsEnabled)
                    .onChange(of: daytimeOn) { _, on in
                        Task { await store.change(kind: "daytime", value: on ? 1 : 0) }
                    }
            }
        }
    }

    private func beamToggle(_ title: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            Task { await store.change(kind: title == "远光白" ? "highWhite" : "highYellow", value: isOn.wrappedValue ? 1 : 0) }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn.wrappedValue ? color : Theme.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? color : Theme.secondary)
                Spacer()
                Text(isOn.wrappedValue ? "开" : "关")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isOn.wrappedValue ? color : Theme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isOn.wrappedValue ? color.opacity(0.45) : Theme.separator.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
        .disabled(!controlsEnabled)
    }

    // MARK: - 连接管理（读取参数 / 断开）

    private var connectionCard: some View {
        AppleCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("连接")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text(ble.connectedDevice?.displayName ?? "--")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if store.profile != .rgb {
                        Button {
                            Task { await store.readParams() }
                        } label: {
                            Label("读取参数", systemImage: "arrow.down.circle")
                                .font(.system(size: 13, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .foregroundStyle(Theme.brand)
                                .background(Theme.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                        }
                        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                        .disabled(!connected)
                    }
                    Button {
                        ble.disconnect()
                    } label: {
                        Label("断开连接", systemImage: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .foregroundStyle(Theme.red)
                            .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    .disabled(!connected)
                }
            }
        }
    }

    // MARK: - 发送节流

    /// 颜色：250ms 合并（RGB 类通用命令直发；M5/AE7 走快照，需要已同步）
    private func debouncedSendColor() {
        guard isColorProfile else { return }
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

import SwiftUI

// MARK: - 通用小件

// StatusPill 用 Core/Design/AppleUI.swift 的版本（支持 pulsing 呼吸动画）。

struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    var accent: Color = Theme.brand

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
    }
}

/// 彩色圆形图标底座（充电卡 / 峰值压差卡等行卡用；AppleUI.IconBadge 是圆角矩形底，勿混用）
struct CircleIconBadge: View {
    let icon: String
    let color: Color
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.14))
            Image(systemName: icon)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

/// 状态磁贴（诊断弹窗「状态信息」网格用）：图标+标题一行，数值带状态色
struct StatusTile: View {
    let icon: String
    let title: String
    let value: String
    var valueColor: Color = Theme.label

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(valueColor.opacity(0.85))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 连接状态横幅（诊断弹窗顶部）：圆形图标底座 + 设备名，占满整行
struct ConnectionBannerTile: View {
    let connected: Bool
    let deviceName: String

    var body: some View {
        let tint: Color = connected ? Theme.green : Theme.secondary
        return HStack(spacing: 10) {
            CircleIconBadge(icon: connected ? "antenna.rtl.fill" : "antenna.rtl.slash", color: tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(connected ? "已连接" : "未连接")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(connected ? tint : Theme.secondary)
                Text(deviceName.isEmpty ? "--" : deviceName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 带图标的指标卡（对齐 Flutter 版 BmsPanel 的 DeviceMetricCard）：
/// 标题行 = 15pt 图标 + 12pt 标题；数值 19pt 加粗，单位同色小字。
struct MetricCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let unit: String
    var valueColor: Color = Theme.label

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(valueColor.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
    }
}

struct LogPanel: View {
    let title: String
    let logs: [String]

    var body: some View {
        AppleCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    if !logs.isEmpty {
                        Text("\(logs.count) 条")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                if logs.isEmpty {
                    Text("暂无通信记录")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .frame(height: 44)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(logs.indices, id: \.self) { index in
                                Text(logs[index])
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                }
            }
        }
    }
}

// MARK: - 蓝牙列表 / 连接弹窗

struct DeviceScanSheet: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @Environment(\.dismiss) private var dismiss
    let filter: DeviceKind?
    let onConnected: (BLEDevice) -> Void

    @State private var activeFilter: DeviceKind?
    /// 正在连接的设备：按钮转 spinner、其余行禁点，避免「点了没反应」的卡顿感
    @State private var connectingID: UUID?

    /// 常见手机/穿戴/杂设备关键词：扫描列表不显示（大小写不敏感）
    private static let junkKeywords: [String] = [
        "iphone", "ipad", "macbook", "imac", "airpod", "android", "galaxy",
        "xiaomi", "redmi", "honor", "huawei", "oppo", "vivo", "oneplus",
        "realme", "pixel", "sm-g", "sm-a", "watch", "buds", "band",
        "手环", "手机", "耳机", "平板", "电视", "音箱",
    ]

    private var visibleDevices: [BLEDevice] {
        let base = ble.discovered.filter { device in
            // 无名设备 + 手机/穿戴等杂设备全部隐藏
            guard !device.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            let lower = device.name.lowercased()
            return !Self.junkKeywords.contains { lower.contains($0) }
        }
        guard let activeFilter else { return base }
        return base.filter { $0.kind == activeFilter }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    scanStatusBar
                    if let error = ble.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    filterChips

                    if visibleDevices.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 10) {
                            ForEach(Array(visibleDevices.enumerated()), id: \.element.id) { index, device in
                                deviceCard(device)
                                    .staggerIn(min(index, 6))
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("连接设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        ble.stopScan()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        ble.startScan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task {
                activeFilter = filter
                ble.startScan()
            }
            .onDisappear { ble.stopScan() }
        }
    }

    // MARK: 扫描状态条

    private var scanStatusBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(ble.isScanning ? Theme.brand.opacity(0.14) : Theme.surfaceAlt)
                if ble.isScanning {
                    ProgressView()
                        .tint(Theme.brand)
                } else {
                    Image(systemName: "bluetooth")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(ble.isScanning ? "正在搜索附近设备" : "扫描已暂停")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ble.isScanning ? Theme.brand : Theme.secondary)
                Text(ble.isScanning
                     ? "约 10 秒后自动停止，可随时手动重扫"
                     : "点右上角重新扫描")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer(minLength: 8)

            if !visibleDevices.isEmpty {
                Text("\(visibleDevices.count) 台")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.brand.opacity(0.10), in: Capsule())
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 分类过滤 chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(nil, title: "全部", icon: "circle.grid.2x2.fill", tint: Theme.brand)
                ForEach(DeviceKind.allCases) { kind in
                    filterChip(kind, title: kind.shortTitle, icon: kind.icon, tint: kind.accent)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(_ kind: DeviceKind?, title: String, icon: String, tint: Color) -> some View {
        let selected = activeFilter == kind
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { activeFilter = kind }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.white : Theme.label)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(selected ? tint : Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    // MARK: 设备卡

    private func deviceCard(_ device: BLEDevice) -> some View {
        let isConnecting = connectingID == device.id
        let accent = device.kind.accent
        return HStack(spacing: 12) {
            // 类别徽标：与设备页卡片同一套渐变视觉
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.24), accent.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: device.kind.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                // 扫描行标题 = 广播名（不改用户的蓝牙名）；分类收进下面一行
                Text(device.displayName)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(device.kind.title)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(accent.opacity(0.12), in: Capsule())
                    if isConnecting {
                        Label("连接中…", systemImage: "circle.dotted")
                    } else {
                        signalMeter(rssi: device.rssi)
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isConnecting ? accent : Theme.secondary)
            }

            Spacer(minLength: 6)

            Menu {
                ForEach(DeviceKind.allCases) { kind in
                    Button {
                        ble.setKind(kind, for: device.id)
                    } label: {
                        Label("按\(kind.shortTitle)打开", systemImage: kind.icon)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 30, height: 30)
            }
            .opacity(isConnecting ? 0.35 : 1)

            Button {
                guard connectingID == nil else { return }
                connectingID = device.id
                Task {
                    do {
                        try await ble.connect(device)
                        onConnected(device)
                        dismiss()
                    } catch {
                        ble.log("连接失败：\(error.localizedDescription)")
                    }
                    connectingID = nil
                }
            } label: {
                if isConnecting {
                    ProgressView()
                        .frame(width: 44)
                } else {
                    Text("连接")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [accent, accent.opacity(0.75)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                        )
                }
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
            .disabled(connectingID != nil && !isConnecting)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(connectingID == nil || isConnecting ? 1 : 0.45)
    }

    // MARK: 信号强度（3 格，按 RSSI 分档着色）

    @ViewBuilder
    private func signalMeter(rssi: Int) -> some View {
        let bars = rssi >= -63 ? 3 : (rssi >= -76 ? 2 : 1)
        let tint: Color = bars == 3 ? Theme.green : (bars == 2 ? Theme.orange : Theme.red)
        HStack(spacing: 4) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.8))
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(index < bars ? tint : Theme.separator.opacity(0.5))
                        .frame(width: 3, height: CGFloat(4 + index * 3))
                }
            }
            Text("\(rssi)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.brand.opacity(0.16), Theme.brand.opacity(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: ble.isScanning ? "iphone.radiowaves.left.and.right" : "bluetooth.slash")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: 5) {
                Text(ble.isScanning ? "正在搜索附近的车辆设备…" : "没有发现设备")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(ble.isScanning
                     ? "请确认设备已上电并在附近，首次搜索可能需要几秒"
                     : "点右上角重新扫描，或确认设备已上电")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .padding(.horizontal, 20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - 密码弹窗

struct PowerPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var error = ""
    let onSuccess: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.brand)
                Text("输入开机密码")
                    .font(Theme.title2)
                    .foregroundStyle(Theme.label)
                Text("大灯调节设备沿用石栏小程序的 8 位开机密码（默认 \(DeviceAuth.defaultPowerOnCode)，可在「我的 → 设备」保存自定义密码），验证后 7 天内免输入。")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)

                SecureField("8 位密码", text: $code)
                    .textContentType(.password)
                    .keyboardType(.numberPad)
                    .font(.system(size: 22, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    .onChange(of: code) { _, newValue in
                        if newValue.count >= 8 { submit(newValue) }
                    }

                if !error.isEmpty {
                    Text(error)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.red)
                }

                Button(action: { submit(code) }) {
                    Text("确认")
                        .font(Theme.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.tap)
                        .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))

                Spacer()
            }
            .padding(Theme.page)
            .background(Theme.groupedBackground)
            .navigationTitle("设备访问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func submit(_ value: String) {
        guard value == DeviceAuth.powerOnCode else {
            error = "密码错误，请重新输入"
            code = ""
            return
        }
        DeviceAuth.markVerified()
        onSuccess()
        dismiss()
    }
}

struct ServicePasswordSheet: View {
    @EnvironmentObject private var session: DeviceSession
    @State private var code = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 36))
                    .foregroundStyle(Theme.orange)
                Text("维修密码")
                    .font(Theme.title2)
                    .foregroundStyle(Theme.label)
                Text("进入限位、预设等高级设置前需要验证 4 位密码。")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)

                SecureField("4 位密码", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(size: 24, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    .onChange(of: code) { _, newValue in
                        if newValue.count >= 4 { session.submit(newValue) }
                    }

                if !session.serviceError.isEmpty {
                    Text(session.serviceError)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.red)
                }

                Button { session.submit(code) } label: {
                    Text("确认")
                        .font(Theme.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.tap)
                        .background(Theme.orange, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))

                Spacer()
            }
            .padding(Theme.page)
            .background(Theme.groupedBackground)
            .navigationTitle("高级设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { session.cancel() }
                }
            }
        }
    }
}

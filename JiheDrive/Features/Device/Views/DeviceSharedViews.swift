import SwiftUI

// MARK: - 通用小件

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

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

private func rssiIcon(_ rssi: Int) -> String {
    if rssi > -55 { return "wifi" }
    if rssi > -75 { return "wifi" }
    return "wifi.exclamationmark"
}

// MARK: - 蓝牙列表 / 连接弹窗

struct DeviceScanSheet: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @Environment(\.dismiss) private var dismiss
    let filter: DeviceKind?
    let onConnected: (BLEDevice) -> Void

    @State private var activeFilter: DeviceKind?

    private var visibleDevices: [BLEDevice] {
        guard let activeFilter else { return ble.discovered }
        return ble.discovered.filter { $0.kind == activeFilter }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip(nil, title: "全部")
                        ForEach(DeviceKind.allCases) { kind in
                            filterChip(kind, title: kind.shortTitle)
                        }
                    }
                    .padding(.horizontal, Theme.page)
                    .padding(.vertical, 10)
                }

                if ble.isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在搜索附近设备 · 30 秒后自动停止")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.page)
                    .padding(.bottom, 8)
                }

                if let error = ble.lastError {
                    Text(error)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.page)
                        .padding(.bottom, 8)
                }

                List {
                    if visibleDevices.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "bluetooth")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.tertiary)
                            Text(ble.isScanning ? "正在搜索…" : "没有发现设备，请点击右上角重新扫描")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(visibleDevices) { device in
                            deviceRow(device)
                                .listRowBackground(Theme.surface)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
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

    private func filterChip(_ kind: DeviceKind?, title: String) -> some View {
        let selected = activeFilter == kind
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { activeFilter = kind }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Theme.label)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Theme.brand : Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
    }

    private func deviceRow(_ device: BLEDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.kind.icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.brand)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.label)
                HStack(spacing: 6) {
                    Text(device.kind.shortTitle)
                    Text("·")
                    Text("\(device.rssi) dBm")
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: rssiIcon(device.rssi))
                .foregroundStyle(device.rssi > -75 ? Theme.green : Theme.orange)
                .font(.system(size: 15))

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
                    .foregroundStyle(Theme.secondary)
            }

            Button {
                Task {
                    do {
                        try await ble.connect(device)
                        onConnected(device)
                        dismiss()
                    } catch {
                        ble.log("连接失败：\(error.localizedDescription)")
                    }
                }
            } label: {
                Text("连接")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.brand, in: Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
        }
        .padding(.vertical, 4)
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
                Text("大灯调节设备沿用石栏小程序的 8 位开机密码，验证后 7 天内免输入。")
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

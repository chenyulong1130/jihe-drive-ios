import SwiftUI

/// 点睛仪表详情页（精简版，两大功能 + 轮切）：
/// 表盘主题（素材图圆形预览，混合/电池/里程/温度/胎压分组，点按即下发；当前主题高亮）
/// + 轮切设置（单屏/轮切显示 + 轮切时间 + 参与主题，寄存器 7）
/// + 仪表配置（电量显示/时间格式/背光/能耗单位/磁控/轮切声音/续航阈值）。
struct DianjingDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: DianjingStore
    @State private var showAutoStyleSheet = false
    @State private var autoStyleTimeDraft = 0
    @State private var autoStyleDraftStyles: [String] = []

    private var connected: Bool { ble.isConnected }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                styleCard
                configCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("点睛仪表")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.attach(ble)
            store.startPolling()
        }
        .onDisappear {
            store.stopPolling()
            store.deactivate()
        }
        .sheet(isPresented: $showAutoStyleSheet) { autoStyleSheet }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(ble.connectedDevice?.displayName ?? "仪表")
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

    // MARK: - 表盘主题（素材图圆形预览，当前主题高亮）

    /// 样式分组与名称，真值来自点睛小程序 setting-style/style.js
    private let styleGroups: [(name: String, styles: [(id: String, title: String)])] = [
        ("混合", [("A01", "样式1"), ("A02", "样式2"), ("A03", "样式3"), ("A04", "样式4")]),
        ("电池", [("B01", "单体电压信息"), ("B02", "电池完整信息"), ("B03", "电池实时健康")]),
        ("里程", [("C01", "里程信息")]),
        ("温度", [("D01", "温度信息")]),
        ("胎压", [("E01", "胎压信息")]),
    ]

    @State private var styleGroupIndex = 0

    /// 当前表盘样式归一化比对：读回值可能带大小写/空白差异
    private func isCurrentStyle(_ id: String) -> Bool {
        !store.dialStyle.isEmpty && store.dialStyle.uppercased().contains(id)
    }

    private var styleCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("表盘主题")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    if !store.dialStyle.isEmpty {
                        Text("当前 \(store.dialStyle)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.brand)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.brand.opacity(0.1), in: Capsule())
                    }
                    Button {
                        autoStyleTimeDraft = max(5, store.autoStyleTime)
                        autoStyleDraftStyles = store.autoStyleStyles.isEmpty
                            ? styleGroups.flatMap { $0.styles.map(\.id) }
                            : store.autoStyleStyles
                        showAutoStyleSheet = true
                    } label: {
                        Label("轮切设置", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.brand)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.brand.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.95, brightness: 0))
                    .disabled(!connected)
                }

                // 分组选择（混合 / 电池 / 里程 / 温度 / 胎压）
                HStack(spacing: 0) {
                    ForEach(styleGroups.indices, id: \.self) { index in
                        let selected = styleGroupIndex == index
                        Button {
                            styleGroupIndex = index
                        } label: {
                            Text(styleGroups[index].name)
                                .font(.system(size: 12.5, weight: selected ? .bold : .semibold))
                                .foregroundStyle(selected ? Theme.brand : Theme.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? Theme.brand.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                        }
                        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    }
                }
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                // 表盘视觉预览格：素材图为圆形仪表 → 圆形裁切预览，点按即下发样式
                let group = styleGroups[styleGroupIndex]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 14) {
                    ForEach(group.styles, id: \.id) { style in
                        let selected = isCurrentStyle(style.id)
                        Button {
                            Task { await store.setDialStyle(style.id) }
                        } label: {
                            VStack(spacing: 6) {
                                meterStyleImage(style.id)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle().strokeBorder(
                                            selected ? Theme.brand : Theme.separator.opacity(0.4),
                                            lineWidth: selected ? 3 : 1)
                                    )
                                    .overlay(alignment: .bottom) {
                                        if selected {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundStyle(Theme.brand)
                                                .background(Circle().fill(Theme.groupedBackground).padding(2))
                                                .offset(y: 4)
                                        }
                                    }
                                    .padding(4)
                                Text(style.title)
                                    .font(.system(size: 12, weight: selected ? .bold : .semibold))
                                    .foregroundStyle(selected ? Theme.brand : Theme.label)
                            }
                        }
                        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                        .disabled(!connected)
                    }
                }
            }
        }
    }

    /// 表盘样式素材图（打包自点睛小程序 assets/meterStyle：A01…E01）
    private func meterStyleImage(_ id: String) -> Image {
        if let ui = UIImage(named: id) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "circle.dotted")
    }

    // MARK: - 轮切设置弹窗（寄存器 7：单屏/轮切 + 轮切时间 + 参与主题）

    private var autoStyleSheet: some View {
        SheetShell(
            title: "轮切设置",
            subtitle: "多块表盘主题按时自动轮换",
            onClose: { showAutoStyleSheet = false }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("显示方式", selection: Binding(
                                get: { store.autoStyleState },
                                set: { state in
                                    Task {
                                        await store.setAutoStyleSwitch(
                                            state: state, time: max(5, autoStyleTimeDraft),
                                            styles: autoStyleDraftStyles)
                                    }
                                }
                            )) {
                                Text("单屏显示").tag(1)
                                Text("轮切显示").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .disabled(!connected)

                            HStack {
                                Text("轮切时间")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.label)
                                Spacer()
                                Stepper(
                                    "\(autoStyleTimeDraft) 秒",
                                    onIncrement: { autoStyleTimeDraft = min(3600, autoStyleTimeDraft + 5) },
                                    onDecrement: { autoStyleTimeDraft = max(5, autoStyleTimeDraft - 5) }
                                )
                                .fixedSize()
                            }
                            Text("轮切显示时，每块参与的主题按该间隔轮换。")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }

                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("参与轮切的主题")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.label)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                                ForEach(styleGroups.flatMap { $0.styles.map(\.id) }, id: \.self) { id in
                                    let title = styleGroups.flatMap { $0.styles }.first { $0.id == id }?.title ?? id
                                    let selected = autoStyleDraftStyles.contains(id)
                                    Button {
                                        if selected {
                                            autoStyleDraftStyles.removeAll { $0 == id }
                                        } else if autoStyleDraftStyles.count < 10 {
                                            autoStyleDraftStyles.append(id)
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .font(.system(size: 14))
                                                .foregroundStyle(selected ? Theme.brand : Theme.tertiary)
                                            Text("\(id) \(title)")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(Theme.label)
                                                .lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(
                                            selected ? Theme.brand.opacity(0.10) : Theme.surfaceAlt,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        )
                                    }
                                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                                }
                            }
                            Button {
                                Task {
                                    await store.setAutoStyleSwitch(
                                        state: store.autoStyleState, time: autoStyleTimeDraft,
                                        styles: autoStyleDraftStyles)
                                    showAutoStyleSheet = false
                                }
                            } label: {
                                Text("保存轮切设置")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                            }
                            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                            .disabled(!connected)
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Theme.groupedBackground)
        }
        .sheetChrome()
    }

    // MARK: - 配置（对齐小程序 setting-basic/extra：picker 下发 = 下标+1，开关 1/2）

    private var configCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("仪表配置")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.label)

                configSegmentedRow("电量显示", options: ["电量格", "容量", "电压"], selection: store.batteryDisplayMode) { value in
                    Task { await store.setBatteryDisplay(value + 1) }
                }
                configSegmentedRow("时间格式", options: ["24h", "12h"], selection: store.timeFormat) { value in
                    Task { await store.setTimeFormat(value + 1) }
                }
                configSegmentedRow("背光", options: ["低", "中", "高"], selection: store.backlight) { value in
                    Task { await store.setBacklight(value + 1) }
                }
                configSegmentedRow("能耗单位", options: ["Wh/km", "Ah/km"], selection: store.energyUnit) { value in
                    Task { await store.setEnergyUnit(value + 1) }
                }

                Divider().opacity(0.6)

                configToggleRow("磁控开关", isOn: store.magneticSwitch) { value in
                    Task { await store.setSwitch(DianjingRegister.magneticSwitch, on: value) }
                }
                configToggleRow("轮切声音", isOn: store.switchSound) { value in
                    Task { await store.setSwitch(DianjingRegister.switchSound, on: value) }
                }

                Divider().opacity(0.6)

                HStack {
                    Text("续航更新阈值")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Stepper(
                        "\(store.socThreshold > 0 ? "\(store.socThreshold)" : "--")",
                        onIncrement: {
                            Task { await store.setSocThreshold(store.socThreshold + 1) }
                        },
                        onDecrement: {
                            Task { await store.setSocThreshold(store.socThreshold - 1) }
                        }
                    )
                    .fixedSize()
                }
                Text("取值 1~100，续航低于该阈值时仪表提示。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func configSegmentedRow(
        _ title: String, options: [String], selection: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)
            Picker(title, selection: Binding(
                get: { max(0, selection - 1) },
                set: { onChange($0) }
            )) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!connected)
        }
    }

    private func configToggleRow(_ title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.label)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onChange($0) }
            ))
            .labelsHidden()
            .tint(Theme.brand)
            .disabled(!connected)
        }
    }
}

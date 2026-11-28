import SwiftUI

/// 点睛仪表详情页（重设计 2026-11-28）：
/// 表盘主题直接在网格上点选——单显 = 单选（点击即下发当前表盘），
/// 轮切 = 多选（点击勾选/取消参与主题，与轮换时间一起即时下发，寄存器 7）；
/// 仪表配置（电量显示/时间格式/背光/能耗单位/磁控/轮切声音/续航阈值）
/// 收进右上角齿轮按钮，不再占用主页面。
struct DianjingDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: DianjingStore
    @State private var showConfigSheet = false
    /// 轮切参与主题多选集合（跨分组；寄存器 7 的样式名列表）
    @State private var rotationSelection: Set<String> = []
    /// 轮换时间草稿（stepper 改动防抖后随选中集一起下发）
    @State private var rotationTimeDraft = 0
    @State private var rotationTimeSaveTask: Task<Void, Never>?
    /// 已向仪表声明过的显示方式（1 单显 / 2 轮切），用于高亮模式 chips
    @State private var declaredMode: Int = 1

    private var connected: Bool { ble.isConnected }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                headerRow
                styleCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("点睛仪表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfigSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("仪表配置")
            }
        }
        .onAppear {
            store.attach(ble)
            store.startPolling()
            rotationTimeDraft = max(5, store.autoStyleTime)
            declaredMode = store.autoStyleState
            if rotationSelection.isEmpty {
                rotationSelection = Set(store.autoStyleStyles)
            }
        }
        .onDisappear {
            store.stopPolling()
            store.deactivate()
        }
        .onChange(of: store.autoStyleStyles) { _, styles in
            // 首次读到寄存器 7 时播种多选集合（避免空白）
            if rotationSelection.isEmpty {
                rotationSelection = Set(styles)
            }
        }
        .onChange(of: store.autoStyleState) { _, state in
            declaredMode = state
        }
        .sheet(isPresented: $showConfigSheet) { configSheet }
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

    // MARK: - 表盘主题（单显单选 / 轮切多选，点选即下发）

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
                // 标题行：表盘主题 + 当前表盘徽标
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
                }

                // 显示方式：单显（单选）/ 轮切（多选），点 chip 即下发寄存器 7
                HStack(spacing: 8) {
                    modeChip(1, title: "单屏显示", icon: "rectangle.fill", tint: Theme.brand)
                    modeChip(2, title: "轮切显示", icon: "arrow.triangle.2.circlepath", tint: Theme.teal)
                }

                if declaredMode == 2 {
                    // 轮切配置：轮换时间 + 已选提示（多选主题在下方网格直接勾选）
                    HStack {
                        Text("轮换时间")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Spacer()
                        Stepper(
                            "\(max(5, rotationTimeDraft)) 秒",
                            onIncrement: {
                                rotationTimeDraft = min(3600, max(5, rotationTimeDraft) + 5)
                                scheduleRotationTimeSave()
                            },
                            onDecrement: {
                                rotationTimeDraft = max(5, rotationTimeDraft - 5)
                                scheduleRotationTimeSave()
                            }
                        )
                        .fixedSize()
                    }
                    Text("在下方主题网格点选参与轮换的主题（已选 \(rotationSelection.count) 个，至少保留 1 个），点选即时下发。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("点按主题即设为当前表盘；切到轮切后改为多选参与轮换的主题。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
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

                // 表盘视觉预览格：素材图为圆形仪表 → 圆形裁切预览
                // 单显 = 点按设当前；轮切 = 点按勾选/取消参与轮换
                let group = styleGroups[styleGroupIndex]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 14) {
                    ForEach(group.styles, id: \.id) { style in
                        let highlighted = declaredMode == 2
                            ? rotationSelection.contains(style.id)
                            : isCurrentStyle(style.id)
                        Button {
                            handleStyleTap(style.id)
                        } label: {
                            VStack(spacing: 6) {
                                meterStyleImage(style.id)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle().strokeBorder(
                                            highlighted ? Theme.brand : Theme.separator.opacity(0.4),
                                            lineWidth: highlighted ? 3 : 1)
                                    )
                                    .overlay(alignment: .bottom) {
                                        if highlighted {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 18))
                                                .foregroundStyle(Theme.brand)
                                                .background(Circle().fill(Theme.groupedBackground).padding(2))
                                                .offset(y: 4)
                                        }
                                    }
                                    .overlay(alignment: .topTrailing) {
                                        // 轮切模式下同时标注当前表盘
                                        if declaredMode == 2, isCurrentStyle(style.id) {
                                            Image(systemName: "display")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(4)
                                                .background(Circle().fill(Theme.orange))
                                                .offset(x: 4, y: -2)
                                        }
                                    }
                                    .padding(4)
                                VStack(spacing: 1) {
                                    Text(style.title)
                                        .font(.system(size: 12, weight: highlighted ? .bold : .semibold))
                                        .foregroundStyle(highlighted ? Theme.brand : Theme.label)
                                    if declaredMode == 2, rotationSelection.contains(style.id) {
                                        Text("参与轮换")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Theme.teal)
                                    }
                                }
                            }
                        }
                        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                        .disabled(!connected)
                    }
                }
            }
        }
    }

    /// 单显/轮切模式 chip：点按即下发（携带当前多选集合与轮换时间）
    private func modeChip(_ mode: Int, title: String, icon: String, tint: Color) -> some View {
        let selected = declaredMode == mode
        return Button {
            guard connected, declaredMode != mode else { return }
            declaredMode = mode
            let styles = rotationSelection.isEmpty
                ? (store.autoStyleStyles.isEmpty ? ["A01"] : store.autoStyleStyles)
                : rotationSelection.sorted()
            Task {
                await store.setAutoStyleSwitch(state: mode, time: max(5, rotationTimeDraft), styles: styles)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: selected ? .bold : .semibold))
            }
            .foregroundStyle(selected ? Color.white : Theme.label)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? tint : Theme.surfaceAlt)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
        .disabled(!connected)
    }

    /// 主题点按：单显 = 设当前表盘（寄存器 4）；
    /// 轮切 = 勾选/取消参与主题并即时下发（寄存器 7，至少保留 1 个）
    private func handleStyleTap(_ id: String) {
        guard connected else { return }
        if declaredMode == 2 {
            if rotationSelection.contains(id) {
                guard rotationSelection.count > 1 else { return }
                rotationSelection.remove(id)
            } else {
                rotationSelection.insert(id)
            }
            Task {
                await store.setAutoStyleSwitch(
                    state: 2, time: max(5, rotationTimeDraft),
                    styles: rotationSelection.sorted())
            }
        } else {
            Task { await store.setDialStyle(id) }
        }
    }

    /// 轮换时间 stepper 防抖：停手 800ms 后与当前选中集一起下发
    private func scheduleRotationTimeSave() {
        rotationTimeSaveTask?.cancel()
        rotationTimeSaveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, connected else { return }
            await store.setAutoStyleSwitch(
                state: declaredMode, time: max(5, rotationTimeDraft),
                styles: rotationSelection.isEmpty
                    ? (store.autoStyleStyles.isEmpty ? ["A01"] : store.autoStyleStyles)
                    : rotationSelection.sorted())
        }
    }

    /// 表盘样式素材图（打包自点睛小程序 assets/meterStyle：A01…E01）
    private func meterStyleImage(_ id: String) -> Image {
        if let ui = UIImage(named: id) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "circle.dotted")
    }

    // MARK: - 仪表配置（右上角齿轮弹窗）

    private var configSheet: some View {
        SheetShell(
            title: "仪表配置",
            subtitle: "电量显示 · 时间 · 背光 · 单位 · 开关",
            onClose: { showConfigSheet = false }
        ) {
            ScrollView(showsIndicators: false) {
                configCard
                    .padding(.horizontal, Theme.page)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
            }
            .background(Theme.groupedBackground)
        }
        .sheetChrome()
    }

    private var configCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("显示与提醒")
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
                Text("取值 1~100，续航低于该阈值时仪表提示。设置即时下发。")
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

import SwiftUI

/// 点睛仪表详情页（深色主题，对齐点睛小程序「表盘」页排版 2026-11-28）：
/// 近黑背景 + 2 列表盘圆卡网格 + 「使用中」徽标 + 底部「确定使用」按钮。
/// 点按表盘 = 选中（单显单选 / 轮切多选），按底部按钮一次性下发（与小程序交互一致）；
/// 仪表配置（电量显示/时间格式/背光/能耗单位/磁控/轮切声音/续航阈值）
/// 收进右上角齿轮按钮。
struct DianjingDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @ObservedObject var store: DianjingStore
    @State private var showConfigSheet = false
    /// 轮切参与主题多选集合（跨分组；寄存器 7 的样式名列表）
    @State private var rotationSelection: Set<String> = []
    /// 单显模式待下发的表盘样式（nil = 用仪表当前值）
    @State private var pendingStyle: String?
    /// 轮换时间草稿（stepper 改动防抖后随选中集一起下发）
    @State private var rotationTimeDraft = 0
    /// 已向仪表声明过的显示方式（1 单显 / 2 轮切）
    @State private var declaredMode: Int = 1

    private var connected: Bool { ble.isConnected }

    // 布局对齐点睛小程序（2 列网格 + 底部确定按钮），配色沿用 App 主题色
    private var pageBackground: Color { Theme.groupedBackground }
    private var cardBackground: Color { Theme.surface }
    private var textPrimary: Color { Theme.label }
    private var textSecondary: Color { Theme.secondary }
    private var accent: Color { Theme.brand }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    topBar
                    groupSegmented
                    dialGrid
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.never)

            confirmButton
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(pageBackground.opacity(0.96))
        }
        .background(pageBackground.ignoresSafeArea())
        .navigationTitle("点睛仪表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfigSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(textSecondary)
                }
                .accessibilityLabel("仪表配置")
            }
        }
        .toolbarBackground(pageBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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

    // MARK: - 顶栏（状态 + 单屏/轮切，无大标题行）

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connected ? accent : textSecondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(connected ? "已连接" : "未连接")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(textSecondary)
                Spacer(minLength: 8)
                if !store.dialStyle.isEmpty {
                    Text("使用中 \(store.dialStyle)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(textPrimary)
                }
                // 单屏/轮切：点按即下发显示方式（对齐小程序右上角下拉）
                Menu {
                    Button("单屏显示") {
                        declaredMode = 1
                        applyModeSwitch(1)
                    }
                    Button("轮切显示") {
                        declaredMode = 2
                        applyModeSwitch(2)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: declaredMode == 2
                              ? "arrow.triangle.2.circlepath" : "circle.circle")
                            .font(.system(size: 12, weight: .bold))
                        Text(declaredMode == 2 ? "轮切显示" : "单屏显示")
                            .font(.system(size: 13, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomTrailingRadius: 12,
                                               bottomLeadingRadius: 12, topTrailingRadius: 12,
                                               style: .continuous)
                        .fill(Theme.surfaceAlt)
                    )
                }
                .disabled(!connected)
            }

            if declaredMode == 2 {
                HStack {
                    Text("轮换时间")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(textSecondary)
                    Spacer()
                    Stepper(
                        "\(max(5, rotationTimeDraft)) 秒",
                        onIncrement: { rotationTimeDraft = min(3600, max(5, rotationTimeDraft) + 5) },
                        onDecrement: { rotationTimeDraft = max(5, rotationTimeDraft - 5) }
                    )
                    .fixedSize()
                }
                Text("点选下方主题参与轮换（已选 \(rotationSelection.count) 个，至少保留 1 个），按底部按钮保存。")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary.opacity(0.75))
            } else {
                Text("点选主题后按底部「确定使用」下发；切到轮切可多选参与轮换。")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary.opacity(0.75))
            }
        }
    }

    /// 单屏/轮切切换下发（寄存器 7：状态 + 轮换时间 + 参与主题一起写）
    private func applyModeSwitch(_ mode: Int) {
        let styles = rotationSelection.isEmpty
            ? (store.autoStyleStyles.isEmpty ? ["A01"] : store.autoStyleStyles)
            : rotationSelection.sorted()
        Task {
            await store.setAutoStyleSwitch(state: mode, time: max(5, rotationTimeDraft), styles: styles)
        }
    }

    // MARK: - 分组（混合 / 电池 / 里程 / 温度 / 胎压）

    /// 样式分组与名称，真值来自点睛小程序 setting-style/style.js
    private let styleGroups: [(name: String, styles: [(id: String, title: String)])] = [
        ("混合", [("A01", "样式1"), ("A02", "样式2"), ("A03", "样式3"), ("A04", "样式4")]),
        ("电池", [("B01", "单体电压信息"), ("B02", "电池完整信息"), ("B03", "电池实时健康")]),
        ("里程", [("C01", "里程信息")]),
        ("温度", [("D01", "温度信息")]),
        ("胎压", [("E01", "胎压信息")]),
    ]

    @State private var styleGroupIndex = 0

    private var groupSegmented: some View {
        HStack(spacing: 0) {
            ForEach(styleGroups.indices, id: \.self) { index in
                let selected = styleGroupIndex == index
                Button {
                    styleGroupIndex = index
                } label: {
                    Text(styleGroups[index].name)
                        .font(.system(size: 13, weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? textPrimary : textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            selected ? Theme.surfaceAlt : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
            }
        }
        .padding(4)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 表盘网格（2 列深色圆卡，点按选中）

    /// 当前表盘样式归一化比对：读回值可能带大小写/空白差异
    private func isCurrentStyle(_ id: String) -> Bool {
        !store.dialStyle.isEmpty && store.dialStyle.uppercased().contains(id)
    }

    private var dialGrid: some View {
        let group = styleGroups[styleGroupIndex]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 14) {
            ForEach(group.styles, id: \.id) { style in
                dialCard(style)
            }
        }
    }

    private func dialCard(_ style: (id: String, title: String)) -> some View {
        let inUse = isCurrentStyle(style.id)
        let selected = declaredMode == 2
            ? rotationSelection.contains(style.id)
            : (pendingStyle ?? store.dialStyle).uppercased().contains(style.id)
        return Button {
            guard connected else { return }
            if declaredMode == 2 {
                if rotationSelection.contains(style.id) {
                    guard rotationSelection.count > 1 else { return }
                    rotationSelection.remove(style.id)
                } else {
                    rotationSelection.insert(style.id)
                }
            } else {
                pendingStyle = style.id
            }
        } label: {
            VStack(spacing: 8) {
                meterStyleImage(style.id)
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(
                            selected ? accent : Theme.separator.opacity(0.5),
                            lineWidth: selected ? 3 : 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if inUse {
                            Text("使用中")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.brand))
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 19))
                                .foregroundStyle(accent)
                                .background(Circle().fill(Theme.surface).padding(2))
                                .offset(x: 4, y: 4)
                        }
                    }
                Text(style.title)
                    .font(.system(size: 13, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? textPrimary : textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? accent.opacity(0.55) : Theme.separator.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
        .disabled(!connected)
    }

    // MARK: - 底部确定按钮（单显：确定使用 / 轮切：保存轮切设置）

    private var confirmButton: some View {
        Button {
            guard connected else { return }
            if declaredMode == 2 {
                Task {
                    await store.setAutoStyleSwitch(
                        state: 2, time: max(5, rotationTimeDraft),
                        styles: rotationSelection.sorted())
                }
            } else if let style = pendingStyle {
                Task { await store.setDialStyle(style) }
            }
        } label: {
            Text(buttonTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(buttonEnabled ? Theme.brand : Theme.brand.opacity(0.35))
                )
        }
        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
        .disabled(!buttonEnabled)
    }

    private var buttonTitle: String {
        declaredMode == 2 ? "保存轮切设置" : "确定使用"
    }

    private var buttonEnabled: Bool {
        guard connected else { return false }
        if declaredMode == 2 {
            return !rotationSelection.isEmpty
        }
        return pendingStyle != nil || !store.dialStyle.isEmpty
    }

    // MARK: - 表盘样式素材图（打包自点睛小程序 assets/meterStyle：A01…E01）

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

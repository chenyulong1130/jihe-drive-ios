import SwiftUI

/// 石栏大灯调节页（苹果风格独立设计，不复用控制器工程风布局）：
/// 3D 车模灯光效果为核心主视觉，光束仰角实时跟随高度；
/// 常驻内容只留「高度主控」，速度/限位/预设/自检等收进右上角设置弹窗，
/// 指令记录收进诊断弹窗（带复制）。协议沿用 motor_handle 的 5A A5 电机帧。
struct HeadlightDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @EnvironmentObject private var session: DeviceSession
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceStore
    @ObservedObject var store: MotorStore

    @State private var glbFile: URL?
    @State private var glbFailed = false
    @State private var resetToken = 0
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var copyToast = false
    /// 用户保存的记忆高度（本地持久化），替代固定快捷档位
    @State private var memories: [Int] = HeadlightMemory.load()
    @State private var showSavePrompt = false
    @State private var pendingSavePercent: Int = 0

    private var current: Int { store.params.absolutePercent }
    private var target: Int { store.params.targetPercent }
    private var accent: Color { Theme.teal }

    /// 滑块拖动中显示拖动值，否则显示目标值
    private var displayPercent: Double {
        scrubbing ? scrubValue : store.targetPercent
    }

    /// 3D 光束跟随：拖动中跟手指，移动中乐观指向目标，空闲时设备回报的真实位置
    private var beamPercent: Int {
        if scrubbing { return Int(scrubValue) }
        if store.busy { return Int(store.targetPercent) }
        return current
    }

    private var stageDark: Bool { appearance.resolvedScheme == .dark }

    private var stageColors: [Color] {
        stageDark
            ? [Color(hex: 0x081018), Color(hex: 0x122236), Color(hex: 0x060B10)]
            : [Color(hex: 0xE9EDF3), Color(hex: 0xF4F6F9), Color(hex: 0xDCE3EC)]
    }

    private var stageFg: Color { stageDark ? .white : Theme.label }
    private var stageFgSoft: Color { stageDark ? Color.white.opacity(0.62) : Theme.secondary }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                stage
                mainControlCard
                if !store.paramsLoaded {
                    loadHintCard
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("石栏大灯")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.loadParams()
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .accessibilityLabel("读取参数")
                Button {
                    showDiagnostics = true
                } label: {
                    Image(systemName: "waveform.path.ecg")
                }
                .accessibilityLabel("诊断")
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .onAppear {
            store.attach(ble, handlerKey: "headlight")
            if !store.paramsLoaded { store.loadParams() }
        }
        .onDisappear { store.deactivate() }
        .task(id: model.selectedVehicle?.vinNo ?? "none") {
            await loadCarModel()
        }
        .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .alert("保存记忆位置", isPresented: $showSavePrompt) {
            Button("保存") {
                memories = HeadlightMemory.add(pendingSavePercent)
                memorySavedFeedback()
            }
            Button("不用", role: .cancel) {}
        } message: {
            Text("是否把 \(pendingSavePercent)% 保存为快捷记忆？保存后可在设备列表和本页一键到达。")
        }
    }

    private func loadCarModel() async {
        guard let vehicle = model.selectedVehicle,
              let url = vehicle.model3DURL,
              vehicle.isGLBModel else {
            glbFile = nil
            glbFailed = model.selectedVehicle != nil
            return
        }
        do {
            glbFile = try await GLBModelStore.localFile(for: url, vin: vehicle.vinNo)
            glbFailed = false
        } catch {
            glbFile = nil
            glbFailed = true
        }
    }

    // MARK: - 3D 车模舞台（大灯灯光效果）

    private var stage: some View {
        ZStack {
            LinearGradient(colors: stageColors, startPoint: .top, endPoint: .bottom)

            stageContent
                .padding(.horizontal, 4)
                .padding(.top, 40)
                .padding(.bottom, 30)

            VStack {
                stageHeader
                Spacer(minLength: 0)
                stageHint
            }
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var stageContent: some View {
        if let glbFile {
            Color.clear.overlay {
                ModelViewerWebView(
                    glbFile: glbFile,
                    reuseKey: "headlight3d",
                    interactive: true,
                    autoRotate: false,
                    resetToken: resetToken,
                    lightsOn: true,
                    beamPercent: beamPercent,
                    // 车靠右、相机拉远：光束朝左侧伸展，仰角变化一目了然
                    modelOffsetX: 0.6,
                    cameraDistance: 5.1
                )
            }
        } else if glbFailed {
            VStack(spacing: 8) {
                Text("3D 模型不可用")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(stageFg)
                Text("当前车辆未提供 3D 模型，下方为示意视图")
                    .font(Theme.caption)
                    .foregroundStyle(stageFgSoft)
                HeadlightBeamView(current: current, target: Int(displayPercent), accent: accent)
                    .frame(height: 140)
                    .padding(.horizontal, 8)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在加载车模")
                    .font(Theme.caption)
                    .foregroundStyle(stageFgSoft)
            }
        }
    }

    private var stageHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("大灯高度")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(stageFg)
                Text(model.selectedVehicle?.name ?? "石栏大灯")
                    .font(Theme.caption)
                    .foregroundStyle(stageFgSoft)
            }
            Spacer(minLength: 8)
            StatusPill(
                text: store.status,
                color: store.busy ? Theme.orange : (store.paramsLoaded ? Theme.green : Theme.secondary)
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private var stageHint: some View {
        HStack(spacing: 10) {
            Text("拖动旋转 · 双击复位")
                .font(Theme.caption)
                .foregroundStyle(stageFgSoft)
            Spacer()
            Button("复位视角") { withAnimation(Motion.quick) { resetToken += 1 } }
                .font(Theme.caption)
                .foregroundStyle(stageDark ? .white : Theme.brand)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - 高度主控（常驻的唯一操作卡）

    private var mainControlCard: some View {
        AppleCard(padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                // 大数字摘要
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(scrubbing ? Int(scrubValue) : current)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondary)
                    Text(scrubbing ? "拖动预览" : "当前高度")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 5) {
                            Rectangle()
                                .fill(Theme.orange)
                                .frame(width: 12, height: 2)
                            Text("目标 \(target)%")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.orange)
                        }
                        Text("限位 \(store.params.minPercent)–\(store.params.maxPercent)%")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                // 主滑杆：拖动 3D 光束实时预览，松手一次性下发
                VStack(alignment: .leading, spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { displayPercent },
                            set: { newValue in
                                scrubValue = newValue
                                store.targetPercent = newValue
                            }
                        ),
                        in: 0...100,
                        step: 1,
                        onEditingChanged: { editing in
                            if editing {
                                scrubbing = true
                            } else {
                                scrubbing = false
                                store.moveTo(percent: scrubValue)
                                // 调好一次后询问是否存为记忆（本地持久化，列表页/下次直接点按直达）
                                pendingSavePercent = Int(scrubValue.rounded())
                                showSavePrompt = true
                            }
                        }
                    )
                    .tint(accent)
                    .disabled(!store.paramsLoaded || store.busy)
                    Text("拖动时 3D 灯光实时预览，松手后大灯移动到该高度，并可存为记忆")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiary)
                }

                Divider().opacity(0.6)

                // 记忆位置：用户存的快捷高度，点按直达，长按删除
                memorySection
            }
        }
    }

    /// 记忆位置区：替代固定快捷档位，内容来自用户保存（本地持久化）
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("记忆位置")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    memories = HeadlightMemory.add(Int(displayPercent.rounded()))
                    memorySavedFeedback()
                } label: {
                    Label("保存当前 \(Int(displayPercent.rounded()))%", systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                }
                .buttonStyle(PressableStyle(scale: 0.95, brightness: 0))
                .disabled(!store.paramsLoaded)
            }

            if memories.isEmpty {
                Text("还没有记忆。调好高度松手时按提示保存，或点右上角「保存当前」。")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(memories, id: \.self) { percent in
                            Button {
                                store.moveTo(percent: Double(percent))
                            } label: {
                                VStack(spacing: 2) {
                                    Text("\(percent)")
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    Text("记忆 %")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(Theme.secondary)
                                }
                                .foregroundStyle(percent == current ? accent : Theme.label)
                                .frame(width: 64, height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(percent == current ? accent.opacity(0.14) : Theme.surfaceAlt)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(percent == current ? accent.opacity(0.55) : .clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(PressableStyle(scale: 0.95, brightness: 0))
                            .disabled(!store.paramsLoaded || store.busy)
                            .contextMenu {
                                Button(role: .destructive) {
                                    memories = HeadlightMemory.remove(percent)
                                } label: {
                                    Label("删除记忆 \(percent)%", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func memorySavedFeedback() {
        copyToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copyToast = false }
    }

    /// 参数未读取时的引导卡（替代原来的 12 格参数总览）
    private var loadHintCard: some View {
        AppleCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("尚未读取到电机参数")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Text("确认设备已通电后，点右上角刷新重试；读取成功后即可调节。")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 诊断弹窗（带复制）

    private var diagnosticsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            ConnectionBannerTile(
                                connected: ble.isConnected,
                                deviceName: ble.connectedDevice?.displayName ?? ""
                            )
                            LazyVGrid(
                                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                                spacing: 8
                            ) {
                                StatusTile(icon: "checkmark.seal.fill", title: "参数状态",
                                           value: store.paramsLoaded ? "已读取" : "待读取",
                                           valueColor: store.paramsLoaded ? Theme.green : Theme.orange)
                                StatusTile(icon: "gearshape.fill", title: "电机状态",
                                           value: store.busy ? "运行中" : "空闲",
                                           valueColor: store.busy ? Theme.orange : Theme.green)
                                StatusTile(icon: "car.2.fill", title: "当前车型",
                                           value: projectName)
                                StatusTile(icon: "arrow.up.and.down", title: "位置",
                                           value: "\(current)% → \(target)%",
                                           valueColor: accent)
                                StatusTile(icon: "ruler.fill", title: "限位范围",
                                           value: "\(store.params.minPercent)–\(store.params.maxPercent)%")
                                StatusTile(icon: "arrow.2.squarepath", title: "方向",
                                           value: store.params.reverse ? "反转" : "正向",
                                           valueColor: store.params.reverse ? Theme.orange : Theme.label)
                            }
                        }
                    }

                    LogPanel(title: "指令记录", logs: store.logs)

                    LogPanel(title: "蓝牙日志", logs: ble.logs)

                    Button {
                        let all = (store.logs + ["", "—— 蓝牙日志 ——"] + ble.logs).joined(separator: "\n")
                        copyToPasteboard(all, fallback: "暂无记录")
                    } label: {
                        Label("复制全部日志", systemImage: "doc.on.doc")
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

    private var projectName: String {
        MotorProject.all.first(where: { $0.index == store.params.project })?.name ?? "默认"
    }

    private func copyToPasteboard(_ text: String, fallback: String) {
        UIPasteboard.general.string = text.isEmpty ? fallback : text
        copyToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copyToast = false
        }
    }

    // MARK: - 设置弹窗

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // 运行速度
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("运行速度")
                                    .font(Theme.headline)
                                    .foregroundStyle(Theme.label)
                                Spacer()
                                Text("\(Int(store.speedLevel)) / 10")
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(accent)
                            }
                            Slider(value: $store.speedLevel, in: 0...10, step: 1)
                                .tint(accent)
                                .disabled(!store.paramsLoaded)
                            Button { store.setSpeed(store.speedLevel) } label: {
                                Text("应用速度")
                                    .font(Theme.footnote)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                            .disabled(!store.paramsLoaded)
                        }
                    }

                    // 车型预设
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("车型预设")
                                .font(Theme.headline)
                                .foregroundStyle(Theme.label)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(MotorProject.all) { project in
                                        let selected = store.selectedProject == project.index
                                        Button {
                                            withServiceAuth { store.applyProject(project) }
                                        } label: {
                                            VStack(spacing: 4) {
                                                Text(project.name)
                                                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                                Text("\(project.min)–\(project.max)%")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(Theme.tertiary)
                                            }
                                            .foregroundStyle(selected ? accent : Theme.label)
                                            .frame(width: 84, height: 56)
                                            .background(
                                                selected ? accent.opacity(0.14) : Theme.surfaceAlt,
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .strokeBorder(selected ? accent.opacity(0.55) : .clear, lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(PressableStyle(scale: 0.95, brightness: 0))
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // 限位范围（维修密码）
                    AppleCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("限位范围（需维修密码 0241）")
                                .font(Theme.headline)
                                .foregroundStyle(Theme.label)
                            HStack {
                                Text("下限 \(Int(store.rangeMin))%")
                                Spacer()
                                Text("上限 \(Int(store.rangeMax))%")
                            }
                            .font(Theme.caption)
                            .foregroundStyle(Theme.tertiary)
                            HStack(spacing: 12) {
                                Slider(value: $store.rangeMin, in: 0...100, step: 1).tint(accent)
                                Slider(value: $store.rangeMax, in: 0...100, step: 1).tint(accent)
                            }
                            Button {
                                withServiceAuth { store.setRange() }
                            } label: {
                                Text("应用限位")
                                    .font(Theme.footnote)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                        }
                    }

                    // 模式与维护
                    AppleCard(padding: 14) {
                        VStack(spacing: 14) {
                            Picker("工作模式", selection: Binding(
                                get: { store.workingMode },
                                set: { mode in store.setWorkingMode(mode) }
                            )) {
                                Text("扫描").tag(0)
                                Text("归位").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .disabled(!store.paramsLoaded)

                            Toggle("自检模式", isOn: Binding(
                                get: { store.selfMode },
                                set: { newValue in
                                    store.selfMode = newValue
                                    store.setSelfTest(enabled: newValue)
                                }
                            ))
                            .disabled(!store.paramsLoaded)

                            Toggle("反转方向", isOn: Binding(
                                get: { store.reverse },
                                set: { newValue in
                                    withServiceAuth {
                                        store.reverse = newValue
                                        store.setReverse(newValue)
                                    }
                                }
                            ))
                            .disabled(!store.paramsLoaded)

                            HStack(spacing: 10) {
                                Button {
                                    withServiceAuth { store.softZero() }
                                } label: {
                                    Text("软归零")
                                        .font(Theme.footnote)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                                Button {
                                    withServiceAuth { store.hardZero() }
                                } label: {
                                    Text("硬归零")
                                        .font(Theme.footnote)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                            }
                            .disabled(!store.paramsLoaded || store.busy)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("大灯设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showSettings = false } }
            }
        }
    }

    private func withServiceAuth(_ action: @escaping () -> Void) {
        if session.serviceVerified {
            action()
        } else {
            session.requestServiceAuth { ok in
                if ok { action() }
            }
        }
    }
}

// MARK: - 2D 光束降级视图（无 3D 模型时）

/// 车身侧视图：大灯光束的仰角随当前高度百分比变化，橙色虚线标出目标高度
private struct HeadlightBeamView: View {
    let current: Int
    let target: Int
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let groundY = h - 14
            let wheelR: CGFloat = 10
            let bodyW = min(w * 0.38, 140)
            let carLeading: CGFloat = 4
            let bodyH: CGFloat = 26
            let bodyY = groundY - wheelR * 2 - bodyH + 5

            let lampX = carLeading + bodyW - 5
            let lampY = bodyY + 9

            let beamTop: CGFloat = 12
            let span = lampY - beamTop
            let beamCenter = lampY - CGFloat(min(100, max(0, current))) / 100 * span
            let targetCenter = lampY - CGFloat(min(100, max(0, target))) / 100 * span
            let beamEndX = w - 8
            let spread: CGFloat = 12

            ZStack {
                Capsule()
                    .fill(Theme.separator)
                    .frame(height: 2)
                    .position(x: w / 2, y: groundY)

                BeamWedgeShape(
                    fromX: lampX, fromY: lampY,
                    toX: beamEndX, centerY: beamCenter, spread: spread
                )
                .fill(
                    LinearGradient(
                        colors: [Theme.yellow.opacity(0.42), accent.opacity(0.05)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )

                TargetMarkShape(centerY: targetCenter, x: beamEndX)
                    .stroke(Theme.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]))

                Group {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.label.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.label.opacity(0.35), lineWidth: 1)
                        )
                        .frame(width: bodyW * 0.52, height: 17)
                        .position(x: carLeading + bodyW * 0.42, y: bodyY - 3)

                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.label.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Theme.label.opacity(0.35), lineWidth: 1)
                        )
                        .frame(width: bodyW, height: bodyH)
                        .position(x: carLeading + bodyW / 2, y: bodyY + bodyH / 2)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .frame(width: bodyW * 0.34, height: 9)
                        .position(x: carLeading + bodyW * 0.42, y: bodyY - 3)

                    ForEach([0.26, 0.76], id: \.self) { ratio in
                        Circle()
                            .fill(Theme.surface)
                            .overlay(Circle().strokeBorder(Theme.label.opacity(0.45), lineWidth: 2))
                            .frame(width: wheelR * 2, height: wheelR * 2)
                            .position(x: carLeading + bodyW * ratio, y: groundY - wheelR)
                    }

                    Circle()
                        .fill(Theme.yellow)
                        .shadow(color: Theme.yellow.opacity(0.85), radius: 5)
                        .frame(width: 9, height: 9)
                        .position(x: lampX, y: lampY)
                }

                Text("高")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .position(x: beamEndX - 2, y: beamTop + 2)
                Text("低")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .position(x: beamEndX - 2, y: lampY - 4)
            }
        }
    }
}

/// 光束扇形：灯珠 → 右侧上下展开
private struct BeamWedgeShape: Shape {
    let fromX: CGFloat
    let fromY: CGFloat
    let toX: CGFloat
    let centerY: CGFloat
    let spread: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: fromX, y: fromY))
        p.addLine(to: CGPoint(x: toX, y: centerY - spread))
        p.addLine(to: CGPoint(x: toX, y: centerY + spread))
        p.closeSubpath()
        return p
    }
}

/// 目标高度竖虚线
private struct TargetMarkShape: Shape {
    let centerY: CGFloat
    let x: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x, y: centerY - 16))
        p.addLine(to: CGPoint(x: x, y: centerY + 16))
        return p
    }
}

import SwiftUI

/// 控制器专属页：电机位置仪表 + 快捷行程 + 限位/速度 + 车型预设，高级操作需维修密码
struct MotorDetailView: View {
    @EnvironmentObject private var ble: DeviceBLEManager
    @EnvironmentObject private var session: DeviceSession
    @ObservedObject var store: MotorStore

    @State private var showLogs = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                motorHero
                SectionHeader("快捷行程")
                quickCard
                SectionHeader("位置与速度")
                sliderCard
                SectionHeader("自检与归位")
                switchCard
                SectionHeader("车型预设")
                projectCard
                SectionHeader("通信日志")
                LogPanel(title: "指令记录", logs: store.logs)
            }
            .padding(.horizontal, Theme.page)
            .padding(.bottom, 40)
        }
        .background(Theme.groupedBackground)
        .navigationTitle("电机控制器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.loadParams() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }
        }
        .onAppear {
            store.attach(ble)
            if !store.paramsLoaded { store.loadParams() }
        }
        .onDisappear { store.deactivate() }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                ScrollView {
                    Text(store.logs.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.page)
                }
                .background(Theme.groupedBackground)
                .navigationTitle("指令记录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("完成") { showLogs = false } }
                }
            }
        }
    }

    private var motorHero: some View {
        AppleCard(padding: 16) {
            VStack(spacing: 14) {
                HStack {
                    Label("当前位置", systemImage: "gearshape.2")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer()
                    StatusPill(text: store.status, color: store.busy ? .orange : (store.paramsLoaded ? .green : .secondary))
                }

                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(Theme.surfaceAlt, lineWidth: 14)
                        Circle()
                            .trim(from: 0, to: CGFloat(min(100, max(0, Double(store.params.absolutePercent)))) / 100)
                            .stroke(Theme.brand, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 0) {
                            Text("\(store.params.absolutePercent)")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.label)
                            Text("绝对位置 %")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .frame(width: 112, height: 112)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("目标 \(store.params.targetPercent)%")
                            .font(Theme.callout)
                            .foregroundStyle(Theme.label)
                        Text("限位 \(store.params.minPercent)–\(store.params.maxPercent)%")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                        Text("速度等级 \(store.params.speedLevel)")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                        Text(store.reverse ? "反转已开启" : "正向")
                            .font(Theme.caption)
                            .foregroundStyle(store.reverse ? Theme.orange : Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                }

                Picker("工作模式", selection: Binding(
                    get: { store.workingMode },
                    set: { mode in
                        withServiceAuth { store.setWorkingMode(mode) }
                    }
                )) {
                    Text("扫描").tag(0)
                    Text("归位").tag(1)
                }
                .pickerStyle(.segmented)
                .disabled(!store.paramsLoaded)
            }
        }
    }

    private var quickCard: some View {
        AppleCard(padding: 14) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { value in
                        Button {
                            store.moveTo(percent: Double(value))
                        } label: {
                            Text("\(value)%")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.label)
                                .frame(maxWidth: .infinity)
                                .frame(height: 38)
                                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(PressableStyle(scale: 0.95, brightness: 0))
                        .disabled(!store.paramsLoaded || store.busy)
                    }
                }
                Text(store.reverse ? "反转开启：快捷百分比按 100 − 目标 换算到绝对位置" : "按目标百分比移动到对应绝对位置")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var sliderCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("目标百分比")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("\(Int(store.targetPercent))%")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.brand)
                    }
                    Slider(value: $store.targetPercent, in: 0...100, step: 1)
                        .disabled(!store.paramsLoaded || store.busy)
                    Button {
                        store.moveTo(percent: store.targetPercent)
                    } label: {
                        Label("移动到此位置", systemImage: "arrow.left.and.right")
                            .font(Theme.footnote)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                    .disabled(!store.paramsLoaded || store.busy)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("速度等级")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("\(Int(store.speedLevel)) / 10")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.brand)
                    }
                    Slider(value: $store.speedLevel, in: 0...10, step: 1)
                        .disabled(!store.paramsLoaded)
                    Button { store.setSpeed(store.speedLevel) } label: {
                        Label("应用速度", systemImage: "speedometer")
                            .font(Theme.footnote)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                    .disabled(!store.paramsLoaded)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("限位范围（需维修密码）")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                    HStack {
                        Text("下限 \(Int(store.rangeMin))%")
                        Spacer()
                        Text("上限 \(Int(store.rangeMax))%")
                    }
                    .font(Theme.caption)
                    .foregroundStyle(Theme.tertiary)
                    HStack(spacing: 12) {
                        Slider(value: $store.rangeMin, in: 0...100, step: 1)
                        Slider(value: $store.rangeMax, in: 0...100, step: 1)
                    }
                    Button {
                        withServiceAuth { store.setRange() }
                    } label: {
                        Label("应用限位", systemImage: "ruler")
                            .font(Theme.footnote)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                }
            }
        }
    }

    private var switchCard: some View {
        AppleCard(padding: 14) {
            VStack(spacing: 14) {
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

                Toggle("日行灯开关（仅本地状态）", isOn: $store.lightSwitch)
                    .font(Theme.footnote)

                HStack(spacing: 10) {
                    Button {
                        withServiceAuth { store.softZero() }
                    } label: {
                        Label("软归零", systemImage: "circle.dashed")
                            .font(Theme.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                    Button {
                        withServiceAuth { store.hardZero() }
                    } label: {
                        Label("硬归零", systemImage: "circle")
                            .font(Theme.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
                }
                .disabled(!store.paramsLoaded || store.busy)
            }
        }
    }

    private var projectCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(MotorProject.all) { project in
                    let selected = store.selectedProject == project.index
                    Button {
                        withServiceAuth { store.applyProject(project) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17))
                            Text(project.name)
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                            Text("\(project.min)–\(project.max)%")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .foregroundStyle(selected ? Theme.brand : Theme.label)
                        .frame(width: 84, height: 76)
                        .background(selected ? Theme.brand.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.95, brightness: 0))
                }
            }
            .padding(.vertical, 2)
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

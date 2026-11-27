import SwiftUI

/// 车辆设置：schema 驱动，写入直接下发到车端
struct VehicleSettingsView: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = VehicleSettingsStore()
    @State private var toast: String?

    var body: some View {
        SheetShell(
            title: "车辆设置",
            subtitle: vehicle.name,
            onClose: { dismiss() }
        ) {
            ZStack {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if !store.loading || !store.raw.isEmpty {
                        ForEach(VehicleSettingsService.groups) { group in
                            sectionHeader(group.title)
                            AppleCard(padding: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 {
                                            HairLine(inset: 14)
                                        }
                                        row(item)
                                    }
                                }
                            }
                        }

                        if let error = store.error {
                            SoftBanner(
                                text: error,
                                icon: "exclamationmark.triangle.fill",
                                tone: Theme.orange
                            )
                            .padding(.top, 14)
                        }

                        Text("修改会直接下发到车辆，与官方 App 同步生效。\n个别设置需要车辆在线才能执行。")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 18)
                            .padding(.horizontal, 10)

                        Button {
                            UIPasteboard.general.string = store.rawJSON
                            showToast("设置原始数据已复制，可发给开发者排查")
                        } label: {
                            Label("复制设置原始数据（排查用）", systemImage: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                        .padding(.top, 6)
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 32)

                if store.loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text("正在读取车辆设置…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.groupedBackground.opacity(store.raw.isEmpty ? 1 : 0.78))
                }
            }
        }
        .sheetChrome()
        .overlay(alignment: .bottom) {
            if let toast {
                ToastView(text: toast)
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task { await store.load(vin: vehicle.vinNo) }
    }

    // MARK: - 行

    /// 分组标题（带语义图标，比纯文字标题更有辨识度）
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sectionIcon(title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brand)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func sectionIcon(_ title: String) -> String {
        switch title {
        case "骑行": return "speedometer"
        case "解锁": return "lock.open.fill"
        case "快捷键": return "hand.tap.fill"
        case "安防": return "shield.lefthalf.filled"
        case "感应": return "dot.radiowaves.left.and.right"
        case "灯光": return "lightbulb.fill"
        case "仪表": return "gauge.high"
        case "音效": return "speaker.wave.2.fill"
        case "电池": return "battery.75percent"
        default: return "gearshape.fill"
        }
    }

    private func row(_ item: VehicleSettingItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.label)
                if let desc = item.desc {
                    Text(desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if store.busyKey == item.key {
                ProgressView().scaleEffect(0.85)
            } else {
                control(item)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(store.busyKey == item.key ? 0.7 : 1)
    }

    @ViewBuilder
    private func control(_ item: VehicleSettingItem) -> some View {
        switch item.kind {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { store.value(for: item) == "1" },
                set: { _ in
                    Task {
                        let ok = await store.toggle(item: item)
                        showToast(ok ? "\(item.title) 已更新" : (store.error ?? "设置失败"))
                    }
                }
            ))
            .labelsHidden()
            .tint(Theme.brand)
            .disabled(store.busyKey != nil)

        case .select(let options):
            Menu {
                // 服务器当前值不在选项表里时（如车型提供别的档位），把当前值补进菜单
                let current = store.value(for: item)
                let known = options.contains(where: { $0.value == current })
                if !current.isEmpty, !known {
                    Button {
                        Task {
                            let ok = await store.select(item: item, newValue: current)
                            showToast(ok ? "\(item.title)：保持当前值" : (store.error ?? "设置失败"))
                        }
                    } label: {
                        Label("当前值 \(current)", systemImage: "checkmark")
                    }
                }
                ForEach(options) { option in
                    Button {
                        Task {
                            let ok = await store.select(item: item, newValue: option.value)
                            showToast(ok ? "\(item.title)：\(option.label)" : (store.error ?? "设置失败"))
                        }
                    } label: {
                        if store.value(for: item) == option.value {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label(for: item, options: options))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.brand)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background {
                    Capsule().fill(Theme.brand.opacity(0.10))
                }
            }
            .disabled(store.busyKey != nil)

        case .action:
            Button {
                Task {
                    let ok = await store.runAction(item: item)
                    if ok {
                        showToast(item.key == "openCushion" ? "坐垫解锁成功" : "指令已发送")
                    } else {
                        showToast(store.error ?? "执行失败")
                    }
                }
            } label: {
                Text("执行")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background {
                        Capsule().fill(Theme.brand)
                    }
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0.02))
            .disabled(store.busyKey != nil)
        }
    }

    private func label(for item: VehicleSettingItem, options: [VehicleSettingOption]) -> String {
        let current = store.value(for: item)
        if current.isEmpty { return "未设置" }
        return options.first(where: { $0.value == current })?.label ?? "当前值 \(current)"
    }

    private func showToast(_ text: String) {
        withAnimation(Motion.spring) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(Motion.quick) { toast = nil }
        }
    }
}

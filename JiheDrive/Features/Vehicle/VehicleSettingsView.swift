import SwiftUI

/// 车辆设置：schema 驱动，写入直接下发到车端
struct VehicleSettingsView: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = VehicleSettingsStore()
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "车辆设置",
                subtitle: vehicle.name,
                onClose: { dismiss() }
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if store.loading && store.raw.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("正在读取车辆设置")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else {
                        ForEach(VehicleSettingsService.groups) { group in
                            SectionHeader(group.title)
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
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 32)
            }
        }
        .background(Theme.groupedBackground.ignoresSafeArea())
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

            control(item)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(store.busyKey == item.key ? 0.55 : 1)
    }

    @ViewBuilder
    private func control(_ item: VehicleSettingItem) -> some View {
        switch item.kind {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { store.value(for: item) == "1" },
                set: { _ in
                    Task { await store.toggle(item: item) }
                }
            ))
            .labelsHidden()
            .tint(Theme.brand)
            .disabled(store.busyKey != nil)

        case .select(let options):
            Menu {
                ForEach(options) { option in
                    Button {
                        Task {
                            await store.select(item: item, newValue: option.value)
                            showToast("\(item.title)：\(option.label)")
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
                    await store.runAction(item: item)
                    showToast(item.key == "openCushion" ? "坐垫解锁指令已发送" : "指令已发送")
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
        return options.first(where: { $0.value == current })?.label ?? "未设置"
    }

    private func showToast(_ text: String) {
        withAnimation(Motion.spring) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(Motion.quick) { toast = nil }
        }
    }
}

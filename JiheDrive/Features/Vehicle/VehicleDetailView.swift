import SwiftUI
import UIKit

/// 车辆详情：档案、里程、电池、位置与快捷操作
struct VehicleDetailView: View {
    let vehicle: Vehicle

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showSettings = false
    @State private var showNavOptions = false

    private var battery: BatteryInfo? { model.batteries.first }

    var body: some View {
        SheetShell(title: "车辆详情", subtitle: vehicle.name, onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    profileCard
                    metricCard
                    batteryRows
                    locationCard
                    actionRows
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
        .sheetChrome()
        .sheet(isPresented: $showSettings) {
            VehicleSettingsView(vehicle: vehicle)
        }
        .confirmationDialog("选择导航应用", isPresented: $showNavOptions, titleVisibility: .visible) {
            if let coordinate = vehicle.coordinate {
                ForEach(NavigationLauncher.options(
                    lat: coordinate.latitude,
                    lon: coordinate.longitude,
                    name: vehicle.name
                )) { option in
                    Button(option.title) { option.action() }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 档案

    private var profileCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(vehicle.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(vehicle.isOnline ? Theme.green : Theme.tertiary)
                            .frame(width: 6, height: 6)
                        Text(vehicle.isOnline ? "在线" : "离线")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(vehicle.isOnline ? Theme.green : Theme.secondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background {
                        Capsule().fill((vehicle.isOnline ? Theme.green : Theme.tertiary).opacity(0.12))
                    }

                    Spacer(minLength: 0)

                    Button {
                        UIPasteboard.general.string = vehicle.vinNo
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text("复制 VIN")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.brand)
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                }

                Text(vehicle.vinNo)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 里程

    private var metricCard: some View {
        AppleCard {
            VStack(spacing: 14) {
                CardTitle(text: "里程", icon: "speedometer", tint: Theme.brand)

                HStack(spacing: 0) {
                    metric("总里程", String(format: "%.0f", vehicle.totalMileKm), "km")
                    divider
                    metric("本月", vehicle.monthMileage ?? "—", "km")
                    divider
                    metric("续航", "\(vehicle.rangeKm)", "km")
                    divider
                    metric("电量", "\(vehicle.soc)", "%")
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 0.5, height: 26)
    }

    // MARK: - 电池（没有数据的字段直接不显示）

    @ViewBuilder
    private var batteryRows: some View {
        let rows = batteryDetailRows
        if !rows.isEmpty {
            AppleCard {
                VStack(spacing: 10) {
                    CardTitle(
                        text: "电池",
                        icon: "bolt.batteryblock.fill",
                        tint: (battery?.isCharging ?? vehicle.isCharging) ? Theme.green : Theme.brand,
                        trailing: battery?.stateText
                    )

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                        InfoRow(title: item.0, value: item.1)
                    }
                }
            }
        }
    }

    private var batteryDetailRows: [(String, String)] {
        var rows: [(String, String)] = []

        let voltage = battery?.voltage ?? vehicle.voltage ?? 0
        if voltage > 0 {
            rows.append(("电压", String(format: "%.1f V", voltage)))
        }

        let temperature = battery?.temperature ?? vehicle.temperature ?? 0
        if temperature != 0 {
            rows.append(("温度", String(format: "%.0f ℃", temperature)))
        }

        let cycle = battery?.cycleCount ?? vehicle.cycleCount ?? 0
        if cycle > 0 {
            rows.append(("循环次数", "\(cycle) 次"))
        }

        if let level = battery?.level, level > 0 {
            rows.append(("剩余电量", "\(level)%"))
        }

        if let capacity = battery?.capacity, capacity > 0 {
            rows.append(("容量", String(format: "%.1f Ah", capacity)))
        }
        return rows
    }

    // MARK: - 位置

    private var locationCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(text: "位置", icon: "location.fill", tint: Theme.brand)

                if let coordinate = vehicle.coordinate {
                    Text(vehicle.address?.isEmpty == false ? vehicle.address! : "已上报坐标")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)

                    if let time = vehicle.locationTime, !time.isEmpty {
                        Text("\(time) 上报")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiary)
                    }

                    Button {
                        showNavOptions = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("导航到车辆")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Theme.brand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Theme.brand.opacity(0.10))
                        }
                    }
                    .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
                } else {
                    Text("车辆暂未上报位置")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    // MARK: - 操作

    private var actionRows: some View {
        AppleCard(padding: 0) {
            VStack(spacing: 0) {
                row(icon: "slider.horizontal.3", title: "车辆设置", detail: "限速与骑行辅助") {
                    showSettings = true
                }
                HairLine(inset: 52)
                row(icon: "arrow.clockwise", title: "刷新数据", detail: "重新读取云端状态") {
                    Task {
                        await model.refreshAll()
                        await model.loadTire(vin: vehicle.vinNo)
                    }
                }
            }
        }
    }

    private func row(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.995, brightness: 0))
    }
}

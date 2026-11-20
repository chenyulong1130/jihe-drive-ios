import SwiftUI

struct VehicleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var wallpaperStore: WallpaperStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var busy: String?
    @State private var toast: String?

    @State private var showMap = false
    @State private var showPicker = false
    @State private var showTheme = false
    @State private var showBattery = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if let vehicle = model.selectedVehicle {
                    hero(vehicle).staggerIn(0)
                    primaryAction(vehicle).staggerIn(1)
                    quickRail(vehicle).staggerIn(2)
                    if vehicle.soc <= 20 && !vehicle.isCharging && vehicle.isOnline {
                        lowBatteryNotice(vehicle).staggerIn(2)
                    }
                    batteryCard(vehicle).staggerIn(3)
                    mapCard(vehicle).staggerIn(4)
                    SectionHeader("我的骑行")
                    rideCard(vehicle).staggerIn(5)
                    SectionHeader("车辆信息")
                    infoCard(vehicle).staggerIn(6)
                    footer(vehicle)
                } else if model.loading {
                    loadingState
                } else {
                    emptyState
                }

                if let error = model.errorMessage {
                    SoftBanner(text: error, icon: "wifi.exclamationmark", tone: Theme.orange)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)
            .padding(.bottom, 118)
        }
        .refreshable { await refresh() }
        .overlay(alignment: .bottom) {
            if let message = toast {
                ToastView(text: message)
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showPicker) {
            VehiclePickerSheet()
        }
        .sheet(isPresented: $showTheme) {
            ThemeSheet()
        }
        .sheet(isPresented: $showBattery) {
            if let vehicle = model.selectedVehicle {
                BatterySheet(vehicle: vehicle)
            }
        }
        .sheet(isPresented: $showMap) {
            if let vehicle = model.selectedVehicle {
                TrackMapView(vehicle: vehicle)
            }
        }
        .task(id: model.selectedVehicle?.vinNo) {
            guard let vin = model.selectedVehicle?.vinNo else { return }
            await model.loadBattery(vin: vin)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // 只处理「后台 → 前台」，首次启动交给上面的 task
            guard oldPhase == .background, newPhase == .active else { return }
            Task { await refresh() }
        }
    }

    // MARK: - 主视觉

    private func hero(_ vehicle: Vehicle) -> some View {
        HeroStage(
            vehicle: vehicle,
            selection: themeStore.selection,
            videoURL: videoStore.url,
            videoPoster: videoStore.poster,
            photo: wallpaperStore.image,
            onPickVehicle: {
                if model.vehicles.count > 1 {
                    showPicker = true
                } else {
                    showToast("当前账号只有一台车辆")
                }
            },
            onOpenTheme: { showTheme = true }
        )
    }

    // MARK: - 主控

    private func primaryAction(_ vehicle: Vehicle) -> some View {
        PowerButton(
            locked: vehicle.isLocked,
            busy: busy == "lock",
            enabled: busy == nil
        ) {
            let queued = !vehicle.isOnline
            run(
                "lock",
                success: queued ? "车辆离线，指令已排队，联网后执行" : "指令已发送，等待车辆响应"
            ) {
                try await model.toggleLock(vehicle)
            }
        }
        .padding(.top, 12)
    }

    private func quickRail(_ vehicle: Vehicle) -> some View {
        HStack(spacing: 12) {
            quickTile(
                title: "寻车",
                hint: "闪灯鸣笛",
                icon: "light.beacon.max",
                key: "find"
            ) {
                try await model.findVehicle(vehicle)
            }

            quickTile(
                title: "坐垫",
                hint: "开启座桶",
                icon: "shippingbox",
                key: "cushion"
            ) {
                try await model.openCushion(vehicle)
            }

            quickTile(
                title: "电池",
                hint: model.batteries.first.map { "\($0.level)%" } ?? "查看详情",
                icon: "battery.75percent",
                key: nil
            ) {
                showBattery = true
            }
        }
        .padding(.top, 12)
    }

    private func quickTile(
        title: String,
        hint: String,
        icon: String,
        key: String?,
        action: @escaping () async throws -> Void
    ) -> some View {
        Button {
            guard let key else { return }
            run(key, action: action)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle()
                        .fill(Theme.surfaceAlt)
                        .frame(width: 32, height: 32)

                    if let key, busy == key {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.brand)
                    }
                }

                Spacer(minLength: 8)

                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.label)

                Text(hint)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 96)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 1, brightness: 0.01, sink: 1.2))
        .disabled(busy != nil && key != nil)
    }

    // MARK: - 电池卡

    private func batteryCard(_ vehicle: Vehicle) -> some View {
        let battery = model.batteries.first
        let tint = (battery?.isCharging ?? vehicle.isCharging) ? Theme.green : Theme.brand

        return Button {
            showBattery = true
        } label: {
            VStack(spacing: 12) {
                CardTitle(
                    text: "电池状态",
                    icon: "bolt.batteryblock",
                    tint: tint,
                    trailing: "详情"
                )

                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RingProgress(
                            progress: Double(min(max(vehicle.soc, 0), 100)) / 100,
                            color: tint,
                            track: Color(uiColor: .tertiarySystemFill),
                            lineWidth: 6,
                            size: 58
                        )
                        Text("\(min(max(vehicle.soc, 0), 100))%")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(vehicle.isCharging ? "正在充电" : "续航 \(vehicle.rangeKm) km")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.label)

                        HStack(spacing: 16) {
                            compactStat(title: "电压", value: battery.map { String(format: "%.1f V", $0.voltage) } ?? "--")
                            compactStat(title: "温度", value: battery.map { String(format: "%.0f ℃", $0.temperature) } ?? "--")
                            compactStat(title: "循环", value: cycleText(battery))
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
        .padding(.top, 12)
    }

    private func cycleText(_ battery: BatteryInfo?) -> String {
        guard let battery, let cycle = battery.cycleCount else { return "--" }
        return "\(cycle)"
    }

    private func compactStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.label)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: - 位置

    private func mapCard(_ vehicle: Vehicle) -> some View {
        ZStack(alignment: .bottom) {
            mapBody(vehicle)

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text(locationLabel(vehicle))
                        .font(Theme.caption)
                }
                .foregroundStyle(Theme.label)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(.regularMaterial))

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("展开")
                        .font(Theme.captionStrong)
                }
                .foregroundStyle(Theme.brand)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(.regularMaterial))
            }
            .padding(10)
        }
        .frame(height: 164)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onTapGesture { showMap = true }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func mapBody(_ vehicle: Vehicle) -> some View {
        if let coordinate = vehicle.coordinate {
            VehicleMapView(coordinate: coordinate, interactive: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        } else {
            ZStack {
                Theme.surfaceAlt
                VStack(spacing: 6) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                    Text("车辆未上报位置")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private func locationLabel(_ vehicle: Vehicle) -> String {
        guard vehicle.coordinate != nil else { return "无位置" }
        return shortTime(vehicle.locationTime)
    }

    // MARK: - 骑行

    private func rideCard(_ vehicle: Vehicle) -> some View {
        AppleCard {
            VStack(spacing: 14) {
                CardTitle(text: "我的骑行", trailing: "本月")

                HStack(spacing: 12) {
                    MetricChip(
                        title: "本月里程",
                        value: vehicle.monthMileage ?? "--",
                        unit: "km"
                    )
                    MetricChip(
                        title: "总里程",
                        value: String(format: "%.0f", vehicle.totalMileKm),
                        unit: "km"
                    )
                    MetricChip(
                        title: "可行驶",
                        value: "\(vehicle.rangeKm)",
                        unit: "km"
                    )
                }
            }
        }
    }

    private func infoCard(_ vehicle: Vehicle) -> some View {
        AppleCard {
            VStack(spacing: 12) {
                InfoRow(title: "VIN", value: vehicle.vinNo, mono: true)
                HairLine()
                InfoRow(title: "状态", value: vehicle.isOnline ? "在线" : "离线", valueColor: vehicle.isOnline ? Theme.green : Theme.secondary)
                HairLine()
                InfoRow(title: "车锁", value: vehicle.isLocked ? "已上锁" : "未上锁", valueColor: vehicle.isLocked ? Theme.label : Theme.orange)
                HairLine()
                InfoRow(title: "充电", value: vehicle.isCharging ? "充电中" : "未充电", valueColor: vehicle.isCharging ? Theme.green : Theme.label)
                HairLine()
                InfoRow(title: "信号", value: "\(vehicle.signalLevel) 级")
                HairLine()
                InfoRow(title: "最后位置", value: coordinateText(vehicle))
            }
        }
    }

    private func footer(_ vehicle: Vehicle) -> some View {
        Text("总里程 \(String(format: "%.0f", vehicle.totalMileKm)) km · 数据来自极核云端")
            .font(Theme.footnote)
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
    }

    // MARK: - 状态

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在读取车辆")
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 160)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.car")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.tertiary)
            Text("账号下还没有车辆")
                .font(Theme.headline)
                .foregroundStyle(Theme.label)
            Text("请先在极核官方 App 绑定车辆")
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 150)
    }

    // MARK: - 刷新

    private func refresh() async {
        await model.loadVehicles()
        if let vin = model.selectedVehicle?.vinNo {
            await model.loadBattery(vin: vin)
        }
    }

    private func lowBatteryNotice(_ vehicle: Vehicle) -> some View {
        SoftBanner(
            text: "电量仅剩 \(vehicle.soc)%，建议尽快充电",
            icon: "battery.25percent",
            tone: Theme.orange
        )
    }

    // MARK: - 工具

    private func coordinateText(_ vehicle: Vehicle) -> String {
        guard let coordinate = vehicle.coordinate else { return "暂无坐标" }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private func shortTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "--" }
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return String(raw.prefix(11)) }
        let date = parts[0].count >= 10 ? parts[0].suffix(5) : parts[0]
        let time = parts[1].count >= 5 ? parts[1].prefix(5) : parts[1]
        return "\(date) \(time)"
    }

    private func run(
        _ key: String,
        success: String = "指令已发送，等待车辆响应",
        action: @escaping () async throws -> Void
    ) {
        busy = key
        Task {
            do {
                try await action()
                showToast(success)
            } catch {
                showToast(error.localizedDescription)
            }
            busy = nil
        }
    }

    private func showToast(_ text: String) {
        withAnimation(Motion.spring) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(Motion.quick) { toast = nil }
        }
    }
}

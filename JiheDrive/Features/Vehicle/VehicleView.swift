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
    @State private var show3D = false
    @State private var showReplay = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if let vehicle = model.selectedVehicle {
                    hero(vehicle).staggerIn(0)
                    actionPanel(vehicle).staggerIn(1)
                    if vehicle.soc <= 20 && !vehicle.isCharging && vehicle.isOnline {
                        lowBatteryNotice(vehicle).staggerIn(1)
                    }
                    batteryTireCard(vehicle).staggerIn(2)
                    mapCard(vehicle).staggerIn(3)
                    SectionHeader("我的骑行")
                    rideCard(vehicle).staggerIn(4)
                    SectionHeader("车辆信息")
                    infoCard(vehicle).staggerIn(5)
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
            .padding(.top, 6)
            .padding(.bottom, 120)
        }
        .refreshable { await model.refreshAll() }
        .overlay(alignment: .bottom) {
            if let message = toast {
                ToastView(text: message)
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showPicker) { VehiclePickerSheet() }
        .sheet(isPresented: $showTheme) { ThemeSheet() }
        .sheet(isPresented: $showBattery) {
            if let vehicle = model.selectedVehicle { BatterySheet(vehicle: vehicle) }
        }
        .sheet(isPresented: $showMap) {
            if let vehicle = model.selectedVehicle { TrackMapView(vehicle: vehicle) }
        }
        .sheet(isPresented: $show3D) {
            if let vehicle = model.selectedVehicle { Vehicle3DSheet(vehicle: vehicle) }
        }
        .fullScreenCover(isPresented: $showReplay) {
            if let vehicle = model.selectedVehicle { RideReplayView(vehicle: vehicle) }
        }
        .task(id: model.selectedVehicle?.vinNo) {
            guard let vin = model.selectedVehicle?.vinNo else { return }
            await model.loadBattery(vin: vin)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase == .background, newPhase == .active else { return }
            Task { await model.refreshAll() }
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

    // MARK: - 操作区

    private func actionPanel(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 12) {
            PowerButton(
                locked: vehicle.isLocked,
                busy: busy == "lock",
                enabled: busy == nil
            ) {
                let queued = !vehicle.isOnline
                run(
                    "lock",
                    success: queued ? "车辆离线，指令已排队" : "指令已发送，等待车辆响应"
                ) {
                    try await model.toggleLock(vehicle)
                }
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    actionTile(icon: "light.beacon.max.fill", title: "寻车", tint: Theme.orange, key: "find") {
                        try await model.findVehicle(vehicle)
                    }
                    actionTile(icon: "shippingbox.fill", title: "开坐垫", tint: Theme.teal, key: "cushion") {
                        try await model.openCushion(vehicle)
                    }
                }
                HStack(spacing: 10) {
                    actionTile(
                        icon: "battery.75percent",
                        title: "电池",
                        tint: Theme.green,
                        key: nil,
                        hint: model.batteries.first.map { "\($0.level)%" }
                    ) {
                        showBattery = true
                    }
                    actionTile(icon: "cube.fill", title: "3D 看车", tint: Theme.indigo, key: nil) {
                        show3D = true
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.45), lineWidth: 0.5)
        )
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 8)
        .padding(.top, 12)
    }

    private func actionTile(
        icon: String,
        title: String,
        tint: Color,
        key: String?,
        hint: String? = nil,
        action: @escaping () async throws -> Void
    ) -> some View {
        Button {
            guard let key else {
                runLocal(action)
                return
            }
            run(key, action: action)
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                        .frame(width: 28, height: 28)

                    if let key, busy == key {
                        ProgressView().scaleEffect(0.55)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    if let hint {
                        Text(hint)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.surfaceAlt)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0.01))
        .disabled(busy != nil && key != nil)
    }

    // MARK: - 电池与胎压

    private func batteryTireCard(_ vehicle: Vehicle) -> some View {
        let battery = model.batteries.first
        let tint = (battery?.isCharging ?? vehicle.isCharging) ? Theme.green : Theme.brand

        return AppleCard {
            VStack(spacing: 14) {
                CardTitle(
                    text: "电池与胎压",
                    icon: "bolt.batteryblock.fill",
                    tint: tint,
                    trailing: battery?.stateText ?? "详情"
                )

                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        RingProgress(
                            progress: Double(min(max(vehicle.soc, 0), 100)) / 100,
                            color: tint,
                            track: Color(uiColor: .tertiarySystemFill),
                            lineWidth: 6,
                            size: 62
                        )
                        VStack(spacing: 0) {
                            Text("\(min(max(vehicle.soc, 0), 100))%")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.label)
                                .monospacedDigit()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 18) {
                            compactStat(title: "电压", value: battery.map { String(format: "%.1f V", $0.voltage) } ?? "--")
                            compactStat(title: "温度", value: battery.map { String(format: "%.0f ℃", $0.temperature) } ?? "--")
                            compactStat(title: "循环", value: cycleText(battery))
                        }

                        HairLine()

                        HStack(spacing: 14) {
                            tireColumn(title: "前轮", kpa: vehicle.tireFrontKpa)
                            tireColumn(title: "后轮", kpa: vehicle.tireRearKpa)
                        }
                    }

                    Spacer(minLength: 0)
                }

                Button {
                    showBattery = true
                } label: {
                    HStack(spacing: 6) {
                        Text("查看电池详情")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Theme.brand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.brand.opacity(0.09))
                    )
                }
                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
            }
        }
        .padding(.top, 12)
    }

    private func tireColumn(title: String, kpa: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Text(tireValue(kpa))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tireTint(kpa))
                    .monospacedDigit()
                Text("bar")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.surfaceAlt)
                        .frame(height: 5)
                    Capsule()
                        .fill(tireTint(kpa))
                        .frame(width: max(4, proxy.size.width * tireRatio(kpa)), height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity)
    }

    private func tireValue(_ kpa: Double?) -> String {
        guard let kpa else { return "--" }
        return String(format: "%.1f", kpa / 100)
    }

    private func tireRatio(_ kpa: Double?) -> CGFloat {
        guard let kpa else { return 0 }
        return CGFloat(min(1, max(0.04, kpa / 320)))
    }

    private func tireTint(_ kpa: Double?) -> Color {
        guard let kpa else { return Theme.tertiary }
        if kpa < 180 { return Theme.red }
        if kpa < 210 || kpa > 290 { return Theme.orange }
        return Theme.green
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
                .font(.system(size: 14, weight: .medium))
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
                CardTitle(text: "骑行数据", trailing: "本月")

                HStack(spacing: 10) {
                    MetricChip(title: "本月里程", value: vehicle.monthMileage ?? "--", unit: "km")
                    MetricChip(title: "总里程", value: String(format: "%.0f", vehicle.totalMileKm), unit: "km")
                    MetricChip(title: "可行驶", value: "\(vehicle.rangeKm)", unit: "km")
                }

                Button {
                    showReplay = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("轨迹回放")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Theme.brand.opacity(0.09))
                    )
                }
                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
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

    private func lowBatteryNotice(_ vehicle: Vehicle) -> some View {
        SoftBanner(
            text: "电量仅剩 \(vehicle.soc)%，建议尽快充电",
            icon: "battery.25percent",
            tone: Theme.orange
        )
        .padding(.top, 12)
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

    /// 只做页面跳转的按钮，不发送指令
    private func runLocal(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { showToast(error.localizedDescription) }
        }
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

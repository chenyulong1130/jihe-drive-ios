import SwiftUI

struct VehicleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var wallpaperStore: WallpaperStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var model3D = VehicleModelLoader()

    @State private var busy: String?
    @State private var toast: String?

    @State private var showMap = false
    @State private var showPicker = false
    @State private var showTheme = false
    @State private var showBattery = false
    @State private var show3D = false
    @State private var showReplay = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if let vehicle = model.selectedVehicle {
                        hero(vehicle, proxy: proxy)
                        content(vehicle)
                    } else if model.loading {
                        loadingState
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 128)
            }
            .ignoresSafeArea(edges: .top)
            .refreshable { await model.refreshAll() }
        }
        .background(Theme.groupedBackground)
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
            model3D.load(model.selectedVehicle?.model3DURL)
            await model.loadBattery(vin: vin)
            await model.loadDetail(vin: vin)
            // 详情接口回来后才可能有 3D 模型地址
            model3D.load(model.selectedVehicle?.model3DURL)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase == .background, newPhase == .active else { return }
            Task { await model.refreshAll() }
        }
    }

    // MARK: - 主视觉

    private func hero(_ vehicle: Vehicle, proxy: GeometryProxy) -> some View {
        let fullHeight = proxy.size.height + proxy.safeAreaInsets.top

        return HeroStage(
            vehicle: vehicle,
            selection: themeStore.selection,
            videoURL: videoStore.url,
            videoPoster: videoStore.poster,
            photo: wallpaperStore.image,
            modelScene: model3D.scene,
            topInset: proxy.safeAreaInsets.top + 10,
            height: max(400, fullHeight * 0.56),
            cornerRadius: 30,
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

    // MARK: - 内容

    private func content(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 14) {
            actionCard(vehicle)
            batteryCard(vehicle)
            tireCard(vehicle)
            locationCard(vehicle)
            rideCard(vehicle)
            infoCard(vehicle)
            footer(vehicle)

            if let error = model.errorMessage {
                SoftBanner(text: error, icon: "wifi.exclamationmark", tone: Theme.orange)
            }
        }
        .padding(.horizontal, Theme.page)
        .padding(.top, 16)
    }

    // MARK: - 操作区

    private func actionCard(_ vehicle: Vehicle) -> some View {
        let locked = vehicle.isLocked

        return AppleCard(padding: 12) {
            VStack(spacing: 12) {
                Button {
                    let queued = !vehicle.isOnline
                    run(
                        "lock",
                        success: queued ? "车辆离线，指令已排队" : (locked ? "已发送解锁指令" : "已发送锁车指令")
                    ) {
                        try await model.toggleLock(vehicle)
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy == "lock" {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: locked ? "lock.open.fill" : "lock.fill")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        Text(locked ? "一键解锁" : "点击锁车")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: locked
                                        ? [Color(hex: 0x0A84FF), Color(hex: 0x0066E0)]
                                        : [Color(hex: 0xFF9F0A), Color(hex: 0xF07C00)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0.02))
                .disabled(busy != nil)

                HStack(spacing: 0) {
                    quickItem(icon: "light.beacon.max.fill", title: "寻车", tint: Theme.orange) {
                        run("find") { try await model.findVehicle(vehicle) }
                    }
                    quickItem(icon: "shippingbox.fill", title: "开坐垫", tint: Theme.teal) {
                        run("cushion") { try await model.openCushion(vehicle) }
                    }
                    quickItem(
                        icon: "battery.75percent",
                        title: "电池",
                        tint: Theme.green,
                        detail: model.batteries.first.map { "\($0.level)%" }
                    ) {
                        showBattery = true
                    }
                    quickItem(icon: "cube.transparent.fill", title: "3D 看车", tint: Theme.indigo) {
                        show3D = true
                    }
                }
            }
        }
    }

    private func quickItem(
        icon: String,
        title: String,
        tint: Color,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.13))
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(detail ?? " ")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
        .disabled(busy != nil)
    }

    // MARK: - 电池

    private func batteryCard(_ vehicle: Vehicle) -> some View {
        let battery = model.batteries.first
        let charging = battery?.isCharging ?? vehicle.isCharging
        let tint = charging ? Theme.green : Theme.brand
        let level = min(max(battery?.level ?? vehicle.soc, 0), 100)

        return AppleCard(onTap: { showBattery = true }) {
            VStack(spacing: 14) {
                CardTitle(
                    text: "电池",
                    icon: "bolt.batteryblock.fill",
                    tint: tint,
                    trailing: battery?.stateText ?? (charging ? "充电中" : "详情")
                )

                HStack(spacing: 18) {
                    ZStack {
                        RingProgress(
                            progress: Double(level) / 100,
                            color: tint,
                            track: Color(uiColor: .tertiarySystemFill),
                            lineWidth: 7,
                            size: 78
                        )
                        VStack(spacing: -2) {
                            Text("\(level)")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Theme.label)
                                .monospacedDigit()
                            Text("%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        statRow("续航", value: "\(vehicle.rangeKm) km")
                        statRow("电压", value: voltageText(battery, vehicle))
                        statRow("温度", value: temperatureText(battery, vehicle))
                        statRow("循环", value: cycleText(battery, vehicle))
                    }

                    Spacer(minLength: 0)
                }

                if let hint = batteryHint(vehicle) {
                    SoftBanner(text: hint, icon: "exclamationmark.circle.fill", tone: Theme.orange)
                }
            }
        }
    }

    private func statRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func voltageText(_ battery: BatteryInfo?, _ vehicle: Vehicle) -> String {
        let value = (battery?.voltage ?? vehicle.voltage) ?? 0
        guard value > 0 else { return "—" }
        return String(format: "%.1f V", value)
    }

    private func temperatureText(_ battery: BatteryInfo?, _ vehicle: Vehicle) -> String {
        let value = (battery?.temperature ?? vehicle.temperature) ?? 0
        guard value != 0 else { return "—" }
        return String(format: "%.0f ℃", value)
    }

    private func cycleText(_ battery: BatteryInfo?, _ vehicle: Vehicle) -> String {
        if let cycle = battery?.cycleCount, cycle > 0 { return "\(cycle) 次" }
        if let cycle = vehicle.cycleCount, cycle > 0 { return "\(cycle) 次" }
        return "—"
    }

    private func batteryHint(_ vehicle: Vehicle) -> String? {
        if vehicle.soc <= 20 && !vehicle.isCharging && vehicle.isOnline {
            return "电量仅剩 \(vehicle.soc)%，建议尽快充电"
        }
        return nil
    }

    // MARK: - 胎压

    private func tireCard(_ vehicle: Vehicle) -> some View {
        AppleCard {
            VStack(spacing: 14) {
                CardTitle(
                    text: "胎压",
                    icon: "circle.dashed",
                    tint: Theme.indigo,
                    trailing: tireStatus(vehicle)
                )

                HStack(spacing: 12) {
                    tireColumn(title: "前轮", kpa: vehicle.tireFrontKpa)
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 0.5, height: 54)
                    tireColumn(title: "后轮", kpa: vehicle.tireRearKpa)
                }

                if !vehicle.hasTirePressure {
                    Text("该车型未上报胎压数据")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func tireColumn(title: String, kpa: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                if let kpa {
                    Text(String(format: "%.1f", kpa / 100))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tireTint(kpa))
                        .monospacedDigit()
                    Text("bar")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                } else {
                    Text("—")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.surfaceAlt)
                        .frame(height: 6)
                    Capsule()
                        .fill(tireTint(kpa))
                        .frame(width: max(6, proxy.size.width * tireRatio(kpa)), height: 6)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }

    private func tireStatus(_ vehicle: Vehicle) -> String {
        guard vehicle.hasTirePressure else { return "无数据" }
        let values = [vehicle.tireFrontKpa, vehicle.tireRearKpa].compactMap { $0 }
        if values.contains(where: { $0 < 180 }) { return "偏低" }
        if values.contains(where: { $0 < 210 || $0 > 290 }) { return "注意" }
        return "正常"
    }

    private func tireRatio(_ kpa: Double?) -> CGFloat {
        guard let kpa else { return 0.02 }
        return CGFloat(min(1, max(0.04, kpa / 320)))
    }

    private func tireTint(_ kpa: Double?) -> Color {
        guard let kpa else { return Theme.tertiary }
        if kpa < 180 { return Theme.red }
        if kpa < 210 || kpa > 290 { return Theme.orange }
        return Theme.green
    }

    // MARK: - 位置

    private func locationCard(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                mapBody(vehicle)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text(locationLabel(vehicle))
                        .font(Theme.caption)
                }
                .foregroundStyle(Theme.label)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(.regularMaterial))
                .padding(10)
            }

            HStack(spacing: 8) {
                Text("车辆位置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                Text("查看地图")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.brand)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.brand)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 20, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { showMap = true }
    }

    @ViewBuilder
    private func mapBody(_ vehicle: Vehicle) -> some View {
        if let coordinate = vehicle.coordinate {
            VehicleMapView(coordinate: coordinate, interactive: false)
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
                CardTitle(text: "骑行", icon: "figure.outdoor.cycle", tint: Theme.brand, trailing: "本月")

                HStack(spacing: 0) {
                    rideStat(title: "本月里程", value: vehicle.monthMileage ?? "—", unit: "km")
                    rideDivider
                    rideStat(title: "总里程", value: String(format: "%.0f", vehicle.totalMileKm), unit: "km")
                    rideDivider
                    rideStat(title: "可行驶", value: "\(vehicle.rangeKm)", unit: "km")
                }

                Button {
                    showReplay = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("轨迹回放")
                            .font(.system(size: 14, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Theme.brand.opacity(0.08))
                    }
                }
                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
            }
        }
    }

    private func rideStat(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var rideDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 0.5, height: 26)
    }

    // MARK: - 车辆信息

    private func infoCard(_ vehicle: Vehicle) -> some View {
        AppleCard {
            VStack(spacing: 0) {
                CardTitle(text: "车辆信息")
                    .padding(.bottom, 12)

                InfoRow(title: "VIN", value: vehicle.vinNo, mono: true)
                HairLine().padding(.vertical, 10)
                InfoRow(
                    title: "状态",
                    value: vehicle.isOnline ? "在线" : "离线",
                    valueColor: vehicle.isOnline ? Theme.green : Theme.secondary
                )
                HairLine().padding(.vertical, 10)
                InfoRow(title: "信号", value: "\(vehicle.signalLevel) 级")
                HairLine().padding(.vertical, 10)
                InfoRow(title: "最后定位", value: coordinateText(vehicle))
            }
        }
    }

    private func footer(_ vehicle: Vehicle) -> some View {
        Text("数据来自极核云端 · 下拉刷新")
            .font(Theme.caption)
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
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

    // MARK: - 工具

    private func coordinateText(_ vehicle: Vehicle) -> String {
        guard let coordinate = vehicle.coordinate else { return "暂无坐标" }
        return String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    private func shortTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
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

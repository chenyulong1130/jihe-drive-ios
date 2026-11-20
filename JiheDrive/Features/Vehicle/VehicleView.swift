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
    @State private var themeFocus: ThemeFocus = .none
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
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if let message = toast {
                ToastView(text: message)
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showPicker) { VehiclePickerSheet() }
        .sheet(isPresented: $showTheme, onDismiss: { themeFocus = .none }) {
            ThemeSheet(focus: themeFocus)
        }
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
            RideHomeView(showsClose: true)
        }
        .task(id: model.selectedVehicle?.vinNo) {
            guard let vin = model.selectedVehicle?.vinNo else { return }
            model3D.load(model.selectedVehicle?.model3DURL)
            async let battery: Void = model.loadBattery(vin: vin)
            async let detail: Void = model.loadDetail(vin: vin)
            async let tire: Void = model.loadTire(vin: vin)
            _ = await (battery, detail, tire)
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
            tireFrontBar: model.tire?.frontBar,
            tireRearBar: model.tire?.rearBar,
            topInset: proxy.safeAreaInsets.top + 10,
            height: max(430, fullHeight * 0.58),
            cornerRadius: 30,
            onPickVehicle: {
                if model.vehicles.count > 1 {
                    showPicker = true
                } else {
                    showToast("当前账号只有一台车辆")
                }
            },
            onOpenWallpaper: {
                themeFocus = .wallpaper
                showTheme = true
            },
            onOpenTheme: {
                themeFocus = .theme
                showTheme = true
            }
        )
    }

    // MARK: - 内容（连续面板，无卡片、无阴影）

    private func content(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 0) {
            HairLine()
            actionBlock(vehicle)
            HairLine()
            batteryBlock(vehicle)
            HairLine()
            locationBlock(vehicle)
            HairLine()
            rideBlock(vehicle)
            HairLine()
            infoBlock(vehicle)

            if let error = model.errorMessage {
                SoftBanner(text: error, icon: "wifi.exclamationmark", tone: Theme.orange)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
            }

            Text("数据来自极核云端 · 下拉刷新")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiary)
                .padding(.vertical, 18)
        }
    }

    // MARK: - 操作

    private func actionBlock(_ vehicle: Vehicle) -> some View {
        let locked = vehicle.isLocked

        return VStack(spacing: 14) {
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
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private func quickItem(
        icon: String,
        title: String,
        tint: Color,
        detail: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(detail ?? " ")
                    .font(.system(size: 9.5, weight: .medium))
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

    private func batteryBlock(_ vehicle: Vehicle) -> some View {
        let battery = model.batteries.first
        let charging = battery?.isCharging ?? vehicle.isCharging
        let level = min(max(battery?.level ?? vehicle.soc, 0), 100)
        let tint = charging ? Theme.green : Theme.brand

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text("电池")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(battery?.stateText ?? (charging ? "充电中" : "正常"))
                    .font(Theme.caption)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text("详情")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }

            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RingProgress(
                        progress: Double(level) / 100,
                        color: tint,
                        track: Theme.surfaceAlt,
                        lineWidth: 5,
                        size: 54
                    )
                    Text("\(level)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                }

                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        cell("续航", "\(vehicle.rangeKm) km")
                        cell("电压", voltageText(battery, vehicle))
                    }
                    HStack(spacing: 12) {
                        cell("温度", temperatureText(battery, vehicle))
                        cell("循环", cycleText(battery, vehicle))
                    }
                }
            }

            if let hint = batteryHint(vehicle) {
                SoftBanner(text: hint, icon: "exclamationmark.circle.fill", tone: Theme.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onTapGesture { showBattery = true }
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.label)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 位置

    private func locationBlock(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text("车辆位置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Spacer(minLength: 0)
                Text(locationLabel(vehicle))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }

            mapBody(vehicle)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
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
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                    Text("车辆未上报位置")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    // MARK: - 骑行

    private func rideBlock(_ vehicle: Vehicle) -> some View {
        Button {
            showReplay = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("骑行")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    HStack(spacing: 12) {
                        Text("本月 \(vehicle.monthMileage ?? "—") km")
                        Text("总 \(String(format: "%.0f", vehicle.totalMileKm)) km")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                }

                Spacer(minLength: 0)

                HStack(spacing: 5) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 9, weight: .bold))
                    Text("骑行记录")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.brand)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background {
                    Capsule(style: .continuous).fill(Theme.brand.opacity(0.10))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.995, brightness: 0))
    }

    // MARK: - 车辆信息

    private func infoBlock(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(vehicle.isOnline ? Theme.green : Theme.tertiary)
                        .frame(width: 6, height: 6)
                    Text(vehicle.isOnline ? "在线" : "离线")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(vehicle.isOnline ? Theme.green : Theme.secondary)
                }
                Text("信号 \(vehicle.signalLevel) 级")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Text(shortTime(vehicle.locationTime))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }

            Text(vehicle.vinNo)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 电池文案

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

    private func locationLabel(_ vehicle: Vehicle) -> String {
        guard vehicle.coordinate != nil else { return "无位置" }
        if let address = vehicle.address, !address.isEmpty { return address }
        return shortTime(vehicle.locationTime)
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

import SwiftUI

struct VehicleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var wallpaperStore: WallpaperStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var model3D = VehicleModelLoader()
    @State private var heroGLB: URL?

    @State private var busy: String?
    @State private var toast: String?

    @State private var todaySummary: RideTrackService.DaySummary?
    @State private var latestTrack: RideTrack?

    @State private var showMap = false
    @State private var showPicker = false
    @State private var showTheme = false
    @State private var themeFocus: ThemeFocus = .none
    @State private var showBattery = false
    @State private var show3D = false
    @State private var showDetail = false
    @State private var showSettings = false
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
        .sheet(isPresented: $showDetail) {
            if let vehicle = model.selectedVehicle { VehicleDetailView(vehicle: vehicle) }
        }
        .sheet(isPresented: $showSettings) {
            if let vehicle = model.selectedVehicle { VehicleSettingsView(vehicle: vehicle) }
        }
        .fullScreenCover(isPresented: $showReplay) {
            RideHomeView(showsClose: true)
        }
        .task(id: model.selectedVehicle?.vinNo) {
            guard let vin = model.selectedVehicle?.vinNo else { return }
            await loadHeroModel()
            async let battery: Void = model.loadBattery(vin: vin)
            async let detail: Void = model.loadDetail(vin: vin)
            async let tire: Void = model.loadTire(vin: vin)
            _ = await (battery, detail, tire)
            await loadHeroModel()
            await loadRideSummary(vin: vin)
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
            modelGLBFile: heroGLB,
            tireFrontBar: model.tire?.frontBar,
            tireRearBar: model.tire?.rearBar,
            topInset: proxy.safeAreaInsets.top + 10,
            height: max(430, fullHeight * 0.56),
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
            },
            onOpenCushion: {
                run("cushion") { try await model.openCushion(vehicle) }
            }
        )
    }

    /// glb 走 model-viewer，其余格式交给 SceneKit
    private func loadHeroModel() async {
        guard let vehicle = model.selectedVehicle, let url = vehicle.model3DURL else { return }
        if vehicle.isGLBModel {
            if heroGLB == nil {
                heroGLB = try? await GLBModelStore.localFile(for: url)
            }
        } else {
            model3D.load(url)
        }
    }

    private func loadRideSummary(vin: String) async {
        todaySummary = await RideTrackService.daySummary(vin: vin)
        latestTrack = await RideTrackService.tracks(vin: vin, days: 7, pageSize: 1)?.first
    }

    // MARK: - 内容

    private func content(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 0) {
            actionStrip(vehicle)
            duoRow(vehicle)
            batteryStrip(vehicle)
            infoStrip(vehicle)

            if let error = model.errorMessage {
                SoftBanner(text: error, icon: "wifi.exclamationmark", tone: Theme.orange)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            Text("数据来自极核云端 · 下拉刷新")
                .font(Theme.caption)
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 14)
                .padding(.bottom, 8)
        }
    }

    // MARK: - 寻车 / 一键解锁 / 设置

    private func actionStrip(_ vehicle: Vehicle) -> some View {
        HStack(alignment: .top, spacing: 10) {
            sideAction(icon: "light.beacon.max.fill", title: "寻车", tint: Theme.orange) {
                run("find") { try await model.findVehicle(vehicle) }
            }

            powerControl(vehicle)

            sideAction(icon: "slider.horizontal.3", title: "设置", tint: Theme.brand) {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private func sideAction(
        icon: String,
        title: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(tint.opacity(0.10))
                        .frame(width: 54, height: 54)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.label)
            }
            .frame(width: 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.93, brightness: 0))
        .disabled(busy != nil)
        .padding(.top, 9)
    }

    private func powerControl(_ vehicle: Vehicle) -> some View {
        let locked = vehicle.isLocked
        let tint = locked ? Color(hex: 0x0A84FF) : Color(hex: 0xFF9F0A)

        return Button {
            let queued = !vehicle.isOnline
            run(
                "lock",
                success: queued ? "车辆离线，指令已排队" : (locked ? "已发送解锁指令" : "已发送锁车指令")
            ) {
                try await model.toggleLock(vehicle)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: locked
                                    ? [Color(hex: 0x2E9BFF), Color(hex: 0x0066E0)]
                                    : [Color(hex: 0xFFB23A), Color(hex: 0xF07C00)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 74, height: 74)
                        .shadow(color: tint.opacity(0.28), radius: 14, x: 0, y: 7)

                    if busy == "lock" {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.9)
                    } else {
                        Image(systemName: locked ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }

                Text(locked ? "一键解锁" : "点击关锁")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.label)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.95, brightness: 0.01))
        .disabled(busy != nil)
    }

    // MARK: - 位置 / 骑行记录

    private func duoRow(_ vehicle: Vehicle) -> some View {
        HStack(spacing: 10) {
            locationMiniCard(vehicle)
            rideMiniCard(vehicle)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func locationMiniCard(_ vehicle: Vehicle) -> some View {
        Button {
            showMap = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("车辆位置")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Text("导航")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.brand)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.brand.opacity(0.7))
                }

                mapBody(vehicle)
                    .frame(height: 74)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)

                Text(locationLabel(vehicle))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surfaceAlt.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
    }

    private func rideMiniCard(_ vehicle: Vehicle) -> some View {
        Button {
            showReplay = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("骑行记录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(latestTrack.map { String(format: "%.1f", $0.mileage) } ?? "—")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                    Text("km")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
                Text("最近一次")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(todaySummary.map { String(format: "%.1f", $0.mileage) } ?? "—")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("今日里程")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(todaySummary.map { "\($0.minutes)" } ?? "—")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("今日时长")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surfaceAlt.opacity(0.55))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
    }

    @ViewBuilder
    private func mapBody(_ vehicle: Vehicle) -> some View {
        if let coordinate = vehicle.coordinate {
            VehicleMapView(coordinate: coordinate, interactive: false)
                .allowsHitTesting(false)
        } else {
            ZStack {
                Theme.surfaceAlt
                VStack(spacing: 4) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.tertiary)
                    Text("未上报位置")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    // MARK: - 电池

    private func batteryStrip(_ vehicle: Vehicle) -> some View {
        let battery = model.batteries.first
        let charging = battery?.isCharging ?? vehicle.isCharging
        let level = min(max(battery?.level ?? vehicle.soc, 0), 100)
        let tint = charging ? Theme.green : Theme.brand

        return Button {
            showBattery = true
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RingProgress(
                        progress: Double(level) / 100,
                        color: tint,
                        track: Theme.surfaceAlt,
                        lineWidth: 4,
                        size: 34
                    )
                    Text("\(level)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("电池")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text(battery?.stateText ?? (charging ? "充电中" : "正常"))
                            .font(.system(size: 11))
                            .foregroundStyle(tint)
                    }

                    Text(batterySummary(battery, vehicle))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.995, brightness: 0))
    }

    private func batterySummary(_ battery: BatteryInfo?, _ vehicle: Vehicle) -> String {
        var parts: [String] = ["续航 \(vehicle.rangeKm) km"]
        let voltage = battery?.voltage ?? vehicle.voltage ?? 0
        if voltage > 0 { parts.append(String(format: "%.1f V", voltage)) }
        let temperature = battery?.temperature ?? vehicle.temperature ?? 0
        if temperature != 0 { parts.append(String(format: "%.0f ℃", temperature)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - 车辆详情入口

    private func infoStrip(_ vehicle: Vehicle) -> some View {
        Button {
            showDetail = true
        } label: {
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

                Text("车辆详情")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.brand)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.995, brightness: 0))
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
        guard vehicle.coordinate != nil else { return "未上报位置" }
        if let address = vehicle.address, !address.isEmpty { return address }
        return shortTime(vehicle.locationTime)
    }

    private func shortTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "暂无上报时间" }
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

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
    @State private var showDashboardWallpaper = false
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
        .background(Theme.groupedBackground)
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
        .sheet(isPresented: $showDashboardWallpaper) {
            if let vehicle = model.selectedVehicle {
                DashboardWallpaperSheet(vehicle: vehicle)
            }
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
            videoURL: themeStore.resolvedVideoURL(local: videoStore.url),
            videoPoster: videoStore.poster,
            photo: wallpaperStore.image,
            modelScene: model3D.scene,
            modelGLBFile: heroGLB,
            tireFrontBar: model.tire?.frontBar,
            tireRearBar: model.tire?.rearBar,
            topInset: proxy.safeAreaInsets.top + 10,
            height: max(420, fullHeight * 0.52),
            onPickVehicle: {
                if model.vehicles.count > 1 {
                    showPicker = true
                } else {
                    showToast("当前账号只有一台车辆")
                }
            },
            onOpenDashboardWallpaper: {
                showDashboardWallpaper = true
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

    // MARK: - 内容面板

    private func content(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 14) {
            actionDock(vehicle)
            duoCards(vehicle)
            ridingCard(vehicle)
            batteryCard(vehicle)

            if let error = model.errorMessage {
                SoftBanner(text: error, icon: "wifi.exclamationmark", tone: Theme.orange)
            }

            Button {
                showDetail = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vehicle.isOnline ? Theme.green : Theme.tertiary)
                        .frame(width: 6, height: 6)
                    Text(vehicle.isOnline ? "车辆在线" : "车辆离线")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                    Text("·")
                        .foregroundStyle(Theme.tertiary)
                    Text("查看详情")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.brand)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.brand.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))

            Text("数据来自极核云端 · 下拉刷新")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 28,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 28,
                style: .continuous
            )
            .fill(Theme.groupedBackground)
            .shadow(color: Theme.cardShadow, radius: 16, x: 0, y: -4)
        }
        .padding(.top, -18)
    }

    // MARK: - 寻车 / 解锁 / 设置

    private func actionDock(_ vehicle: Vehicle) -> some View {
        HStack(alignment: .center, spacing: 10) {
            sideActionCard(
                icon: "light.beacon.max.fill",
                title: "寻车",
                hint: "轻点闪灯",
                tint: Theme.find,
                busy: busy == "find"
            ) {
                run("find") { try await model.findVehicle(vehicle) }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.55).onEnded { _ in
                    run("find", success: "已发送鸣笛闪灯") {
                        try await model.loudFindVehicle(vehicle)
                    }
                }
            )

            unlockButton(vehicle)

            sideActionCard(
                icon: "gearshape.fill",
                title: "设置",
                hint: "车辆控制",
                tint: Theme.brand,
                busy: false
            ) {
                showSettings = true
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.cardShadow, radius: 18, x: 0, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.55), lineWidth: 0.5)
        }
    }

    private func sideActionCard(
        icon: String,
        title: String,
        hint: String,
        tint: Color,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.22), tint.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                    if busy {
                        ProgressView()
                            .scaleEffect(0.85)
                            .tint(tint)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(tint)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Text(hint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(width: 76)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
        .disabled(self.busy != nil)
    }

    private func unlockButton(_ vehicle: Vehicle) -> some View {
        let locked = vehicle.isLocked
        let accent = locked ? Theme.unlock : Theme.lock
        let colors: [Color] = locked
            ? [accent.mixed(with: .white, amount: 0.18), accent]
            : [accent.mixed(with: .white, amount: 0.22), accent]

        return Button {
            let queued = !vehicle.isOnline
            run(
                "lock",
                success: queued ? "车辆离线，指令已排队" : (locked ? "已发送解锁指令" : "已发送锁车指令")
            ) {
                try await model.toggleLock(vehicle)
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 40, height: 40)
                    if busy == "lock" {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: locked ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 17, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(locked ? "点击解锁" : "点击关锁")
                        .font(.system(size: 16, weight: .bold))
                    Text(vehicle.isOnline ? (locked ? "车辆已上锁" : "车辆已解锁") : "离线 · 指令将排队")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.88)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(0.55)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 86)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.22), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    }
            }
            .shadow(color: accent.opacity(0.38), radius: 16, x: 0, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0.02))
        .disabled(busy != nil)
        .animation(Motion.spring, value: locked)
    }

    // MARK: - 位置 / 骑行

    private func duoCards(_ vehicle: Vehicle) -> some View {
        HStack(alignment: .top, spacing: 10) {
            locationCard(vehicle)
            rideCard(vehicle)
        }
    }

    private func locationCard(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button {
                    showMap = true
                } label: {
                    mapBody(vehicle)
                        .frame(height: 88)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 1, brightness: 0))

                if vehicle.coordinate != nil {
                    Button {
                        navigate(vehicle)
                    } label: {
                        Text("导航")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                    .padding(8)
                }
            }
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 16,
                style: .continuous
            ))

            Button {
                showMap = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                        Text("车辆位置")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.tertiary)
                    }

                    Text(locationLabel(vehicle))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 28, alignment: .topLeading)

                    Text(shortTime(vehicle.locationTime))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
        .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 4)
    }

    private func rideCard(_ vehicle: Vehicle) -> some View {
        Button {
            showReplay = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Text("骑行记录")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(latestTrack.map { String(format: "%.1f", $0.mileage) } ?? "—")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("最近 · km")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                        MiniSparkline(tint: Color(hex: 0xFF5A5F), seed: 1)
                            .frame(height: 18)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(latestTrack.map { "\($0.durationMinutes)" } ?? "—")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("时长 · min")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                        MiniSparkline(tint: Theme.brand, seed: 2)
                            .frame(height: 18)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HairLine()

                HStack(spacing: 0) {
                    rideStat(
                        value: todaySummary.map { String(format: "%.1f", $0.mileage) } ?? "—",
                        unit: "km",
                        label: "今日"
                    )
                    rideStat(
                        value: todaySummary.map { formatSpeed($0.maxSpeed) } ?? "—",
                        unit: "km/h",
                        label: "极速"
                    )
                    rideStat(
                        value: todaySummary.map { "\($0.minutes)" } ?? "—",
                        unit: "min",
                        label: "时长"
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            }
            .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
    }

    private func rideStat(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unit)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func mapBody(_ vehicle: Vehicle) -> some View {
        if let coordinate = vehicle.coordinate {
            VehicleMapView(coordinate: coordinate, interactive: false)
                .allowsHitTesting(false)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0xE8EEF5), Color(hex: 0xD5DFEA)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(spacing: 4) {
                    Image(systemName: "location.slash")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.tertiary)
                    Text("未上报位置")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    // MARK: - 我的骑行

    private func ridingCard(_ vehicle: Vehicle) -> some View {
        Button {
            showReplay = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "bicycle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Text("我的骑行")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Text("全部")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }

                HStack(spacing: 0) {
                    ridingMetric(
                        value: formatTodayDuration(),
                        label: "今日时长"
                    )
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 0.5, height: 36)
                    ridingMetric(
                        value: vehicle.monthMileage ?? "—",
                        unit: "km",
                        label: "本月里程"
                    )
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 0.5, height: 36)
                    ridingMetric(
                        value: String(format: "%.0f", vehicle.totalMileKm),
                        unit: "km",
                        label: "总里程"
                    )
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            }
            .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.985, brightness: 0))
    }

    private func ridingMetric(value: String, unit: String? = nil, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 电池

    private func batteryCard(_ vehicle: Vehicle) -> some View {
        let battery = model.batteries.first
        let charging = battery?.isCharging ?? vehicle.isCharging
        let level = min(max(battery?.level ?? vehicle.soc, 0), 100)
        let tint = charging ? Theme.green : Theme.brand

        return Button {
            showBattery = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RingProgress(
                        progress: Double(level) / 100,
                        color: tint,
                        track: Theme.surfaceAlt,
                        lineWidth: 3.5,
                        size: 38
                    )
                    Text("\(level)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("电池健康")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text(battery?.stateText ?? (charging ? "充电中" : "正常"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.12)))
                    }
                    Text(batterySummary(battery, vehicle))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            }
            .shadow(color: Theme.cardShadow, radius: 12, x: 0, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
    }

    private func batterySummary(_ battery: BatteryInfo?, _ vehicle: Vehicle) -> String {
        var parts: [String] = ["续航 \(vehicle.rangeKm) km"]
        let voltage = battery?.voltage ?? vehicle.voltage ?? 0
        if voltage > 0 { parts.append(String(format: "%.1f V", voltage)) }
        let temperature = battery?.temperature ?? vehicle.temperature ?? 0
        if temperature != 0 { parts.append(String(format: "%.0f ℃", temperature)) }
        return parts.joined(separator: " · ")
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

    private func navigate(_ vehicle: Vehicle) {
        guard let coordinate = vehicle.coordinate else { return }
        NavigationLauncher.openBest(
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            name: vehicle.name
        )
    }

    private func locationLabel(_ vehicle: Vehicle) -> String {
        guard vehicle.coordinate != nil else { return "未上报位置" }
        if let address = vehicle.address, !address.isEmpty { return address }
        return "已定位 · 点击查看地图"
    }

    private func shortTime(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "暂无上报时间" }
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return String(raw.prefix(11)) }
        let date = parts[0].count >= 10 ? parts[0].suffix(5) : parts[0]
        let time = parts[1].count >= 5 ? parts[1].prefix(5) : parts[1]
        return "上报 \(date) \(time)"
    }

    private func formatSpeed(_ speed: Double) -> String {
        guard speed > 0 else { return "—" }
        return String(format: "%.0f", speed)
    }

    private func formatTodayDuration() -> String {
        guard let minutes = todaySummary?.minutes, minutes > 0 else { return "—" }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 { return "\(h)时\(m)分" }
        return "\(m)分"
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

// MARK: - 装饰性微折线（骑行卡片氛围）

private struct MiniSparkline: View {
    var tint: Color
    var seed: Int

    var body: some View {
        GeometryReader { proxy in
            let pts = points(in: proxy.size)
            ZStack(alignment: .bottom) {
                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for point in pts.dropFirst() {
                        path.addLine(to: point)
                    }
                    if let last = pts.last {
                        path.addLine(to: CGPoint(x: last.x, y: proxy.size.height))
                        path.addLine(to: CGPoint(x: first.x, y: proxy.size.height))
                        path.closeSubpath()
                    }
                }
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.18), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard let first = pts.first else { return }
                    path.move(to: first)
                    for point in pts.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(tint.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let values: [CGFloat] = seed == 1
            ? [0.35, 0.55, 0.42, 0.78, 0.50, 0.88, 0.62]
            : [0.55, 0.40, 0.68, 0.48, 0.72, 0.58, 0.82]
        guard values.count > 1, size.width > 0, size.height > 0 else { return [] }
        return values.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height * (1 - value)
            return CGPoint(x: x, y: y)
        }
    }
}

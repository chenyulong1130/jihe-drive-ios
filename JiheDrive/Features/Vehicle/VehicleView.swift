import SwiftUI

struct VehicleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var wallpaperStore: WallpaperStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var model3D = VehicleModelLoader()
    @State private var heroGLB: URL?
    @State private var loadedModelVin: String?

    @State private var busy: String?
    @State private var toast: String?

    @State private var rideExtra: RideTrackService.RideExtra?
    @State private var rideLoading = false
    @State private var resolvedAddress: String?
    @StateObject private var signin = SigninStore()

    @State private var showMap = false
    @State private var showPicker = false
    @State private var showTheme = false
    @State private var themeFocus: ThemeFocus = .none
    @State private var showDashboardWallpaper = false
    @State private var showTire = false
    @State private var showBattery = false
    @State private var show3D = false
    @State private var showSettings = false
    @State private var showReplay = false
    @State private var pinningHero = false

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
            .scrollDisabled(pinningHero)
            .refreshable { await reloadPage() }
        }
        .ignoresSafeArea(edges: .top)
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
        .sheet(isPresented: $showTire) {
            if let vehicle = model.selectedVehicle { TireSheet(vehicle: vehicle) }
        }
        .sheet(isPresented: $showBattery) {
            if let vehicle = model.selectedVehicle { BatterySheet(vehicle: vehicle) }
        }
        .sheet(isPresented: $showMap) {
            if let vehicle = model.selectedVehicle {
                TrackMapView(vehicle: vehicle, address: locationLabel(vehicle))
            }
        }
        .sheet(isPresented: $show3D) {
            if let vehicle = model.selectedVehicle { Vehicle3DSheet(vehicle: vehicle) }
        }
        .sheet(isPresented: $showSettings) {
            if let vehicle = model.selectedVehicle { VehicleSettingsView(vehicle: vehicle) }
        }
        .fullScreenCover(isPresented: $showReplay) {
            RideHomeView(showsClose: true)
        }
        .task(id: model.selectedVehicle?.vinNo) {
            guard let vin = model.selectedVehicle?.vinNo else { return }
            if loadedModelVin != vin {
                heroGLB = nil
                model3D.clear()
                loadedModelVin = vin
            }
            resolvedAddress = nil
            async let ride: Void = loadRideSummary(vin: vin)
            async let battery: Void = model.loadBattery(vin: vin)
            async let detail: Void = model.loadDetail(vin: vin)
            async let tire: Void = model.loadTire(vin: vin)
            async let sign: Void = signin.refresh()
            async let addr: Void = resolveAddressIfNeeded()
            _ = await (ride, battery, detail, tire, sign, addr)
            await loadHeroModel()
            await signin.syncWidget(model: model, ride: rideExtra)
        }
        .onChange(of: model.selectedVehicle?.soc) { _, _ in
            WidgetSnapshot.publish(from: model, signin: signin, ride: rideExtra)
        }
        .onChange(of: model.selectedVehicle?.latitude) { _, _ in
            Task { await resolveAddressIfNeeded() }
        }
        .onChange(of: model.selectedVehicle?.longitude) { _, _ in
            Task { await resolveAddressIfNeeded() }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard oldPhase == .background, newPhase == .active else { return }
            Task { await reloadPage() }
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
            topInset: proxy.safeAreaInsets.top + 4,
            height: max(390, fullHeight * 0.46)
                + ((model.tire?.hasData == true) ? 36 : 0),
            onPickVehicle: {
                if model.vehicles.count > 1 {
                    showPicker = true
                } else {
                    showToast("当前账号只有一台车辆")
                }
            },
            onOpenDashboardWallpaper: {
                if vehicle.isCarMaster {
                    showDashboardWallpaper = true
                } else {
                    showToast("分享车辆暂不支持仪表壁纸")
                }
            },
            onOpenTheme: {
                themeFocus = .theme
                showTheme = true
            },
            onOpenCushion: {
                run("cushion") { try await model.openCushion(vehicle) }
            },
            onOpenTire: {
                showTire = true
            },
            onOpenBattery: {
                showBattery = true
            },
            onInteract: { pinningHero = $0 },
            canSwitchVehicle: model.vehicles.count > 1
        )
    }

    /// glb 走 model-viewer，其余格式交给 SceneKit；切车必须强制重载
    private func loadHeroModel() async {
        guard let vehicle = model.selectedVehicle else {
            heroGLB = nil
            model3D.clear()
            return
        }
        let vin = vehicle.vinNo
        guard let url = vehicle.model3DURL else {
            guard model.selectedVehicle?.vinNo == vin else { return }
            heroGLB = nil
            model3D.clear()
            return
        }
        if vehicle.isGLBModel {
            if heroGLB == nil {
                let file = try? await GLBModelStore.localFile(for: url)
                guard model.selectedVehicle?.vinNo == vin else { return }
                heroGLB = file
            }
        } else {
            heroGLB = nil
            model3D.load(url)
        }
    }

    private func reloadPage() async {
        await model.refreshAll()
        guard let vin = model.selectedVehicle?.vinNo else { return }
        await loadRideSummary(vin: vin)
        await resolveAddressIfNeeded()
        await signin.syncWidget(model: model, ride: rideExtra)
    }

    private func loadRideSummary(vin: String) async {
        if rideExtra == nil { rideLoading = true }
        defer { rideLoading = false }
        if let extra = await RideTrackService.rideExtra(vin: vin) {
            rideExtra = extra
        }
    }

    // MARK: - 内容面板

    private func content(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 8) {
            actionDock(vehicle)
            if vehicle.isShared {
                sharedHint
            }
            duoCards(vehicle)
            ridingCard(vehicle)

            if let error = model.errorMessage {
                SoftBanner(text: error, icon: "wifi.exclamationmark", tone: Theme.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // 对齐小程序：内容区直角，靠英雄区底部渐隐过渡，不要圆角「盖」在视频上
        .background(Theme.groupedBackground)
    }

    // MARK: - 寻车 / 解锁 / 设置

    private func actionDock(_ vehicle: Vehicle) -> some View {
        HStack(alignment: .center, spacing: 16) {
            sideActionCard(
                icon: "light.beacon.max.fill",
                title: "寻车",
                tint: Theme.label,
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
                icon: "slider.horizontal.3",
                title: "设置",
                tint: Theme.label,
                busy: false
            ) {
                if vehicle.isCarMaster {
                    showSettings = true
                } else {
                    showToast("分享车辆暂不支持车辆设置")
                }
            }
        }
    }

    private func sideActionCard(
        icon: String,
        title: String,
        tint: Color,
        busy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.separator.opacity(0.55), lineWidth: 0.5)
                    )
                    .shadow(color: Theme.cardShadow, radius: 10, y: 4)
                if busy {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
        .disabled(self.busy != nil)
        .accessibilityLabel(title)
    }

    /// 对齐 Flutter / 小程序：横向大按钮「一键解锁 / 点击关锁」
    private func unlockButton(_ vehicle: Vehicle) -> some View {
        let locked = vehicle.isLocked
        let online = vehicle.isOnline
        let loading = busy == "lock"
        let accent = locked ? Color(hex: 0x30D158) : Color(hex: 0xFF9F0A)

        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let queued = !online
            run(
                "lock",
                success: queued
                    ? "车辆离线，指令已排队"
                    : (locked ? "开锁指令已发送" : "关锁指令已发送")
            ) {
                try await model.toggleLock(vehicle)
            }
        } label: {
            ZStack {
                HStack {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 40, height: 40)
                        if loading {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    Spacer(minLength: 0)
                }

                VStack(spacing: 2) {
                    Text(loading ? "请求中…" : (locked ? "一键解锁" : "点击关锁"))
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(online ? (locked ? "车辆已关锁" : "车辆未关锁") : "离线 · 指令将排队")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent.opacity(0.88), accent.opacity(0.62)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.42), lineWidth: 1)
                    )
            }
            .shadow(color: accent.opacity(0.28), radius: 16, x: 0, y: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0.03))
        .disabled(busy != nil)
        .animation(Motion.spring, value: locked)
        .animation(Motion.quick, value: online)
        .accessibilityLabel(locked ? "一键解锁" : "点击关锁")
    }

    // MARK: - 位置 / 骑行

    private func duoCards(_ vehicle: Vehicle) -> some View {
        HStack(alignment: .top, spacing: 9) {
            locationCard(vehicle)
            rideCard(vehicle)
        }
        .frame(height: 198)
    }

    private func locationCard(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showMap = true
            } label: {
                ZStack(alignment: .topLeading) {
                    mapBody(vehicle)
                    Text("腾讯地图")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.75)))
                        .padding(6)
                }
                .frame(height: 128)
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 1, brightness: 0))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("车辆位置")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 4)
                    Button {
                        navigate(vehicle)
                    } label: {
                        Text("导航 ›")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(vehicle.coordinate == nil ? Theme.tertiary : Theme.brand)
                    }
                    .buttonStyle(.plain)
                    .disabled(vehicle.coordinate == nil)
                }
                Text(locationLabel(vehicle))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(locationTimeLabel(vehicle))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.top, 6)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: Theme.cardShadow, radius: 12, x: 0, y: 4)
    }

    private func rideCard(_ vehicle: Vehicle) -> some View {
        Button {
            showReplay = true
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("骑行记录")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.label)

                if rideLoading && rideExtra == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBar(width: 72, height: 12)
                        SkeletonBar(height: 22)
                        SkeletonBar(height: 22)
                        SkeletonBar(height: 28, radius: 8)
                    }
                } else {
                rideWaveRow(
                    value: rideExtra?.lastKm.map { String(format: "%.1f", $0) } ?? "—",
                    unit: "km",
                    label: "最近骑行",
                    tint: Color(hex: 0xFF3B64)
                )
                rideWaveRow(
                    value: rideExtra?.lastMin.map { RideTrackService.durationText($0) } ?? "—",
                    unit: "",
                    label: "耗时",
                    tint: Color(hex: 0x0B84FF)
                )

                Spacer(minLength: 2)

                HairLine()
                    .padding(.top, 2)

                HStack(spacing: 0) {
                    rideStat(
                        value: rideExtra?.todayKm.map { String(format: "%.1f", $0) } ?? "—",
                        unit: "km",
                        label: "今日里程"
                    )
                    rideStat(
                        value: rideExtra?.todayMaxSpeed.map { formatSpeed($0) } ?? "—",
                        unit: "km/h",
                        label: "速度"
                    )
                    rideStat(
                        value: rideExtra?.todayMin.map { RideTrackService.durationText($0) } ?? "—",
                        unit: "",
                        label: "时长"
                    )
                }
                .padding(.top, 4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.45), lineWidth: 0.5)
            }
            .shadow(color: Theme.cardShadow, radius: 12, x: 0, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
    }

    private func rideWaveRow(value: String, unit: String, label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.label)
                    }
                }
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary)
            }
            MiniSparkline(tint: tint, values: rideExtra?.recentKm ?? [])
                .frame(height: 20)
        }
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
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
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

    private var sharedHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("共享车辆")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text("仪表壁纸与车辆设置仅车主可用")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.orange.opacity(0.08))
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
                        value: vehicle.monthRideMinutes ?? formatTodayDuration(),
                        label: "本月时长"
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
                        value: vehicle.totalMileKm > 0 ? String(format: "%.0f", vehicle.totalMileKm) : "—",
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

    // MARK: - 状态

    private var loadingState: some View {
        VStack(spacing: 12) {
            SkeletonBar(height: 360, radius: 0)
            HStack(spacing: 9) {
                SkeletonBar(height: 198, radius: 16)
                SkeletonBar(height: 198, radius: 16)
            }
            .padding(.horizontal, 16)
            SkeletonBar(height: 88, radius: 16)
                .padding(.horizontal, 16)
        }
        .padding(.top, 0)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.car")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Theme.tertiary)
            Text("账号下还没有车辆")
                .font(Theme.headline)
                .foregroundStyle(Theme.label)
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
            name: locationLabel(vehicle)
        )
    }

    private func locationLabel(_ vehicle: Vehicle) -> String {
        guard vehicle.coordinate != nil else { return "暂无车辆定位" }
        if let address = AmapGeocode.readableAddress(resolvedAddress)
            ?? AmapGeocode.readableAddress(vehicle.address) {
            return address
        }
        return "定位中…"
    }

    private func locationTimeLabel(_ vehicle: Vehicle) -> String {
        guard vehicle.coordinate != nil else { return "" }
        if let raw = vehicle.locationTime, !raw.isEmpty {
            return "最近上报 \(raw)"
        }
        return "最近上报 --"
    }

    private func resolveAddressIfNeeded() async {
        guard let vehicle = model.selectedVehicle,
              let coord = vehicle.coordinate else {
            resolvedAddress = nil
            return
        }
        if let existing = AmapGeocode.readableAddress(vehicle.address) {
            resolvedAddress = existing
            return
        }
        if let cached = AmapGeocode.readableAddress(resolvedAddress) {
            return
        }
        resolvedAddress = await AmapGeocode.reverse(
            longitude: coord.longitude,
            latitude: coord.latitude
        )
    }

    private func formatSpeed(_ speed: Double) -> String {
        guard speed > 0 else { return "—" }
        return String(format: "%.0f", speed)
    }

    private func formatTodayDuration() -> String {
        guard let minutes = rideExtra?.todayMin, minutes > 0 else { return "—" }
        return RideTrackService.durationText(minutes)
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
    var values: [Double] = []

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
                        colors: [tint.opacity(0.22), tint.opacity(0.02)],
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
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let series: [CGFloat] = {
            let raw = values.filter { $0 >= 0 }
            if raw.count >= 2 {
                let peak = max(raw.max() ?? 1, 0.1)
                return raw.suffix(10).map { CGFloat($0 / peak) * 0.82 + 0.12 }
            }
            return [0.28, 0.46, 0.38, 0.62, 0.48, 0.78, 0.58]
        }()
        guard series.count > 1, size.width > 0, size.height > 0 else { return [] }
        return series.enumerated().map { index, value in
            let x = size.width * CGFloat(index) / CGFloat(series.count - 1)
            let y = size.height * (1 - value)
            return CGPoint(x: x, y: y)
        }
    }
}

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

    @State private var rideExtra: RideTrackService.RideExtra?
    @State private var resolvedAddress: String?
    @StateObject private var signin = SigninStore()

    @State private var showMap = false
    @State private var showPicker = false
    @State private var showTheme = false
    @State private var themeFocus: ThemeFocus = .none
    @State private var showDashboardWallpaper = false
    @State private var showTire = false
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
        .sheet(isPresented: $showTire) {
            if let vehicle = model.selectedVehicle { TireSheet(vehicle: vehicle) }
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
            // 切车先清掉上一台的模型，避免画面短暂串车
            heroGLB = nil
            model3D.clear()
            rideExtra = nil
            resolvedAddress = nil
            await loadHeroModel()
            async let battery: Void = model.loadBattery(vin: vin)
            async let detail: Void = model.loadDetail(vin: vin)
            async let tire: Void = model.loadTire(vin: vin)
            async let sign: Void = signin.refresh()
            _ = await (battery, detail, tire, sign)
            await loadHeroModel()
            await loadRideSummary(vin: vin)
            await resolveAddressIfNeeded()
            WidgetSnapshot.publish(from: model, signin: signin)
        }
        .onChange(of: model.selectedVehicle?.soc) { _, _ in
            WidgetSnapshot.publish(from: model, signin: signin)
        }
        .onChange(of: model.selectedVehicle?.latitude) { _, _ in
            Task { await resolveAddressIfNeeded() }
        }
        .onChange(of: model.selectedVehicle?.longitude) { _, _ in
            Task { await resolveAddressIfNeeded() }
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
            height: max(420, fullHeight * 0.50),
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
                if vehicle.isCarMaster {
                    themeFocus = .theme
                    showTheme = true
                } else {
                    showToast("分享车辆暂不支持主题")
                }
            },
            onOpenCushion: {
                run("cushion") { try await model.openCushion(vehicle) }
            },
            onOpenTire: {
                showTire = true
            }
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
            model3D.clear()
            let file = try? await GLBModelStore.localFile(for: url)
            guard model.selectedVehicle?.vinNo == vin else { return }
            heroGLB = file
        } else {
            heroGLB = nil
            model3D.load(url)
        }
    }

    private func loadRideSummary(vin: String) async {
        rideExtra = await RideTrackService.rideExtra(vin: vin)
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

            Button {
                showDetail = true
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vehicle.isOnline ? Theme.green : Theme.tertiary)
                            .frame(width: 7, height: 7)
                            .overlay {
                                if vehicle.isOnline {
                                    Circle()
                                        .stroke(Theme.green.opacity(0.35), lineWidth: 4)
                                        .frame(width: 11, height: 11)
                                }
                            }
                        Text(vehicle.isOnline ? "在线" : "离线")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(vehicle.isOnline ? Theme.green : Theme.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill((vehicle.isOnline ? Theme.green : Theme.tertiary).opacity(0.12))
                    )

                    Text(vehicle.isLocked ? "已关锁" : "未关锁")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(vehicle.isLocked ? Theme.secondary : Theme.orange)

                    Spacer(minLength: 0)

                    Text("车辆详情")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.brand)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.brand.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        // 对齐小程序：内容区直角，靠英雄区底部渐隐过渡，不要圆角「盖」在视频上
        .background(Theme.groupedBackground)
    }

    // MARK: - 寻车 / 解锁 / 设置

    private func actionDock(_ vehicle: Vehicle) -> some View {
        HStack(alignment: .center, spacing: 8) {
            sideActionCard(
                icon: "light.beacon.max.fill",
                title: "寻车",
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
                icon: "slider.horizontal.3",
                title: "设置",
                tint: vehicle.isCarMaster ? Theme.brand : Theme.tertiary,
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
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.surface)
                        .shadow(color: Theme.cardShadow, radius: 10, y: 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
                        )
                    if busy {
                        ProgressView().tint(tint)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(tint)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .frame(width: 58, height: 58)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.label)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
        .disabled(self.busy != nil)
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
            HStack(spacing: 10) {
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(loading ? "请求中…" : (locked ? "一键解锁" : "点击关锁"))
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(online ? (locked ? "车辆已关锁" : "车辆未关锁") : "离线 · 指令将排队")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.98), accent.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                            .padding(1)
                            .mask(
                                LinearGradient(
                                    colors: [.white, .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
            }
            .shadow(color: accent.opacity(0.32), radius: 16, x: 0, y: 8)
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
        HStack(alignment: .top, spacing: 8) {
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
                        .frame(height: 96)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            LinearGradient(
                                colors: [.clear, Theme.surface.opacity(0.92)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 1, brightness: 0))

                if vehicle.coordinate != nil {
                    Button {
                        navigate(vehicle)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 9, weight: .bold))
                            Text("导航")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.brand.opacity(0.92)))
                        .shadow(color: Theme.brand.opacity(0.35), radius: 6, y: 2)
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                    .padding(8)
                }
            }
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 18,
                style: .continuous
            ))

            Button {
                showMap = true
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.brand)
                        Text("位置")
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
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(shortTime(vehicle.locationTime))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: Theme.cardShadow, radius: 12, x: 0, y: 4)
    }

    private func rideCard(_ vehicle: Vehicle) -> some View {
        Button {
            showReplay = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "figure.outdoor.cycle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Text("骑行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Text("回放")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.brand.opacity(0.7))
                }

                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rideExtra?.lastKm.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("最近 · km")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                        MiniSparkline(tint: Color(hex: 0xFF5A5F), seed: 1)
                            .frame(height: 32)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(rideExtra?.lastMin.map { "\($0)" } ?? "—")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("时长 · min")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                        MiniSparkline(tint: Theme.brand, seed: 2)
                            .frame(height: 32)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HairLine()

                HStack(spacing: 0) {
                    rideStat(
                        value: rideExtra?.todayKm.map { String(format: "%.1f", $0) } ?? "—",
                        unit: "km",
                        label: "今日"
                    )
                    rideStat(
                        value: rideExtra?.todayMaxSpeed.map { formatSpeed($0) } ?? "—",
                        unit: "km/h",
                        label: "极速"
                    )
                    rideStat(
                        value: rideExtra?.todayMin.map { "\($0)" } ?? "—",
                        unit: "min",
                        label: "时长"
                    )
                }

                HStack(spacing: 0) {
                    rideStat(
                        value: rideExtra?.todayAccel.map { "\($0)" } ?? "—",
                        unit: "次",
                        label: "急加速"
                    )
                    rideStat(
                        value: rideExtra?.todayBrake.map { "\($0)" } ?? "—",
                        unit: "次",
                        label: "急刹车"
                    )
                    rideStat(
                        value: rideExtra?.todayBend.map { "\($0)" } ?? "—",
                        unit: "次",
                        label: "弯道"
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.surface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.45), lineWidth: 0.5)
            }
            .shadow(color: Theme.cardShadow, radius: 12, x: 0, y: 4)
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

    private var sharedHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("共享车辆")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text("主题、仪表壁纸与车辆设置仅车主可用")
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
        if let address = AmapGeocode.readableAddress(resolvedAddress)
            ?? AmapGeocode.readableAddress(vehicle.address) {
            return address
        }
        return "定位中…"
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
        guard let minutes = rideExtra?.todayMin, minutes > 0 else { return "—" }
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

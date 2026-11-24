import SwiftUI

struct VehicleView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var wallpaperStore: WallpaperStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @EnvironmentObject private var messages: MessageStore
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var seatLinkage: SeatLinkageStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.activeMainTab) private var activeMainTab

    @StateObject private var model3D = VehicleModelLoader()
    @State private var heroGLB: URL?
    /// 3D 模型下载失败（仪表 Wi-Fi 等无互联网网络常见）：主视觉回落车图并提示
    @State private var glbLoadFailed = false
    @State private var loadedModelVin: String?
    @State private var readyGLBVins: Set<String> = []

    @State private var busy: String?
    @State private var toast: String?

    @State private var seatSyncToken = 0 // 云端坐垫状态变化计数，驱动主页 3D 模型
    @State private var rideExtra: RideTrackService.RideExtra?
    @State private var rideLoading = false
    @State private var resolvedAddress: String?
    /// 定位隐私遮挡：开启后首页地图/地址模糊隐藏（记忆在本地设置）
    @AppStorage("privacy.hideLocation") private var hideLocation = false
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
    @State private var showMessages = false
    @State private var pinningHero = false
    @State private var cameraReset = 0
    @State private var didResetForScroll = false

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let vehicle = model.selectedVehicle {
                    hero(vehicle, proxy: proxy)
                    ScrollView(showsIndicators: false) {
                        content(vehicle)
                            .padding(.bottom, 128)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: VehicleScrollOffsetKey.self,
                                        value: geo.frame(in: .named("vehicleHome")).minY
                                    )
                                }
                            }
                    }
                    .padding(.top, themeStore.selection.blendsIntoPage ? -HeroStage.pageBlend : 0)
                    .coordinateSpace(name: "vehicleHome")
                    .scrollDisabled(pinningHero)
                    .refreshable { await reloadPage() }
                    .onPreferenceChange(VehicleScrollOffsetKey.self) { y in
                        if y < -36, !didResetForScroll {
                            didResetForScroll = true
                            cameraReset += 1
                        } else if y > -8 {
                            didResetForScroll = false
                        }
                    }
                } else if model.loading {
                    loadingState
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(edges: .top)
        .background(Theme.groupedBackground.ignoresSafeArea())
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
                TrackMapView(
                    vehicle: vehicle,
                    address: locationLabel(vehicle),
                    vehicleImage: mapMarkerImage(vehicle)
                )
            }
        }
        .sheet(isPresented: $show3D) {
            if let vehicle = model.selectedVehicle { Vehicle3DSheet(vehicle: vehicle) }
        }
        .sheet(isPresented: $showSettings) {
            if let vehicle = model.selectedVehicle { VehicleSettingsView(vehicle: vehicle) }
        }
        .sheet(isPresented: $showMessages) {
            MessageInboxView(store: messages)
        }
        .fullScreenCover(isPresented: $showReplay) {
            RideHomeView(showsClose: true)
        }
        .task(id: model.selectedVehicle?.vinNo) {
            guard let vin = model.selectedVehicle?.vinNo else { return }
            if loadedModelVin != vin {
                restoreCachedHero(vin: vin)
                loadedModelVin = vin
            }
            rideExtra = nil
            resolvedAddress = nil
            async let modelTask: Void = loadHeroModel()
            async let photo: Void = cacheSelectedPhoto()
            async let ride: Void = loadRideSummary(vin: vin)
            async let battery: Void = model.loadBattery(vin: vin)
            async let detail: Void = model.loadDetail(vin: vin)
            async let tire: Void = model.loadTire(vin: vin)
            async let sign: Void = signin.refresh()
            async let addr: Void = resolveAddressIfNeeded()
            async let inbox: Void = messages.refresh()
            _ = await (modelTask, photo, ride, battery, detail, tire, sign, addr, inbox)
            await signin.syncWidget(model: model, ride: rideExtra)
            syncChargeIsland()
            model.markUpdated()

            // 充电中约 20 秒刷电池；平时约 90 秒。离开车辆 Tab 不刷
            while !Task.isCancelled {
                let charging = model.liveBatteryOfSelected?.isLiveCharging == true
                try? await Task.sleep(nanoseconds: charging ? 20_000_000_000 : 90_000_000_000)
                guard !Task.isCancelled else { break }
                guard scenePhase == .active, activeMainTab == .vehicle else { continue }
                if charging {
                    if let vin = model.selectedVehicle?.vinNo {
                        await model.loadBattery(vin: vin, quiet: true)
                    }
                    syncChargeIsland()
                    continue
                }
                await model.refreshQuiet()
                await messages.refresh()
                syncChargeIsland()
                if let current = model.selectedVehicle?.vinNo {
                    await loadRideSummary(vin: current)
                    await model.loadTire(vin: current)
                    await signin.syncWidget(model: model, ride: rideExtra)
                }
            }
        }
        .onChange(of: model.selectedVehicle?.vinNo) { _, vin in
            guard let vin else { return }
            restoreCachedHero(vin: vin)
            loadedModelVin = vin
        }
        // 3D 模型地址只有详情接口带，详情回来晚了要补一次加载
        .onChange(of: model.selectedVehicle?.model3DURL) { _, url in
            guard url != nil else { return }
            Task { await loadHeroModel() }
        }
        .onChange(of: model.selectedVehicle?.soc) { _, _ in
            WidgetSnapshot.publish(from: model, signin: signin, ride: rideExtra)
            syncChargeIsland()
        }
        .onChange(of: model.selectedVehicle?.isCharging) { _, _ in
            syncChargeIsland()
        }
        .onChange(of: model.selectedVehicle?.seat) { _, _ in
            // 云端坐垫状态变化：主页 3D 模型跟着开/合（该车型关闭联动时不跟随）
            guard seatLinkage.isLinked(vin: model.selectedVehicle?.vinNo) else { return }
            seatSyncToken += 1
        }
        .onChange(of: model.selectedVehicle?.vinNo) { _, _ in
            seatSyncToken += 1 // 切车后也要按新车状态摆坐垫
        }
        .onReceive(seatLinkage.objectWillChange) { _ in
            // 联动开关变化：重新摆一次坐垫（关→合上，开→按真实状态摆）
            seatSyncToken += 1
        }
        .onReceive(model3D.$state) { state in
            if case .ready = state, let vin = model.selectedVehicle?.vinNo {
                snapshotMarkerIfNeeded(vin: vin)
            }
        }
        .onChange(of: model.selectedVehicle?.latitude) { _, _ in
            Task { await resolveAddressIfNeeded() }
        }
        .onChange(of: model.selectedVehicle?.longitude) { _, _ in
            Task { await resolveAddressIfNeeded() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // 回前台轻量刷新，不整页重载 3D/视频，避免闪白
            Task {
                await model.refreshQuiet()
                await messages.refresh()
                syncChargeIsland()
                if let vin = model.selectedVehicle?.vinNo {
                    await loadRideSummary(vin: vin)
                    await signin.syncWidget(model: model, ride: rideExtra)
                }
            }
        }
    }

    // MARK: - 主视觉

    private func hero(_ vehicle: Vehicle, proxy: GeometryProxy) -> some View {
        let bar = ScreenMetrics.statusBarHeight
        let fullHeight = proxy.size.height + bar

        return HeroStage(
            vehicle: vehicle,
            selection: themeStore.selection,
            videoURL: themeStore.resolvedVideoURL(local: videoStore.url),
            videoPoster: videoStore.poster,
            photo: wallpaperStore.image,
            modelScene: model3D.scene,
            modelGLBFile: heroGLB,
            modelGLBCached: vehicle.vinNo == loadedModelVin && (readyGLBVins.contains(vehicle.vinNo) || HeroAssetCache.glb(for: vehicle.vinNo) != nil),
            prefers3D: vehicle.model3DURL != nil,
            modelGLBFailed: glbLoadFailed,
            onRetryModel: {
                glbLoadFailed = false
                Task { await loadHeroModel() }
            },
            screenActive: activeMainTab == .vehicle,
            lightsOn: appearance.resolvedScheme == .dark,
            liveCharging: model.liveBatteryOfSelected?.isLiveCharging,
            // 关闭该车型的坐垫联动时，模型保持合上，不跟随云端坐垫状态
            seatOpen: seatLinkage.isLinked(vin: vehicle.vinNo) && model.selectedVehicle?.seat?.isOpen() == true,
            seatSyncToken: seatSyncToken,
            tireFrontBar: model.tire?.frontBar,
            tireRearBar: model.tire?.rearBar,
            tireFrontTemp: model.tire?.frontTemp,
            tireRearTemp: model.tire?.rearTemp,
            topInset: bar + 8,
            height: max(388, fullHeight * 0.47),
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
            onOpenMessages: { showMessages = true },
            unreadCount: messages.unreadCount,
            onOpenTheme: {
                themeFocus = .theme
                showTheme = true
            },
            onOpenCushion: {
                run("cushion") { try await model.openCushion(vehicle) }
                // 开坐垫后尽快拉状态，让主页/弹层的 3D 模型跟上（云端上报有延迟，多试几轮）
                Task {
                    for delay in [8.0, 20.0, 40.0] {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        await model.loadBattery(vin: vehicle.vinNo, quiet: true)
                    }
                }
            },
            onOpenTire: {
                showTire = true
            },
            onOpenBattery: {
                showBattery = true
            },
            onInteract: { pinningHero = $0 },
            canSwitchVehicle: model.vehicles.count > 1,
            cameraReset: cameraReset
        )
    }

    /// 切车时先用这份 VIN 缓存，避免 3D / 车图重新下载闪一下
    private func restoreCachedHero(vin: String) {
        let vehicle = model.selectedVehicle
        let remote = vehicle?.model3DURL
        if let file = HeroAssetCache.glb(for: vin) ?? GLBModelStore.cached(vin: vin, remote: remote) {
            HeroAssetCache.rememberGLB(file, vin: vin)
            heroGLB = file
            readyGLBVins.insert(vin)
            model3D.clear()
            return
        }
        if let remote, vehicle?.isGLBModel != true {
            model3D.restore(vin: vin, url: remote)
            heroGLB = nil
            return
        }
        heroGLB = nil
        if VehicleModelLoader.cachedScene(vin: vin) == nil {
            model3D.clear()
        }
    }

    /// glb 走 model-viewer，其余格式交给 SceneKit；同一 VIN 命中磁盘/内存缓存就不再请求
    private func loadHeroModel() async {
        guard let vehicle = model.selectedVehicle else {
            heroGLB = nil
            model3D.clear()
            return
        }
        let vin = vehicle.vinNo
        glbLoadFailed = false
        if let cached = HeroAssetCache.glb(for: vin) ?? GLBModelStore.cached(vin: vin, remote: vehicle.model3DURL) {
            heroGLB = cached
            readyGLBVins.insert(vin)
            snapshotMarkerIfNeeded(vin: vin)
            return
        }
        guard let url = vehicle.model3DURL else {
            guard model.selectedVehicle?.vinNo == vin else { return }
            heroGLB = nil
            model3D.clear()
            snapshotMarkerIfNeeded(vin: vin)
            return
        }
        if vehicle.isGLBModel {
            if let cached = GLBModelStore.cached(vin: vin, remote: url) {
                readyGLBVins.insert(vin)
                heroGLB = cached
                snapshotMarkerIfNeeded(vin: vin)
                return
            }
            let file = try? await GLBModelStore.localFile(for: url, vin: vin)
            guard model.selectedVehicle?.vinNo == vin else { return }
            if let file {
                readyGLBVins.insert(vin)
                heroGLB = file
                glbLoadFailed = false
                // hero 车模就绪后顺手预热 3D 弹层网页：首次打开弹层也接近秒开
                ModelViewerWebView.prewarm(reuseKey: "sheet3d-\(vin)", glbFile: file)
            } else {
                // 下载失败（常见于仪表 Wi-Fi 无互联网）：回落车图并提示，不再永远转圈
                glbLoadFailed = true
                showToast("3D 模型下载失败，已临时改用官方车图")
            }
        } else {
            heroGLB = nil
            model3D.load(url, vin: vin)
        }
        snapshotMarkerIfNeeded(vin: vin)
    }

    private func cacheSelectedPhoto() async {
        guard let vehicle = model.selectedVehicle, let url = vehicle.imageURL else { return }
        let vin = vehicle.vinNo
        let image = await ResourceCache.image(for: url)
        guard model.selectedVehicle?.vinNo == vin else { return }
        if let image {
            HeroAssetCache.rememberPhoto(image, vin: vin)
            if let data = image.pngData() {
                WidgetSnapshot.saveImage(data, vin: vin)
            }
        }
    }

    private func snapshotMarkerIfNeeded(vin: String) {
        if let scene = model3D.scene ?? VehicleModelLoader.cachedScene(vin: vin),
           let shot = VehicleSceneSnapshot.image(from: scene) {
            HeroAssetCache.rememberSnapshot(shot, vin: vin)
            return
        }
        if let photo = HeroAssetCache.photo(for: vin) {
            HeroAssetCache.rememberPhoto(photo, vin: vin)
        }
    }

    private func mapMarkerImage(_ vehicle: Vehicle) -> UIImage? {
        HeroAssetCache.photo(for: vehicle.vinNo)
            ?? ResourceCache.cachedImage(vehicle.imageURL)
            ?? WidgetSnapshot.displayImage(vin: vehicle.vinNo)
    }

    private func reloadPage() async {
        await model.loadVehicles()
        guard let vin = model.selectedVehicle?.vinNo else { return }
        async let battery: Void = model.loadBattery(vin: vin, quiet: true)
        async let detail: Void = model.loadDetail(vin: vin)
        async let tire: Void = model.loadTire(vin: vin)
        _ = await (battery, detail, tire)
        await loadRideSummary(vin: vin)
        await resolveAddressIfNeeded()
        await signin.syncWidget(model: model, ride: rideExtra)
        await messages.refresh()
        syncChargeIsland()
        cameraReset += 1
        model.markUpdated()
    }

    private func syncChargeIsland() {
        guard let vehicle = model.selectedVehicle else { return }
        let live = model.liveBatteryOfSelected
        ChargeLiveActivityController.sync(vehicle: vehicle, battery: live)
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
            updatedAtFooter
        }
        .padding(.horizontal, 16)
        .padding(.top, themeStore.selection.blendsIntoPage ? 8 : 4)
        .padding(.bottom, 8)
        .background(alignment: .top) { contentBackdrop }
    }

    /// 数据最近一次成功刷新的时间
    private var updatedAtFooter: some View {
        Group {
            if let date = model.lastUpdatedAt {
                Text("更新于 " + Self.timeFormatter.string(from: date))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
        }
        .transaction { $0.animation = nil }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    @ViewBuilder
    private var contentBackdrop: some View {
        if themeStore.selection.blendsIntoPage {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: Theme.groupedBackground.opacity(0), location: 0),
                        .init(color: Theme.groupedBackground.opacity(0.35), location: 0.4),
                        .init(color: Theme.groupedBackground.opacity(0.82), location: 0.78),
                        .init(color: Theme.groupedBackground, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: HeroStage.pageBlend + 20)
                Theme.groupedBackground
            }
        } else {
            Theme.groupedBackground
        }
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
                run("find", success: "寻车指令已发送") { try await model.findVehicle(vehicle) }
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
                    ? "车辆离线，指令已排队，上线后执行"
                    : (locked ? "开机指令已发送" : "关机指令已发送")
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
                    Text(loading ? "请求中…" : (locked ? "开机" : "关机"))
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(online ? (locked ? "车辆已关机" : "车辆已开机") : "离线 · 指令将排队")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityLabel(locked ? "开机" : "关机")
    }

    // MARK: - 位置 / 骑行

    private func duoCards(_ vehicle: Vehicle) -> some View {
        HStack(alignment: .top, spacing: 9) {
            locationCard(vehicle)
            rideCard(vehicle)
        }
        .frame(height: 176)
    }

    private func locationCard(_ vehicle: Vehicle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !hideLocation else { return }
                showMap = true
            } label: {
                ZStack(alignment: .topLeading) {
                    mapBody(vehicle)
                    Text("高德地图")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x00B6FF))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.88)))
                        .padding(6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .overlay {
                    // 隐私遮挡层：磨砂盖板 + 提示，盖住地图细节
                    if hideLocation {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(systemName: "eye.slash")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("位置已隐藏")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(Theme.secondary)
                            )
                            .allowsHitTesting(false)
                    }
                }
            }
            .buttonStyle(PressableStyle(scale: 1, brightness: 0))
            .disabled(hideLocation)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("车辆位置")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(Motion.quick) { hideLocation.toggle() }
                    } label: {
                        Image(systemName: hideLocation ? "eye.slash" : "eye")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(hideLocation ? Theme.orange : Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    Button {
                        navigate(vehicle)
                    } label: {
                        Text("导航")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(vehicle.coordinate == nil || hideLocation ? Theme.tertiary : Theme.brand)
                    }
                    .buttonStyle(.plain)
                    .disabled(vehicle.coordinate == nil || hideLocation)
                }
                Text(hideLocation ? "位置已隐藏" : locationLabel(vehicle))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !hideLocation, !locationTimeLabel(vehicle).isEmpty {
                    Text(locationTimeLabel(vehicle))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 0) {
                Text("骑行记录")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.label)
                    .padding(.bottom, 12)

                if rideLoading && rideExtra == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        SkeletonBar(width: 88, height: 18)
                        SkeletonBar(width: 72, height: 18)
                        Spacer(minLength: 0)
                        SkeletonBar(height: 28, radius: 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    rideWaveRow(
                        value: formatRideKm(rideExtra?.lastKm),
                        unit: "km",
                        label: "最近骑行",
                        tint: Color(hex: 0xFF3B64),
                        phase: 0.4
                    )
                    .padding(.bottom, 8)

                    rideWaveRow(
                        value: formatRideMinutes(rideExtra?.lastMin),
                        unit: "min",
                        label: "时长",
                        tint: Color(hex: 0x0B84FF),
                        phase: 0.75
                    )

                    Spacer(minLength: 6)

                    HStack(spacing: 0) {
                        rideFoot(
                            value: formatRideKm(rideExtra?.todayKm),
                            unit: "km",
                            label: "今日里程"
                        )
                        rideFoot(
                            value: formatRideMinutes(rideExtra?.todayMin),
                            unit: "min",
                            label: "时长"
                        )
                        rideFoot(
                            value: formatSpeed(rideExtra?.todayMaxSpeed),
                            unit: "km/h",
                            label: "极速"
                        )
                    }
                    .padding(.top, 7)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(Theme.separator.opacity(0.7))
                            .frame(height: 0.6)
                    }
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

    private func rideWaveRow(
        value: String,
        unit: String,
        label: String,
        tint: Color,
        phase: Double
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(unit)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.label)
                }
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)

            RideWaveLine(tint: tint, phase: phase)
                .frame(height: 18)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private func rideFoot(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(unit)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.secondary)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func mapBody(_ vehicle: Vehicle) -> some View {
        if let coordinate = vehicle.coordinate {
            VehicleMapView(
                coordinate: coordinate,
                interactive: false,
                vehicleImage: mapMarkerImage(vehicle),
                vehicleImageURL: vehicle.imageURL
            )
                .id(vehicle.vinNo)
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
        .padding(.top, ScreenMetrics.statusBarHeight)
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
        .padding(.top, ScreenMetrics.statusBarHeight + 120)
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
        guard vehicle.coordinate != nil else { return "暂无定位" }
        if let address = AmapGeocode.compact(resolvedAddress, limit: 12)
            ?? AmapGeocode.compact(vehicle.address, limit: 12) {
            return address
        }
        return "定位中…"
    }

    private func locationTimeLabel(_ vehicle: Vehicle) -> String {
        guard vehicle.coordinate != nil else { return "" }
        if let raw = vehicle.locationTime, !raw.isEmpty {
            return raw
        }
        return ""
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
        if let cached = AmapGeocode.readableAddress(resolvedAddress),
           model.selectedVehicle?.vinNo == vehicle.vinNo {
            return
        }
        resolvedAddress = await AmapGeocode.reverse(
            longitude: coord.longitude,
            latitude: coord.latitude
        )
    }

    private func formatRideKm(_ km: Double?) -> String {
        guard let km, km > 0 else { return "—" }
        return km >= 100 ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

    private func formatRideMinutes(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "—" }
        return "\(minutes)"
    }

    private func formatSpeed(_ speed: Double?) -> String {
        guard let speed, speed > 0 else { return "—" }
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

private struct VehicleScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 衰减波浪折线，对齐官方骑行卡红/蓝装饰曲线
private struct RideWaveLine: View {
    var tint: Color
    var phase: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Path { path in
                let steps = 36
                guard size.width > 1, size.height > 1 else { return }
                var points: [CGPoint] = []
                points.reserveCapacity(steps + 1)
                for i in 0...steps {
                    let t = Double(i) / Double(steps)
                    let decay = exp(-t * 2.6)
                    let yNorm = 0.5 + 0.42 * decay * sin((t * 9.5 + phase * .pi * 2) * .pi)
                    let y = min(max(yNorm * size.height, 1), size.height - 1)
                    points.append(CGPoint(x: size.width * t, y: y))
                }
                guard let first = points.first else { return }
                path.move(to: first)
                for i in 1..<points.count {
                    let previous = points[i - 1]
                    let current = points[i]
                    let mid = CGPoint(
                        x: (previous.x + current.x) / 2,
                        y: (previous.y + current.y) / 2
                    )
                    path.addQuadCurve(to: mid, control: previous)
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))
        }
    }
}

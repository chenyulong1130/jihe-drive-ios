import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var videoStore: VideoBackdropStore
    @EnvironmentObject private var wallpaperStore: WallpaperStore
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.activeMainTab) private var activeMainTab

    @State private var showPicker = false
    @State private var showTheme = false
    @State private var showBattery = false
    @State private var showDashboardWallpaper = false
    @State private var showSigninDetail = false
    @StateObject private var signin = SigninStore()
    @StateObject private var profileStore = UserProfileStore()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                LargeTitle("我的")
                    .staggerIn(0)

                accountCard.staggerIn(1)

                SectionHeader("签到")
                SigninPanel(store: signin, onMore: { showSigninDetail = true })
                    .padding(.bottom, 8)
                    .staggerIn(2)

                SectionHeader("车辆")
                vehicleSection.staggerIn(3)

                SectionHeader("外观")
                appearanceSection.staggerIn(4)

                SectionHeader("个性化")
                personalSection.staggerIn(5)

                SectionHeader("桌面")
                widgetSection.staggerIn(6)

                logoutButton
                    .padding(.top, 24)
                    .staggerIn(7)
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)
            .padding(.bottom, 118)
        }
        .animation(nil, value: appearance.resolvedScheme)
        .task(id: activeMainTab) {
            guard activeMainTab == .settings else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, activeMainTab == .settings else { return }
            async let sign: Void = signin.refresh()
            async let profile: Void = profileStore.refresh()
            _ = await (sign, profile)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, activeMainTab == .settings else { return }
            Task { await signin.refresh() }
        }
        .sheet(isPresented: $showPicker) {
            VehiclePickerSheet()
        }
        .sheet(isPresented: $showTheme) {
            ThemeSheet()
        }
        .sheet(isPresented: $showDashboardWallpaper) {
            if let vehicle = model.selectedVehicle {
                DashboardWallpaperSheet(vehicle: vehicle)
            }
        }
        .sheet(isPresented: $showBattery) {
            if let vehicle = model.selectedVehicle {
                BatterySheet(vehicle: vehicle)
            }
        }
        .sheet(isPresented: $showSigninDetail) {
            SigninDetailSheet()
                .environmentObject(signin)
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        AppleCard(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)) {
            HStack(spacing: 8) {
                ForEach(AppAppearance.allCases) { mode in
                    appearanceChip(mode)
                }
            }
        }
    }

    private func appearanceChip(_ mode: AppAppearance) -> some View {
        let selected = appearance.mode == mode
        return Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { appearance.mode = mode }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.white : Theme.label)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.surfaceAlt)
                    if selected {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.brand, Color(hex: 0x4B5BFF)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.96, brightness: 0))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 账号

    private var accountCard: some View {
        let profile = profileStore.profile
        return AppleCard {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    avatarView(profile)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile?.nickName.isEmpty == false ? profile!.nickName : "极核骑手")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(profileSubtitle(profile))
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    StatusPill(text: "已登录", color: Theme.green)
                }

                HairLine()

                HStack(spacing: 0) {
                    accountStat(title: "积分", value: profile.map { "\($0.score)" } ?? "--", unit: nil)
                    accountDivider
                    accountStat(title: "帖子", value: profile.map { "\($0.postsNum)" } ?? "--", unit: nil)
                    accountDivider
                    accountStat(title: "粉丝", value: profile.map { "\($0.fansNum)" } ?? "--", unit: nil)
                    accountDivider
                    accountStat(title: "获赞", value: profile.map { "\($0.likeTimes)" } ?? "--", unit: nil)
                }
            }
        }
    }

    private func avatarView(_ profile: UserProfileStore.Profile?) -> some View {
        ZStack {
            Circle()
                .fill(Theme.brand.opacity(0.12))
            if let url = profile?.avatarURL {
                CachedRemoteImage(url: url, contentMode: .fill)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.brand)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
    }

    private func profileSubtitle(_ profile: UserProfileStore.Profile?) -> String {
        if let profile {
            if !profile.signature.isEmpty { return profile.signature }
            if !profile.userShowId.isEmpty { return "ID \(profile.userShowId)" }
            if !profile.userId.isEmpty { return "UID \(profile.userId)" }
        }
        return ZeehoClient.shared.userId.map { "UID \($0)" } ?? "未获取到 UID"
    }

    private func accountStat(title: String, value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 0.5, height: 28)
            .padding(.horizontal, 10)
    }

    // MARK: - 车辆

    private var vehicleSection: some View {
        AppleCard(padding: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)) {
            VStack(spacing: 0) {
                row(
                    icon: "car.2",
                    title: "车辆管理",
                    detail: model.vehicles.count > 1 ? "\(model.vehicles.count) 台" : (model.selectedVehicle?.name ?? "暂无")
                ) {
                    if !model.vehicles.isEmpty { showPicker = true }
                }

                HairLine().padding(.leading, 44)

                row(
                    icon: "battery.75percent",
                    title: "电池信息",
                    detail: (model.batteriesBelongToSelected ? model.batteries.first : nil).map { "\($0.level)% · \($0.stateText)" } ?? "未读取"
                ) {
                    showBattery = true
                }

                HairLine().padding(.leading, 44)

                plainRow(
                    icon: "point.topleft.down.to.point.bottomright.curvepath",
                    title: "最后位置",
                    detail: model.selectedVehicle?.coordinate == nil ? "未上报" : "车辆页查看地图"
                )
            }
        }
    }

    // MARK: - 小组件

    private var widgetSection: some View {
        AppleCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("主屏小组件")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text("今日骑行 · 电量 · 积分 · 签到 · 社区")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Text("长按桌面空白处 → 添加小组件 → 搜索「极核智行」")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("今日已签到且社区已完成时，刷新只拉车辆数据，不再重复签到和社区任务。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task {
                        await model.refreshAll()
                        await signin.refresh()
                        await signin.syncWidget(model: model, ride: nil)
                    }
                } label: {
                    Text("立即同步到小组件")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.brand.opacity(0.1))
                        )
                }
                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
            }
        }
    }

    // MARK: - 个性化

    private var personalSection: some View {
        AppleCard(padding: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)) {
            VStack(spacing: 0) {
                row(
                    icon: "paintpalette.fill",
                    title: "车辆背景主题",
                    detail: backdropDetail
                ) {
                    showTheme = true
                }

                HairLine().padding(.leading, 44)

                row(
                    icon: "photo.on.rectangle",
                    title: "仪表壁纸",
                    detail: ""
                ) {
                    if model.selectedVehicle != nil {
                        showDashboardWallpaper = true
                    }
                }
            }
        }
    }

    private var backdropShort: String {
        themeStore.displayName
    }

    private var backdropDetail: String {
        switch themeStore.selection {
        case .video:
            return videoStore.hasVideo ? "视频 · 循环播放" : "视频未设置"
        case .photo:
            return wallpaperStore.hasWallpaper ? "照片" : "照片未设置"
        case .animated(let kind):
            return "动态 · \(kind.name)"
        case .builtin(let wallpaper):
            return "内置 · \(wallpaper.name)"
        case .theme(let theme):
            return "云端 · \(theme.name)"
        }
    }

    private var logoutButton: some View {
        Button {
            withAnimation(Motion.spring) {
                model.logout()
            }
        } label: {
            Text("退出登录")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                        .fill(Theme.surface)
                )
                .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
    }

    // MARK: - 行

    private func row(
        icon: String,
        title: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 28, height: 28)

                Text(title)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.label)

                Spacer(minLength: 6)

                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
    }

    private func plainRow(
        icon: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)

            Text(title)
                .font(.system(size: 17))
                .foregroundStyle(Theme.label)

            Spacer(minLength: 6)

            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 48)
    }
}

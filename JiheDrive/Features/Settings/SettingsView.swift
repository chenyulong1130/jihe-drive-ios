import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var seatLinkage: SeatLinkageStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.activeMainTab) private var activeMainTab

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

                SectionHeader("外观")
                appearanceSection.staggerIn(3)

                SectionHeader("3D 模型")
                modelSection.staggerIn(4)

                logoutButton
                    .padding(.top, 24)
                    .staggerIn(5)
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

    // MARK: - 3D 模型

    /// 当前选中车辆的坐垫联动开关（按 VIN 记忆，切车互不影响）
    private var seatLinkBinding: Binding<Bool> {
        Binding(
            get: { seatLinkage.isLinked(vin: model.selectedVehicle?.vinNo) },
            set: { seatLinkage.setLinked($0, vin: model.selectedVehicle?.vinNo) }
        )
    }

    private var modelSection: some View {
        AppleCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "cube.transparent.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("坐垫联动")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.label)
                        Text(vehicleName)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }

                    Spacer(minLength: 6)

                    Toggle("", isOn: seatLinkBinding)
                        .labelsHidden()
                        .tint(Theme.brand)
                }

                Text(linkHint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var vehicleName: String {
        let linked = seatLinkage.isLinked(vin: model.selectedVehicle?.vinNo)
        let name = model.selectedVehicle?.name ?? "当前车辆"
        return "\(name) · 联动\(linked ? "开" : "关")"
    }

    private var linkHint: String {
        seatLinkage.isLinked(vin: model.selectedVehicle?.vinNo)
            ? "真实坐垫开合时，主页与 3D 看车的模型坐垫同步跟动。"
            : "已关闭：模型坐垫不跟随真实坐垫，仅 3D 看车内手动开关时才会动。"
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
}

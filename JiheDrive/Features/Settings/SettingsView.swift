import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var seatLinkage: SeatLinkageStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.activeMainTab) private var activeMainTab

    @State private var showSigninDetail = false
    @State private var showHangReport = false
    @StateObject private var signin = SigninStore()
    @StateObject private var profileStore = UserProfileStore()
    // 石栏开机密码（大灯/控制器入口用），存在这里详情页就不用每次问
    @State private var powerCode = DeviceAuth.powerOnCode
    @State private var hasCustomPowerCode = DeviceAuth.hasCustomPowerCode()
    @State private var powerCodeSaved = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                LargeTitle("我的") {
                    appearanceMenu
                }
                .staggerIn(0)

                accountCard.staggerIn(1)

                SigninPanel(store: signin, onMore: { showSigninDetail = true })
                    .staggerIn(2)

                modelSection.staggerIn(3)

                deviceSection.staggerIn(4)

                diagnosticsSection.staggerIn(5)

                logoutButton
                    .padding(.top, 16)
                    .staggerIn(6)
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
        .sheet(isPresented: $showHangReport) { hangReportSheet }
    }

    // MARK: - 外观（右上角图标切换）

    /// 外观切换：右上角图标显示当前模式，点开菜单三选（跟随系统/浅色/深色）
    private var appearanceMenu: some View {
        Menu {
            ForEach(AppAppearance.allCases) { mode in
                Button {
                    appearance.mode = mode
                } label: {
                    if appearance.mode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            }
        } label: {
            Image(systemName: appearance.mode.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceAlt, in: Circle())
        }
        .accessibilityLabel("外观：\(appearance.mode.title)")
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

    // MARK: - 设备（石栏开机密码）

    /// 石栏大灯 / 控制器的 8 位开机密码：在这里存好，设备页验证时直接比对，
    /// 没存则回落出厂默认 22222222
    private var deviceSection: some View {
        AppleCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("石栏开机密码")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.label)
                        Text(hasCustomPowerCode
                             ? "已保存自定义密码 · 连接大灯/控制器时自动校验"
                             : "未保存，使用默认密码 \(DeviceAuth.defaultPowerOnCode)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                TextField("8 位数字密码", text: $powerCode)
                    .keyboardType(.numberPad)
                    .font(.system(size: 18, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))

                HStack(spacing: 12) {
                    Button {
                        DeviceAuth.setPowerOnCode(powerCode)
                        hasCustomPowerCode = DeviceAuth.hasCustomPowerCode()
                        powerCodeSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { powerCodeSaved = false }
                    } label: {
                        Text(powerCodeSaved ? "已保存 ✓" : "保存")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                    }
                    .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

                    if hasCustomPowerCode {
                        Button {
                            DeviceAuth.setPowerOnCode("")
                            powerCode = DeviceAuth.defaultPowerOnCode
                            hasCustomPowerCode = false
                        } label: {
                            Text("恢复默认")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.red)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Theme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous))
                        }
                        .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
                    }
                }
            }
        }
    }

    // MARK: - 账号

    /// 主线程卡死报告入口：App 偶发「直接卡死」时，报告里有卡死时长和卡死前的事件环，
    /// 复制全文反馈即可定位是哪个子系统堵住了主线程
    private var diagnosticsSection: some View {
        AppleCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
            Button {
                showHangReport = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg.rectangle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("主线程卡死报告")
                            .font(.system(size: 17))
                            .foregroundStyle(Theme.label)
                        Text("App 出现「直接卡死」时自动记录，点开复制全文反馈")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
        }
    }

    private var hangReportSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if let text = MainThreadHangMonitor.reportText() {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label("复制全部报告", systemImage: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.bottom, 4)

                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("暂无卡死记录", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.green)
                            Text("监测器常驻后台（阈值 3.5 秒）。App 再次出现「直接卡死」时，卡死发生瞬间的时长与事件环会自动写入本报告，回到这里复制全文即可反馈。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                        }
                        .padding(.vertical, 32)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(Theme.page)
            }
            .background(Theme.groupedBackground)
            .navigationTitle("卡死报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { showHangReport = false } }
            }
        }
    }

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

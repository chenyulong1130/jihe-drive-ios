import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @EnvironmentObject private var videoStore: VideoBackdropStore

    @State private var showPicker = false
    @State private var showTheme = false
    @State private var showBattery = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                LargeTitle("我的", subtitle: "账号 · 车辆 · 个性化")
                    .staggerIn(0)

                accountCard.staggerIn(1)

                SectionHeader("车辆")
                vehicleSection.staggerIn(2)

                SectionHeader("个性化")
                personalSection.staggerIn(3)

                SectionHeader("关于")
                aboutCard.staggerIn(4)

                logoutButton
                    .padding(.top, 24)
                    .staggerIn(5)
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 8)
            .padding(.bottom, 118)
        }
        .sheet(isPresented: $showPicker) {
            VehiclePickerSheet()
        }
        .sheet(isPresented: $showTheme) {
            ThemeSheet()
        }
        .sheet(isPresented: $showBattery) {
            if let vehicle = model.selectedVehicle {
                BatterySheet(vehicle: vehicle)
            }
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        AppleCard {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.brand.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: "person.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Theme.brand)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("极核账号")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.label)
                        Text(ZeehoClient.shared.userId.map { "UID \($0)" } ?? "未获取到 UID")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    StatusPill(text: "已登录", color: Theme.green)
                }

                HairLine()

                HStack(spacing: 0) {
                    accountStat(title: "车辆", value: "\(model.vehicles.count)", unit: "台")
                    accountDivider
                    accountStat(
                        title: "当前电量",
                        value: model.selectedVehicle.map { "\($0.soc)" } ?? "--",
                        unit: "%"
                    )
                    accountDivider
                    accountStat(
                        title: "主视觉",
                        value: backdropShort,
                        unit: nil
                    )
                }
            }
        }
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
                    detail: model.batteries.first.map { "\($0.level)% · \($0.stateText)" } ?? "未读取"
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

    // MARK: - 个性化

    private var personalSection: some View {
        AppleCard(padding: EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)) {
            VStack(spacing: 0) {
                row(
                    icon: "play.rectangle.on.rectangle",
                    title: "车辆背景",
                    detail: backdropDetail
                ) {
                    showTheme = true
                }
            }
        }
    }

    private var backdropShort: String {
        switch themeStore.selection {
        case .video: return "视频"
        case .photo: return "照片"
        case .animated(let kind): return kind.name
        case .theme(let theme): return theme.name
        }
    }

    private var backdropDetail: String {
        switch themeStore.selection {
        case .video:
            return videoStore.hasVideo ? "视频 · 循环播放" : "视频未设置"
        case .photo:
            return "照片"
        case .animated(let kind):
            return "动态 · \(kind.name)"
        case .theme(let theme):
            return theme.name
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                InfoRow(title: "版本", value: Bundle.main.shortVersion)
                HairLine()
                InfoRow(title: "接口", value: "tapi.zeehoev.com", mono: true)
                HairLine()
                InfoRow(title: "构建", value: "unsigned · sideload")
                HairLine()
                InfoRow(title: "登录凭据", value: maskedToken, mono: true)

                Text("非官方客户端，仅供个人调试使用。接口由极核云端提供，随时可能变更。")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
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
                    .lineLimit(1)

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
                .lineLimit(1)
        }
        .frame(minHeight: 48)
    }

    private var maskedToken: String {
        guard let token = ZeehoClient.shared.token, !token.isEmpty else { return "--" }
        return "\(token.prefix(8))…(\(token.count) 位)"
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

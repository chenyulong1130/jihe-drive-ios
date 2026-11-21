import SwiftUI

/// 车辆页签到卡：对齐 Flutter SigninPanel
struct SigninPanel: View {
    @ObservedObject var store: SigninStore
    var onMore: (() -> Void)?

    var body: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 12) {
                header

                if store.loading && store.info == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else if let info = store.info {
                    bodyCard(info)
                } else if let error = store.error {
                    SoftBanner(text: error, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                } else {
                    Text("登录后可签到领积分")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("今日签到")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.label)
            Spacer(minLength: 0)
            if let total = store.totalSignCount {
                Text("已累计 \(total) 天")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
            statusBadge
            communityBadge
            if let onMore {
                Button("更多", action: onMore)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
        }
    }

    private var statusBadge: some View {
        let signed = store.signedToday
        return Text(signed ? "已签" : "未签")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(signed ? Theme.green : Theme.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((signed ? Theme.green : Theme.orange).opacity(0.14))
            )
    }

    private var communityBadge: some View {
        let done = store.communityDone
        return Text(done ? "社区已完成" : "社区未完成")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(done ? Theme.green : Theme.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((done ? Theme.green : Theme.orange).opacity(0.14))
            )
    }

    private func bodyCard(_ info: SigninInfo) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                metric("\(info.daysUntilLottery)", unit: "天", label: "距盲盒")
                metric("\(info.continueDays)", unit: "天", label: "连续签到")
                metric("+\(info.todayEarnedScore + (store.communityDone ? 3 : 0))", unit: "分", label: "今日积分", accent: true)
            }

            HairLine()

            taskRow(
                title: "签到",
                desc: store.signedToday ? "今日已签到" : "今日可 +\(info.todayRuleScore) 分",
                done: store.signedToday,
                score: store.signedToday ? "+\(info.todayEarnedScore)" : "—"
            )

            taskRow(
                title: "社区",
                desc: store.communityRunning ? "正在执行发帖 / 点赞 / 分享…" : (store.communityDone ? "今日已完成" : "发帖 / 点赞 / 分享"),
                done: store.communityDone,
                score: store.communityDone ? "+3" : "—"
            )

            if let last = info.lastTime, !last.isEmpty {
                HStack {
                    Text("最近签到")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(last)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.label)
                }
            }

            HStack(spacing: 8) {
                if !store.signedToday {
                    Button {
                        Task { await store.signInToday() }
                    } label: {
                        HStack {
                            if store.signingIn {
                                ProgressView().tint(.white)
                            }
                            Text(store.signingIn ? "签到中…" : "签到 +\(info.todayRuleScore)")
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.brand)
                        )
                    }
                    .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
                    .disabled(store.signingIn)
                }

                Button {
                    Task { await store.runCommunity() }
                } label: {
                    HStack {
                        if store.communityRunning {
                            ProgressView().tint(Theme.brand)
                        }
                        Text(store.communityRunning ? "社区任务中…" : (store.communityDone ? "社区已完成" : "社区任务 +3"))
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(store.communityDone ? Theme.tertiary : Theme.brand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.brand.opacity(0.12))
                    )
                }
                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
                .disabled(store.communityRunning || store.communityDone)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.groupedBackground)
        )
    }

    private func metric(_ value: String, unit: String, label: String, accent: Bool = false) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(accent ? Theme.brand : Theme.label)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func taskRow(title: String, desc: String, done: Bool, score: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? Theme.green : Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
            Text(score)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(done ? Theme.brand : Theme.tertiary)
        }
    }
}

struct SigninDetailSheet: View {
    @EnvironmentObject private var store: SigninStore
    @Environment(\.dismiss) private var dismiss

    private var info: SigninInfo? { store.info }
    private var continueDays: Int { info?.continueDays ?? 0 }
    private var untilBox: Int { info?.daysUntilLottery ?? 30 }
    private var cycleDay: Int { info?.cycleDayInRound ?? 0 }
    private var cycleProgress: Double { Double(cycleDay) / 30 }
    private var todayCycleDay: Int {
        let days = info?.days ?? continueDays
        guard days > 0 else { return 0 }
        return days % 7 == 0 ? 7 : days % 7
    }
    private var todayScore: Int {
        (info?.todayEarnedScore ?? 0) + (store.communityDone ? 3 : 0)
    }

    var body: some View {
        SheetShell(
            title: "签到与盲盒",
            subtitle: continueDays > 0 ? "连续 \(continueDays) 天" : "连续签到领盲盒",
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let error = store.error, !error.isEmpty {
                        SoftBanner(text: error, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                    }
                    heroCard
                    actionRow
                    if weekRules.contains(where: { $0.score > 0 }) {
                        weekCard
                    }
                    prizeSection
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 32)
            }
            .refreshable {
                await store.refresh()
                await store.loadPrizes()
            }
        }
        .sheetChrome(detents: [.large])
        .task {
            await store.refresh()
            await store.loadPrizes()
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        AppleCard {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    ZStack {
                        RingProgress(
                            progress: cycleProgress,
                            color: untilBox == 0 ? Theme.orange : Theme.brand,
                            track: Theme.surfaceAlt,
                            lineWidth: 8,
                            size: 86
                        )
                        VStack(spacing: 0) {
                            Text("\(untilBox)")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(untilBox == 0 ? Theme.orange : Theme.label)
                                .monospacedDigit()
                            Text(untilBox == 0 ? "可抽" : "天")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(untilBox == 0 ? "盲盒已就绪" : "距下一轮盲盒")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text("连续签到 30 天一轮，本轮已走 \(cycleDay) 天")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if store.signedToday {
                            StatusPill(text: "今日已签到", color: Theme.green)
                        } else {
                            StatusPill(text: "今日未签到", color: Theme.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceAlt)
                        Capsule()
                            .fill(untilBox == 0 ? Theme.orange : Theme.brand)
                            .frame(width: cycleProgress <= 0 ? 0 : max(8, geo.size.width * cycleProgress))
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("本轮进度")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                    Text("\(cycleDay) / 30")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                }

                HairLine()

                HStack(spacing: 0) {
                    metric("\(store.totalSignCount ?? info?.days ?? 0)", "累计")
                    metric("\(continueDays)", "连签")
                    metric(todayScore > 0 ? "+\(todayScore)" : "--", "今日", accent: true)
                }

                if let last = info?.lastTime, !last.isEmpty {
                    Text("最近签到 \(last)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func metric(_ value: String, _ label: String, accent: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(accent ? Theme.brand : Theme.label)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.signInToday() }
            } label: {
                HStack(spacing: 6) {
                    if store.signingIn { ProgressView().tint(.white) }
                    Text(store.signedToday
                         ? "今日已签"
                         : (store.signingIn ? "签到中…" : "立即签到 +\(info?.todayRuleScore ?? 0)"))
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(store.signedToday ? Theme.green : Theme.brand)
                )
            }
            .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
            .disabled(store.signedToday || store.signingIn)

            Button {
                Task { await store.runCommunity() }
            } label: {
                HStack(spacing: 6) {
                    if store.communityRunning { ProgressView().tint(Theme.brand) }
                    Text(store.communityDone ? "社区已完成" : (store.communityRunning ? "执行中…" : "社区 +3"))
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(store.communityDone ? Theme.tertiary : Theme.brand)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.brand.opacity(store.communityDone ? 0.15 : 0.35), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
            .disabled(store.communityDone || store.communityRunning)
        }
    }

    // MARK: - 7-day rules

    private var weekCard: some View {
        AppleCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("7 天积分循环")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.label)
                    Spacer()
                    Text("当天高亮")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }

                HStack(spacing: 6) {
                    ForEach(weekRules) { rule in
                        let current = rule.days == todayCycleDay
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(current ? Theme.brand : Theme.surfaceAlt)
                                    .frame(width: 40, height: 40)
                                if current && store.signedToday {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                } else {
                                    Text("+\(rule.score)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(current ? Color.white : Theme.label)
                                }
                            }
                            Text("D\(rule.days)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(current ? Theme.brand : Theme.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var weekRules: [SigninScoreRule] {
        let list = info?.scoreList ?? []
        if list.count >= 7 { return Array(list.sorted { $0.days < $1.days }.prefix(7)) }
        return (1...7).map { day in
            list.first(where: { $0.days == day }) ?? SigninScoreRule(days: day, score: 0)
        }
    }

    // MARK: - Prizes

    private var prizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("盲盒奖励")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.label)
                Spacer()
                Text("连签 30 天可得")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 4)

            if store.prizesLoading && store.prizes.isEmpty {
                AppleCard {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            } else if store.prizes.isEmpty {
                AppleCard {
                    VStack(spacing: 6) {
                        Text("暂无盲盒奖励")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text("连续签到 30 天可获得盲盒奖品")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } else {
                ForEach(store.prizes) { prize in
                    prizeRow(prize)
                }
                Text("以上是全部奖励")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
    }

    private func prizeRow(_ prize: SigninPrize) -> some View {
        AppleCard(padding: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.surfaceAlt)
                    if let url = prize.imageURL {
                        CachedRemoteImage(url: url, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Text("盲盒")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(prize.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if !prize.createDate.isEmpty {
                        Text(prize.createDate)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Text(prize.distributed ? "已发放" : "已获取")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(prize.distributed ? Theme.green : Theme.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill((prize.distributed ? Theme.green : Theme.orange).opacity(0.14))
                    )
            }
        }
    }
}

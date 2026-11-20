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

    private func bodyCard(_ info: SigninInfo) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                metric("\(info.daysUntilLottery)", unit: "天", label: "距盲盒")
                metric("\(info.continueDays)", unit: "天", label: "连续签到")
                metric("+\(info.todayEarnedScore)", unit: "分", label: "今日积分", accent: true)
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

    var body: some View {
        SheetShell(title: "签到详情", subtitle: "连续签到领盲盒积分", onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    SigninPanel(store: store)

                    if let info = store.info, !info.scoreList.isEmpty {
                        AppleCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("积分规则（7 天循环）")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.label)
                                ForEach(info.scoreList) { rule in
                                    HStack {
                                        Text("第 \(rule.days) 天")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Theme.secondary)
                                        Spacer()
                                        Text("+\(rule.score) 分")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Theme.brand)
                                    }
                                }
                            }
                        }
                    }

                    Text("盲盒周期：连续签到 30 天一轮")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.medium, .large])
        .task { await store.refresh() }
    }
}

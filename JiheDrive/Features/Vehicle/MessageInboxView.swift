import SwiftUI

struct MessageInboxView: View {
    @ObservedObject var store: MessageStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: InboxMessage?
    @State private var working = false
    @State private var confirmDelete = false
    /// 分类：没有「全部」，三桶互斥覆盖所有消息，默认进系统
    @State private var filter = 0

    private var filtered: [InboxMessage] {
        switch filter {
        case 1: return store.items.filter { $0.kind == 2 }
        case 2: return store.items.filter(\.isSocial)
        default: return store.items.filter { !$0.isSocial && $0.kind != 2 }
        }
    }

    var body: some View {
        SheetShell(
            title: headerTitle,
            subtitle: store.unreadCount > 0 ? "\(store.unreadCount) 条未读" : nil,
            onClose: { dismiss() },
            trailing: {
                headerButton(
                    icon: "checkmark.circle",
                    label: "全部已读",
                    disabled: working || store.unreadCount == 0
                ) {
                    Task {
                        working = true
                        await store.markAllRead()
                        working = false
                    }
                }
                headerButton(
                    icon: "trash",
                    label: "清空",
                    disabled: working || store.items.isEmpty
                ) {
                    confirmDelete = true
                }
            }
        ) {
            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .padding(.bottom, 8)

                if store.loading && store.items.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = store.error, store.items.isEmpty {
                    SoftBanner(text: error, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
                        .padding(.horizontal, Theme.page)
                    Spacer()
                } else if filtered.isEmpty {
                    empty
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 12) {
                            ForEach(filtered) { item in
                                Button {
                                    store.open(item)
                                    selected = item
                                } label: {
                                    MessageCard(item: item)
                                }
                                .buttonStyle(PressableStyle(scale: 0.995, brightness: 0))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                    }
                    .refreshable { await store.refresh(notifyNew: false) }
                }
            }
        }
        .sheetChrome(detents: [.large])
        .sheet(item: $selected) { item in
            MessageDetailView(item: item)
        }
        .confirmationDialog("清空所有消息？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) {
                working = true
                Task {
                    await store.deleteAll()
                    working = false
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后不可恢复，刷新时以服务端数据为准")
        }
        .task { await store.refresh(notifyNew: false) }
    }

    /// 与关闭按钮同风格的圆形小按钮
    private func headerButton(icon: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(disabled ? Theme.tertiary : Theme.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surfaceAlt))
        }
        .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var headerTitle: String {
        switch filter {
        case 1: return "车辆消息"
        case 2: return "互动消息"
        default: return "系统消息"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 0) {
            tab("系统", 0)
            tab("车辆", 1)
            tab("互动", 2)
        }
    }

    private func tab(_ title: String, _ kind: Int) -> some View {
        let on = filter == kind
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { filter = kind }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.label : Theme.secondary)
                Capsule()
                    .fill(on ? Theme.label : Color.clear)
                    .frame(width: 18, height: 2.5)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("暂无消息")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.label)
            Text(store.error ?? "官方有新通知时会自动出现")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MessageCard: View {
    let item: InboxMessage

    var body: some View {
        Group {
            if item.isSocial {
                socialCard
            } else if item.kind == 2 {
                vehicleCard
            } else if item.isCampaign {
                campaignCard
            } else {
                systemCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.03), radius: 10, y: 3)
    }

    // MARK: - 系统：标题正文连排，时间在下

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            systemBody
            timeLine
        }
        .padding(16)
    }

    private var systemBody: some View {
        (Text(item.title).font(.system(size: 15, weight: .semibold))
         + (item.content.isEmpty || item.content == item.title
            ? Text("")
            : Text(item.title.hasSuffix("】") ? item.content : " \(item.content)")
                .font(.system(size: 15, weight: .regular))))
        .foregroundStyle(Theme.label)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 活动：标题 + 大图

    private var campaignCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                chevron
            }
            if let url = item.imageURL {
                CachedRemoteImage(url: url, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            timeLine
        }
        .padding(14)
    }

    // MARK: - 车辆：红点标题、正文、地点、地图

    private var vehicleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                if item.unread {
                    Circle()
                        .fill(Color(hex: 0xFF3B30))
                        .frame(width: 7, height: 7)
                }
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                chevron
            }

            if !item.content.isEmpty, item.content != item.title {
                highlightedBody(item.content)
            }

            if !item.addressText.isEmpty {
                Text("触发地点：\(item.addressText)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let url = item.imageURL {
                CachedRemoteImage(url: url, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            timeLine
        }
        .padding(16)
    }

    // MARK: - 互动：头像、蓝字动作、引用块

    private var socialCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 4) {
                    socialHeadline
                    Text(item.timeText)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 4)
                chevron.padding(.top, 2)
            }
            if !item.quote.isEmpty {
                Text(item.quote)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.surfaceAlt)
                    )
            } else if !item.content.isEmpty, item.content != item.title {
                Text(item.content)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.surfaceAlt)
                    )
            }
        }
        .padding(14)
    }

    private var socialHeadline: some View {
        let name = item.actorName.isEmpty ? item.title : item.actorName
        let action = item.actionText
        return Group {
            if action.isEmpty {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                (Text(name)
                    .foregroundStyle(Theme.label)
                 + Text("。")
                    .foregroundStyle(Theme.label)
                 + Text(action)
                    .foregroundStyle(Color(hex: 0x3B82F6)))
                .font(.system(size: 15, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = item.actorAvatar {
                    CachedRemoteImage(url: url, contentMode: .fill)
                } else {
                    Circle()
                        .fill(Theme.surfaceAlt)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                        }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            if item.verified {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x3B82F6), Theme.surface)
                    .offset(x: 2, y: 2)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.tertiary.opacity(0.7))
    }

    private var timeLine: some View {
        Text(item.timeText)
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
    }

    private func highlightedBody(_ raw: String) -> some View {
        Text(attributedCar(raw))
            .font(.system(size: 14))
            .foregroundStyle(Theme.label.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributedCar(_ raw: String) -> AttributedString {
        var text = AttributedString(raw)
        if let start = raw.firstIndex(of: "【"),
           let end = raw.firstIndex(of: "】"),
           start < end {
            let slice = start..<raw.index(after: end)
            if let attr = Range(slice, in: text) {
                text[attr].font = .system(size: 14, weight: .semibold)
            }
        }
        return text
    }
}

struct MessageDetailView: View {
    let item: InboxMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell(title: item.kindLabel, subtitle: item.timeText, onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if item.isSocial {
                        socialHeader
                    }

                    if let url = item.imageURL, !item.isSocial {
                        CachedRemoteImage(url: url, contentMode: .fill)
                            .frame(height: item.kind == 2 ? 160 : 180)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.content.isEmpty, item.content != item.title {
                            Text(item.content)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !item.quote.isEmpty {
                        Text(item.quote)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Theme.surface)
                            )
                    }

                    if !item.carInfo.isEmpty || !item.addressText.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !item.carInfo.isEmpty {
                                detailRow(title: "车辆", value: item.carInfo)
                            }
                            if !item.addressText.isEmpty {
                                detailRow(title: "触发地点", value: item.addressText)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.surface)
                        )
                    }

                    if !item.coordinate.isEmpty {
                        Button(action: openMap) {
                            Text("在地图中查看")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.brand)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Theme.brand.opacity(0.10))
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if let url = item.jumpURL {
                        Link(destination: url) {
                            Text("查看详情")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Theme.brand)
                                )
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.large])
    }

    private var socialHeader: some View {
        HStack(spacing: 12) {
            Group {
                if let url = item.actorAvatar {
                    CachedRemoteImage(url: url, contentMode: .fill)
                } else {
                    Circle().fill(Theme.surfaceAlt)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(item.actorName.isEmpty ? item.title : item.actorName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.actionText.isEmpty {
                    Text(item.actionText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: 0x3B82F6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func openMap() {
        let parts = item.coordinate.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return }
        NavigationLauncher.openBest(
            lat: parts[1],
            lon: parts[0],
            name: item.addressText.isEmpty ? item.title : item.addressText
        )
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

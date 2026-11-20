import SwiftUI

struct MessageInboxView: View {
    @ObservedObject var store: MessageStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: InboxMessage?
    @State private var filter = 0

    private var filtered: [InboxMessage] {
        if filter == 0 { return store.items }
        return store.items.filter { $0.kind == filter }
    }

    var body: some View {
        SheetShell(
            title: "消息",
            subtitle: store.unreadCount > 0 ? "\(store.unreadCount) 条未读" : "官方通知",
            onClose: { dismiss() }
        ) {
            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal, Theme.page)
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
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { item in
                                Button {
                                    store.open(item)
                                    selected = item
                                } label: {
                                    row(item)
                                }
                                .buttonStyle(PressableStyle(scale: 0.98, brightness: 0))
                            }
                        }
                        .padding(.horizontal, Theme.page)
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
        .task { await store.refresh(notifyNew: false) }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            chip("全部", 0)
            chip("系统", 3)
            chip("车辆", 2)
            chip("活动", 1)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ title: String, _ kind: Int) -> some View {
        let on = filter == kind
        return Button {
            filter = kind
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.white : Theme.label)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(on ? Theme.brand : Theme.surface))
        }
        .buttonStyle(.plain)
    }

    private func row(_ item: InboxMessage) -> some View {
        AppleCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(item.unread ? Theme.brand : Color.clear)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(item.kindLabel)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Theme.surfaceAlt))
                    }
                    if !item.content.isEmpty {
                        Text(item.content)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                    Text(item.timeText.isEmpty ? " " : item.timeText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.tertiary)
            Text("暂无消息")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.label)
            Text("系统通知会显示在这里")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MessageDetailView: View {
    let item: InboxMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell(title: item.title, subtitle: item.kindLabel, onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if !item.timeText.isEmpty {
                        Text(item.timeText)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                    }
                    if !item.content.isEmpty {
                        Text(item.content)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let url = item.jumpURL {
                        Link(destination: url) {
                            Text(url.absoluteString)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.brand)
                                .underline()
                        }
                    }
                    AppleCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("接口返回参数")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.label)
                            Text("GET /v1.0/mine/cfmotoservermine/app/Message/list_v2")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.tertiary)
                            ForEach(item.fields, id: \.key) { field in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(field.key)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Theme.secondary)
                                    Text(field.value)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.label)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.large])
    }
}

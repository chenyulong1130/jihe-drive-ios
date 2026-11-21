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
                    .padding(.top, 4)
                    .padding(.bottom, 10)

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
                                    MessageCard(item: item)
                                }
                                .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.white : Theme.label)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(on ? Theme.brand : Theme.surface))
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.unread {
                        Circle()
                            .fill(Color(hex: 0x3B82F6))
                            .frame(width: 7, height: 7)
                            .padding(.top, 7)
                    }
                    Spacer(minLength: 8)
                    Text(item.kindLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }

                if !item.content.isEmpty, item.content != item.title {
                    Text(item.content)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 8) {
                    if !item.carInfo.isEmpty {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "scooter")
                                .font(.system(size: 11, weight: .medium))
                            Text(item.carInfo)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(item.timeText)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, item.imageURL == nil ? 12 : 10)

            if let url = item.imageURL {
                CachedRemoteImage(url: url, contentMode: .fill)
                    .frame(height: 132)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(accent)
            .frame(width: 3)
        }
    }

    private var accent: Color {
        switch item.kind {
        case 2: return Color(hex: 0xE08A2C)
        case 1: return Theme.indigo
        default: return Theme.brand
        }
    }
}

struct MessageDetailView: View {
    let item: InboxMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell(title: item.kindLabel, subtitle: item.timeText, onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    if let url = item.imageURL {
                        CachedRemoteImage(url: url, contentMode: .fill)
                            .frame(height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.label)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.content.isEmpty {
                            Text(item.content)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !item.carInfo.isEmpty || !item.addressText.isEmpty {
                        AppleCard {
                            VStack(alignment: .leading, spacing: 12) {
                                if !item.carInfo.isEmpty {
                                    detailRow(icon: "scooter", title: "车辆", value: item.carInfo)
                                }
                                if !item.addressText.isEmpty {
                                    detailRow(icon: "mappin.and.ellipse", title: "位置", value: item.addressText)
                                }
                            }
                        }
                    }

                    if !item.coordinate.isEmpty {
                        Button {
                            openMap()
                        } label: {
                            Label("在地图中查看", systemImage: "map")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.brand)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Theme.brand.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if let url = item.jumpURL {
                        Link(destination: url) {
                            Text("查看详情")
                                .font(.system(size: 15, weight: .bold))
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

    private func openMap() {
        let parts = item.coordinate.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2 else { return }
        NavigationLauncher.openBest(lat: parts[1], lon: parts[0], name: item.addressText.isEmpty ? item.title : item.addressText)
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

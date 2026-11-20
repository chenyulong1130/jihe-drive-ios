import Foundation
import UserNotifications
import SwiftUI

/// 消息收件箱：list_v2 拉取、未读角标、本地通知。
@MainActor
final class MessageStore: ObservableObject {
    @Published private(set) var items: [InboxMessage] = []
    @Published private(set) var loading = false
    @Published var error: String?

    private let seenKey = "jihe.message.seen.ids"
    private var seeded = false

    var unreadCount: Int { items.filter(\.unread).count }

    func refresh(notifyNew: Bool = true) async {
        guard ZeehoClient.shared.isLoggedIn else {
            items = []
            return
        }
        loading = true
        error = nil
        defer { loading = false }

        var collected: [InboxMessage] = []
        // 文档明确 kind=3 系统消息；1/2 一并拉，空结果忽略
        for kind in [3, 2, 1] {
            let page = await fetchPage(kind: kind)
            collected.append(contentsOf: page)
        }
        var unique: [String: InboxMessage] = [:]
        for item in collected { unique[item.id] = item }
        let sorted = unique.values.sorted { lhs, rhs in
            if lhs.timeText == rhs.timeText { return lhs.id > rhs.id }
            return lhs.timeText > rhs.timeText
        }
        let localRead = readLocal()
        items = sorted.map { item in
            var copy = item
            if localRead.contains(item.id) { copy.unread = false }
            return copy
        }

        if !seeded {
            seedSeen(items.map(\.id))
            seeded = true
        } else if notifyNew {
            await notifyFresh(items)
        }
    }

    func open(_ item: InboxMessage) {
        markRead(item.id)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].unread = false
        }
        Task { await postRead(item.id) }
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Network

    private func fetchPage(kind: Int) async -> [InboxMessage] {
        guard let uid = ZeehoClient.shared.userId, !uid.isEmpty else { return [] }
        let query = [
            "userId": uid,
            "messageKind": "\(kind)",
            "page": "1",
            "pageSize": "20"
        ]
        guard let res = try? await ZeehoClient.shared.get(
            "/v1.0/mine/cfmotoservermine/app/Message/list_v2",
            query: query
        ) else { return [] }
        let code = ZeehoClient.codeString(res["code"])
        if !code.isEmpty, code != "10000" {
            if kind == 3 {
                error = ZeehoClient.errorText(res) ?? "消息加载失败"
            }
            return []
        }
        return InboxMessage.parseList(res)
    }

    private func postRead(_ id: String) async {
        _ = try? await ZeehoClient.shared.post(
            "/v1.0/mine/cfmotoservermine/app/Message/read",
            body: ["messageId": id, "id": id]
        )
    }

    // MARK: - Seen / notify

    private func notifyFresh(_ list: [InboxMessage]) async {
        let seen = readIDs()
        let fresh = list.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty else { return }
        seedSeen(seen.union(fresh.map(\.id)))
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        for item in fresh.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.content.isEmpty ? item.kindLabel : item.content
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "msg-\(item.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func seedSeen(_ ids: some Collection<String>) {
        UserDefaults.standard.set(Array(Set(ids)), forKey: seenKey)
    }

    private func readIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
    }

    private func markRead(_ id: String) {
        var ids = readIDs()
        ids.insert(id)
        seedSeen(ids)
        var local = readLocal()
        local.insert(id)
        UserDefaults.standard.set(Array(local), forKey: "jihe.message.local.read")
    }

    private func readLocal() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "jihe.message.local.read") ?? [])
    }
}

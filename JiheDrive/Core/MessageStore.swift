import Foundation
import UserNotifications
import SwiftUI
import UIKit

/// 消息收件箱：list_v2 拉取、未读角标、本地通知。前台约 2 分钟轮询一次。
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

        await hydrateUserId()

        var collected: [InboxMessage] = []
        var lastFail: String?
        // 官方 list_v2 用 messageVOList；不带 messageKind 一次拉全部分类
        let uid = ZeehoClient.shared.userId
        let page = await fetchPage(kind: nil, userId: uid)
        switch page {
        case .success(let list):
            collected = list
        case .failure(let message):
            lastFail = message
            if collected.isEmpty, let uid, !uid.isEmpty {
                for kind in [3, 2, 1] {
                    if case .success(let list) = await fetchPage(kind: kind, userId: uid) {
                        collected.append(contentsOf: list)
                    }
                }
            }
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

        if items.isEmpty, let lastFail {
            error = lastFail
        }

        if !seeded {
            // 已读的记入 seen，未读的走一次本地通知，避免整页历史刷屏
            seedSeen(items.filter { !$0.unread }.map(\.id))
            seeded = true
            if notifyNew {
                await notifyFresh(items)
            } else {
                seedSeen(items.map(\.id))
            }
        } else if notifyNew {
            await notifyFresh(items)
        }
        applyBadge()
    }

    func open(_ item: InboxMessage) {
        markRead(item.id)
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].unread = false
        }
        applyBadge()
        Task { await postRead(item.id) }
    }

    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: - Network

    private enum FetchResult {
        case success([InboxMessage])
        case failure(String)
    }

    private func hydrateUserId() async {
        if let uid = ZeehoClient.shared.userId, !uid.isEmpty { return }
        guard let res = try? await ZeehoClient.shared.get(
            "/v1.0/mine/cfmotoservermine/baseInfo",
            query: ["server_name": "SMART"]
        ) else { return }
        let data = res["data"] as? [String: Any]
        let uid = "\(data?["id"] ?? data?["userId"] ?? "")"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !uid.isEmpty, uid != "<null>" {
            ZeehoClient.shared.userId = uid
        }
    }

    private func fetchPage(kind: Int?, userId: String?) async -> FetchResult {
        var query = [
            "page": "1",
            "pageSize": "20"
        ]
        if let userId, !userId.isEmpty { query["userId"] = userId }
        if let kind { query["messageKind"] = "\(kind)" }
        do {
            let res = try await ZeehoClient.shared.get(
                "/v1.0/mine/cfmotoservermine/app/Message/list_v2",
                query: query
            )
            let code = ZeehoClient.codeString(res["code"])
            if !code.isEmpty, code != "10000" {
                return .failure(ZeehoClient.errorText(res) ?? "消息加载失败 (\(code))")
            }
            return .success(InboxMessage.parseList(res))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 官方 list_v2 的 messageId 是数字；unread=1 表示已读。
    /// 先走与列表同前缀的 GET/POST，避免只改本地、刷新后又变未读。
    private func postRead(_ id: String) async {
        await hydrateUserId()
        let uid = ZeehoClient.shared.userId ?? ""
        var query = ["messageId": id, "unread": "1"]
        if !uid.isEmpty { query["userId"] = uid }

        let getPaths = [
            "/v1.0/mine/cfmotoservermine/app/Message/read_v2",
            "/v1.0/mine/cfmotoservermine/app/Message/read",
            "/v1.0/mine/cfmotoservermine/app/Message/readMessage"
        ]
        for path in getPaths {
            if await accepted(try? await ZeehoClient.shared.get(path, query: query)) { return }
        }

        var body: [String: Any] = [
            "messageId": Int(id) ?? id,
            "unread": 1
        ]
        if !uid.isEmpty { body["userId"] = uid }
        let postPaths = [
            "/v1.0/mine/cfmotoservermine/app/Message/read_v2",
            "/v1.0/mine/cfmotoservermine/app/Message/read",
            "/v1.0/mine/cfmotoservermine/app/Message/readMessage"
        ]
        for path in postPaths {
            if await accepted(try? await ZeehoClient.shared.post(path, body: body)) { return }
        }

        body["messageIds"] = [Int(id) ?? id]
        if await accepted(try? await ZeehoClient.shared.post(
            "/v1.0/mine/cfmotoservermine/app/Message/read_v2",
            body: body
        )) { return }

        var h5Query = H5Client.mineQuery
        h5Query.merge(query) { _, new in new }
        _ = try? await H5Client.post("/cfmotoservermine/app/Message/read_v2", query: h5Query, body: body)
        applyBadge()
    }

    private func accepted(_ response: [String: Any]?) async -> Bool {
        guard let response else { return false }
        let code = ZeehoClient.codeString(response["code"])
        guard code.isEmpty || code == "10000" else { return false }
        applyBadge()
        return true
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
        let incoming = fresh.filter(\.unread)
        let notify = incoming.isEmpty ? Array(fresh.prefix(1)) : Array(incoming.prefix(3))
        for item in notify {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.content.isEmpty ? item.kindLabel : item.content
            content.sound = .default
            content.badge = NSNumber(value: unreadCount)
            let request = UNNotificationRequest(
                identifier: "msg-\(item.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func applyBadge() {
        let count = unreadCount
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
        UIApplication.shared.applicationIconBadgeNumber = count
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

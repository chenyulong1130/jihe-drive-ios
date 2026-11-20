import Foundation

/// 官方消息 `GET .../app/Message/list_v2`
/// 文档参数：`userId`、`messageKind=3`、`page`、`pageSize≤20`
struct InboxMessage: Identifiable, Hashable {
    var id: String
    var title: String
    var content: String
    var timeText: String
    var kind: Int
    var kindLabel: String
    var unread: Bool
    var imageURL: URL?
    var jumpURL: URL?
    /// 原始字段，详情页展示「接口返回参数」
    var fields: [(key: String, value: String)]

    static func == (lhs: InboxMessage, rhs: InboxMessage) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func parseList(_ response: [String: Any]) -> [InboxMessage] {
        items(in: response["data"] ?? response).compactMap(InboxMessage.init(json:))
    }

    init?(json: [String: Any]) {
        let id = text(json, ["id", "messageId", "msgId", "uuid", "noticeId"])
        guard !id.isEmpty else { return nil }
        self.id = id
        title = text(json, ["title", "messageTitle", "msgTitle", "subject", "name"])
        let rawContent = text(json, ["content", "messageContent", "msgContent", "text", "body"])
        content = Self.stripHTML(rawContent)
        if title.isEmpty {
            let clip = String(content.prefix(24))
            title = clip.isEmpty ? "系统消息" : clip
        }
        timeText = text(json, [
            "createDate", "createTime", "sendTime", "gmtCreate", "publishTime", "updateDate"
        ])
        kind = intValue(json, ["messageKind", "kind", "type", "messageType", "msgType"])
        kindLabel = Self.label(for: kind)
        unread = Self.isUnread(json)
        imageURL = urlValue(json, ["picUrl", "imageUrl", "picture", "coverUrl", "imgUrl"])
        jumpURL = urlValue(json, ["jumpUrl", "skipUrl", "linkUrl", "url", "h5Url", "targetUrl"])
        fields = json.keys.sorted().compactMap { key in
            let value = json[key]
            if value is NSNull { return (key, "null") }
            if JSONSerialization.isValidJSONObject(value as Any) ,
               let data = try? JSONSerialization.data(withJSONObject: value as Any),
               let encoded = String(data: data, encoding: .utf8) {
                return (key, encoded)
            }
            let encoded = "\(value ?? "")"
            return encoded == "<null>" ? (key, "null") : (key, encoded)
        }
    }

    static func label(for kind: Int) -> String {
        switch kind {
        case 1: return "活动"
        case 2: return "车辆"
        case 3: return "系统"
        default: return kind == 0 ? "通知" : "类型\(kind)"
        }
    }

    private static func isUnread(_ json: [String: Any]) -> Bool {
        if let flag = json["readFlag"] ?? json["isRead"] ?? json["readStatus"] ?? json["read"] {
            let text = "\(flag)".trimmingCharacters(in: .whitespaces).lowercased()
            if ["1", "true", "y", "read"].contains(text) { return false }
            if ["0", "false", "n", "unread"].contains(text) { return true }
        }
        return true
    }

    private static func items(in data: Any) -> [[String: Any]] {
        if let list = data as? [[String: Any]] { return list }
        guard let map = data as? [String: Any] else { return [] }
        for key in ["list", "records", "rows", "data", "messageList", "result"] {
            if let list = map[key] as? [[String: Any]] { return list }
        }
        return []
    }

    private static func stripHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func text(_ json: [String: Any], _ keys: [String]) -> String {
    for key in keys {
        guard let raw = json[key], !(raw is NSNull) else { continue }
        let value = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value != "<null>" { return value }
    }
    return ""
}

private func intValue(_ json: [String: Any], _ keys: [String]) -> Int {
    for key in keys {
        guard let raw = json[key], !(raw is NSNull) else { continue }
        if let number = raw as? NSNumber { return number.intValue }
        if let number = Int("\(raw)") { return number }
    }
    return 0
}

private func urlValue(_ json: [String: Any], _ keys: [String]) -> URL? {
    let value = text(json, keys)
    guard value.hasPrefix("http") else { return nil }
    return URL(string: value)
}

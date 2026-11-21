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
        guard !id.isEmpty, id != "0" else { return nil }
        self.id = id
        let extra = Self.parseExtra(json["extra"])
        title = text(json, ["title", "messageTitle", "msgTitle", "subject", "name", "content"])
        let rawContent = text(extra, ["detail", "body", "desc"])
            .ifEmpty(text(json, ["content", "messageContent", "msgContent", "text", "body"]))
        content = Self.stripHTML(rawContent)
        if title.isEmpty {
            let clip = String(content.prefix(24))
            title = clip.isEmpty ? "系统消息" : clip
        }
        if title == content {
            let detail = text(extra, ["detail"])
            if !detail.isEmpty { content = Self.stripHTML(detail) }
        }
        timeText = text(json, [
            "messageTime", "messageTimeStr", "createDate", "createTime", "sendTime", "gmtCreate", "publishTime", "updateDate"
        ])
        let rawType = intValue(json, ["messageType", "messageKind", "kind", "type", "msgType"])
        kind = Self.group(rawType)
        kindLabel = Self.label(for: rawType)
        unread = Self.isUnread(json)
        imageURL = urlValue(json, ["picUrl", "imageUrl", "picture", "coverUrl", "imgUrl"])
            ?? urlValue(extra, ["addressThumbnail", "picUrl", "imageUrl"])
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
        case 1, 2, 3: break
        default:
            switch kind / 100 {
            case 1: return "活动"
            case 3: return "车辆"
            default: break
            }
        }
        switch kind {
        case 1: return "活动"
        case 2: return "车辆"
        case 3: return "系统"
        default: return kind == 0 ? "通知" : "类型\(kind)"
        }
    }

    /// 筛选分组：1 活动 / 2 车辆 / 3 系统。官方 messageType 如 302、108。
    static func group(_ type: Int) -> Int {
        switch type {
        case 1, 2, 3: return type
        default:
            switch type / 100 {
            case 1: return 1
            case 3: return 2
            default: return 3
            }
        }
    }

    private static func isUnread(_ json: [String: Any]) -> Bool {
        // list_v2：unread=0 未读、unread=1 已读（与 noRead 计数一致）
        if let flag = json["unread"] ?? json["readFlag"] ?? json["isRead"] ?? json["readStatus"] ?? json["read"] {
            let text = "\(flag)".trimmingCharacters(in: .whitespaces).lowercased()
            if ["1", "true", "y", "read"].contains(text) { return false }
            if ["0", "false", "n", "unread"].contains(text) { return true }
        }
        return true
    }

    private static func parseExtra(_ raw: Any?) -> [String: Any] {
        if let map = raw as? [String: Any] { return map }
        guard let text = raw as? String, !text.isEmpty,
              let data = text.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return map
    }

    private static func items(in data: Any) -> [[String: Any]] {
        if let list = data as? [[String: Any]] { return list }
        guard let map = data as? [String: Any] else { return [] }
        for key in [
            "messageVOList", "messageList", "list", "records", "rows",
            "data", "result", "content", "items"
        ] {
            if let list = map[key] as? [[String: Any]] { return list }
            if let nested = map[key] {
                let dug = items(in: nested)
                if !dug.isEmpty { return dug }
            }
        }
        if let page = map["page"] ?? map["pageInfo"] ?? map["pageResult"] {
            let dug = items(in: page)
            if !dug.isEmpty { return dug }
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

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

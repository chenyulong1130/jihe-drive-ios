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
    var carInfo: String
    var addressText: String
    var coordinate: String
    var actorName: String
    var actorAvatar: URL?
    var quote: String
    var actionText: String
    var verified: Bool

    var isSocial: Bool { kind == 4 || !actorName.isEmpty || actorAvatar != nil }
    var isCampaign: Bool { kind == 1 && imageURL != nil }

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
        unread = Self.isUnread(json)
        imageURL = urlValue(json, ["picUrl", "imageUrl", "picture", "coverUrl", "imgUrl"])
            ?? urlValue(extra, ["picUrl", "imageUrl", "coverUrl"])
            ?? urlValue(extra, ["addressThumbnail"])
        jumpURL = urlValue(json, ["jumpUrl", "skipUrl", "linkUrl", "url", "h5Url", "targetUrl"])
        carInfo = text(extra, ["carInfo"]).replacingOccurrences(of: "车辆：", with: "")
        coordinate = text(extra, ["location"])
        addressText = Self.parseAddress(extra)
        actorName = text(extra, ["nickName", "fromNickName", "userName", "userNick", "fromUserName", "authorName"])
        actorAvatar = urlValue(extra, ["avatar", "headImg", "headImage", "fromAvatar", "userAvatar", "authorAvatar"])
        quote = Self.stripHTML(text(extra, ["postContent", "feedContent", "comment", "quote", "originContent", "sourceContent"]))
        actionText = text(extra, ["action", "actionText", "operateName", "operateTypeName"])
        verified = boolValue(extra, ["vip", "verified", "isVip", "official"])
        if actorName.isEmpty, let split = Self.splitSocialTitle(title) {
            actorName = split.name
            if actionText.isEmpty { actionText = split.action }
        }
        if actionText.isEmpty { actionText = Self.guessAction(title) }
        let social = !actorName.isEmpty || actorAvatar != nil || rawType / 100 == 2 || rawType == 4
        kind = social ? 4 : Self.group(rawType)
        kindLabel = Self.label(for: kind == 4 ? 4 : rawType)
    }

    private static func parseAddress(_ extra: [String: Any]) -> String {
        let nested = extra["address"]
        if let textValue = nested as? String,
           let data = textValue.data(using: .utf8),
           let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let name = text(map, ["name", "address"])
            if !name.isEmpty { return name }
        }
        if let map = nested as? [String: Any] {
            return text(map, ["name", "address"])
        }
        return text(extra, ["address"])
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
        case 4: return "互动"
        default: return kind == 0 ? "通知" : "类型\(kind)"
        }
    }

    /// 筛选分组：1 活动 / 2 车辆 / 3 系统 / 4 互动。官方 messageType 如 302、108。
    static func group(_ type: Int) -> Int {
        switch type {
        case 1, 2, 3, 4: return type
        default:
            switch type / 100 {
            case 1: return 1
            case 2: return 4
            case 3: return 2
            default: return 3
            }
        }
    }

    private static func splitSocialTitle(_ title: String) -> (name: String, action: String)? {
        for sep in ["。", ".", " "] {
            guard let range = title.range(of: sep) else { continue }
            let name = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let action = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if name.count >= 2, action.contains("点赞") || action.contains("评论") || action.contains("关注") || action.contains("回复") {
                return (name, action)
            }
        }
        return nil
    }

    private static func guessAction(_ title: String) -> String {
        if title.contains("点赞") { return "点赞了你的帖子" }
        if title.contains("评论") { return "评论了你的帖子" }
        if title.contains("关注") { return "关注了你" }
        if title.contains("回复") { return "回复了你" }
        return ""
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

private func boolValue(_ json: [String: Any], _ keys: [String]) -> Bool {
    for key in keys {
        guard let raw = json[key], !(raw is NSNull) else { continue }
        if let flag = raw as? Bool { return flag }
        let text = "\(raw)".trimmingCharacters(in: .whitespaces).lowercased()
        if ["1", "true", "y", "yes"].contains(text) { return true }
    }
    return false
}

private func urlValue(_ json: [String: Any], _ keys: [String]) -> URL? {
    let value = text(json, keys)
    guard value.hasPrefix("http") else { return nil }
    return URL(string: value)
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

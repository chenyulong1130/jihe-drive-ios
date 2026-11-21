import Foundation

/// 社区任务：发帖 → 点赞 → 分享 → 删帖（对齐小程序 communityTask.js）
/// 发帖只允许手动点一次；今日已发过就不再 create。
enum CommunityTask {
    private static let base = "/v1.0/social/cfmotoserversocial"
    private static let mine = "/v1.0/mine/cfmotoservermine"
    private static let postContent = "生尽欢，死无憾。"
    private static let lock = CommunityTaskLock()

    static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func isDoneToday(userId: String?) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        let key = markKey(userId)
        if UserDefaults.standard.bool(forKey: key) { return true }
        return UserDefaults(suiteName: WidgetSnapshot.suiteName)?.bool(forKey: key) ?? false
    }

    static func markDone(userId: String) {
        let key = markKey(userId)
        UserDefaults.standard.set(true, forKey: key)
        let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName)
        defaults?.set(true, forKey: key)
        defaults?.synchronize()
    }

    /// 今日社区是否完成：本地日期标记 → 积分明细 → 今日已有帖。任一命中都不再发帖。
    static func resolveDone(userId: String) async -> Bool {
        if isDoneToday(userId: userId) { return true }
        if await doneFromIntegral(userId: userId) {
            markDone(userId: userId)
            return true
        }
        if await postedToday(userId: userId) {
            markDone(userId: userId)
            return true
        }
        return false
    }

    static func dayKey(_ raw: String) -> String? {
        let normalized = raw
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        guard let match = normalized.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return String(normalized[match])
    }

    private static func markKey(_ userId: String) -> String {
        "jihe.community.done.\(userId).\(todayKey())"
    }

    struct Result: Sendable {
        var success: Bool
        var summary: String
    }

    static func run(userId: String) async -> Result {
        await lock.run {
            await runLocked(userId: userId)
        }
    }

    private static func runLocked(userId: String) async -> Result {
        if await resolveDone(userId: userId) {
            return Result(success: true, summary: "今日社区已完成")
        }
        var steps: [String] = []
        do {
            let create = try await ZeehoClient.shared.post(
                "\(base)/commonArticle",
                body: ["postcontent": postContent]
            )
            let createCode = ZeehoClient.codeString(create["code"])
            let createMsg = "\(create["message"] ?? create["msg"] ?? "")"
            let createOK = createCode == "10000"
            let createAlready = createMsg.contains("重复")
                || createMsg.contains("上限")
                || createMsg.contains("已发")
                || createMsg.contains("已完成")
                || createMsg.contains("频繁")
                || createMsg.contains("过多")
                || createMsg.contains("次数")
            steps.append(createOK ? "发帖:OK" : (createAlready ? "发帖:已做" : "发帖:FAIL"))
            // 发帖成功或今日额度已用：立刻落闸门，避免后续失败导致反复发帖
            if createOK || createAlready {
                markDone(userId: userId)
            }
            if createAlready, !createOK {
                return Result(success: true, summary: steps.joined(separator: " | "))
            }

            try await Task.sleep(nanoseconds: 350_000_000)
            let mineRes = try await ZeehoClient.shared.get(
                "\(base)/community/mineArticleInfo",
                query: ["userId": userId, "page": "1", "pageSize": "10"]
            )
            var postId = firstID(mineRes["data"]) ?? firstID(create["data"])
            var articleId = firstID(mineRes["data"], keys: ["articleId", "articleID", "tuuid", "uuid", "postId", "id"])
                ?? postId

            if postId == nil {
                let feed = try await ZeehoClient.shared.get(
                    "\(base)/community/qbTzInfoNewV2",
                    query: ["page": "1", "pageSize": "20", "postModule": "2", "slidingType": "1"]
                )
                postId = ownPostID(feed["data"], userId: userId)
                articleId = postId
            }

            guard let postId else {
                return Result(success: false, summary: steps.joined(separator: " | "))
            }

            try await Task.sleep(nanoseconds: 300_000_000)
            let like = try await ZeehoClient.shared.post(
                "\(base)/socialCommu/likeFavoriteInfo",
                body: ["postId": postId, "kindFlag": "0"]
            )
            steps.append(ZeehoClient.codeString(like["code"]) == "10000" ? "点赞:OK" : "点赞:FAIL")

            try await Task.sleep(nanoseconds: 300_000_000)
            let share = try await ZeehoClient.shared.put("\(base)/article/share/\(postId)")
            steps.append(ZeehoClient.codeString(share["code"]) == "10000" ? "分享:OK" : "分享:FAIL")
            _ = try? await ZeehoClient.shared.get("\(mine)/integral/adjustByShare")

            if let articleId, !articleId.isEmpty {
                try await Task.sleep(nanoseconds: 300_000_000)
                let del = try await ZeehoClient.shared.delete(
                    "\(base)/commonArticle/deleteArticle?articleId=\(articleId)&postType=0"
                )
                steps.append(ZeehoClient.codeString(del["code"]) == "10000" ? "删除:OK" : "删除:跳过")
            }

            markDone(userId: userId)
            return Result(success: true, summary: steps.joined(separator: " | "))
        } catch {
            steps.append(error.localizedDescription)
            return Result(success: false, summary: steps.joined(separator: " | "))
        }
    }

    static func doneFromIntegral(userId: String) async -> Bool {
        guard let res = try? await ZeehoClient.shared.get(
            "\(mine)/integral/getByUserId",
            query: ["userId": userId, "page": "1", "pageSize": "30"]
        ) else { return false }
        let list = integralList(res["data"])
        let today = todayKey()
        var post = false, like = false, share = false
        for item in list {
            let name = "\(item["name"] ?? item["integralName"] ?? item["ruleName"] ?? item["title"] ?? "")"
            let remarks = "\(item["remarks"] ?? "")"
            if (name + remarks).contains("社区任务") { return true }
            let when = "\(item["createDate"] ?? item["updateDate"] ?? item["createTime"] ?? "")"
            let key = dayKey(when)
            let todayHit = key == today || (quotaFull(remarks) && (key == nil || key == today))
            guard todayHit else { continue }
            if name.contains("发帖") || name.contains("帖子") || name.contains("发布") { post = true }
            else if name.contains("点赞") { like = true }
            else if name.contains("分享") { share = true }
            if quotaFull(remarks) { return true }
        }
        // 今天已经拿过发帖分，就视为做过，绝不再 create
        return post || (like && share)
    }

    /// 我的帖子里今天已经有文，同样视为已发过
    static func postedToday(userId: String) async -> Bool {
        guard let res = try? await ZeehoClient.shared.get(
            "\(base)/community/mineArticleInfo",
            query: ["userId": userId, "page": "1", "pageSize": "10"]
        ) else { return false }
        let list: [[String: Any]]
        if let arr = res["data"] as? [[String: Any]] {
            list = arr
        } else if let map = res["data"] as? [String: Any] {
            list = (map["list"] as? [[String: Any]]) ?? (map["records"] as? [[String: Any]]) ?? []
        } else {
            list = []
        }
        let today = todayKey()
        return list.contains { item in
            let when = "\(item["createDate"] ?? item["createTime"] ?? item["updateDate"] ?? "")"
            guard dayKey(when) == today else { return false }
            let text = "\(item["postcontent"] ?? item["content"] ?? item["postContent"] ?? "")"
            return text.contains("生尽欢") || text.isEmpty == false
        }
    }

    /// remarks 形如「每日上限1次  (1/1)」表示今日额度已用完
    private static func quotaFull(_ remarks: String) -> Bool {
        guard let match = remarks.range(of: #"\(\s*(\d+)\s*/\s*(\d+)\s*\)"#, options: .regularExpression) else {
            return false
        }
        let inner = String(remarks[match]).filter { $0.isNumber || $0 == "/" }
        let parts = inner.split(separator: "/")
        guard parts.count == 2, let used = Int(parts[0]), let cap = Int(parts[1]), cap > 0 else {
            return false
        }
        return used >= cap
    }

    private static func integralList(_ data: Any?) -> [[String: Any]] {
        if let list = data as? [[String: Any]] { return list }
        guard let map = data as? [String: Any] else { return [] }
        if let list = map["list"] as? [[String: Any]] { return list }
        for value in map.values {
            guard let list = value as? [[String: Any]], let first = list.first else { continue }
            if first["integralNumber"] != nil || first["remarks"] != nil || first["integralType"] != nil {
                return list
            }
        }
        return []
    }

    private static func firstID(_ data: Any?, keys: [String] = ["postId", "postid", "uuid", "tuuid", "id", "articleId"]) -> String? {
        let item: [String: Any]?
        if let list = data as? [[String: Any]] {
            item = list.first
        } else if let map = data as? [String: Any] {
            if let list = map["list"] as? [[String: Any]] ?? map["records"] as? [[String: Any]] {
                item = list.first
            } else {
                item = map
            }
        } else {
            item = nil
        }
        guard let item else { return nil }
        for key in keys {
            let text = "\(item[key] ?? "")".trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text != "<null>" { return text }
        }
        return nil
    }

    private static func ownPostID(_ data: Any?, userId: String) -> String? {
        let list: [[String: Any]]
        if let array = data as? [[String: Any]] {
            list = array
        } else if let map = data as? [String: Any] {
            list = (map["list"] as? [[String: Any]]) ?? (map["records"] as? [[String: Any]]) ?? []
        } else {
            list = []
        }
        let own = list.first { item in
            let uid = "\(item["userId"] ?? item["createBy"] ?? item["uid"] ?? "")"
            return uid == userId
        }
        return firstID(own)
    }
}

/// 串行执行发帖，避免小组件刷新和页面同步同时 create
private actor CommunityTaskLock {
    func run(_ body: @Sendable () async -> CommunityTask.Result) async -> CommunityTask.Result {
        await body()
    }
}

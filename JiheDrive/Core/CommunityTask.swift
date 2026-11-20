import Foundation

/// 社区任务：发帖 → 点赞 → 分享 → 删帖（对齐小程序 communityTask.js）
enum CommunityTask {
    private static let base = "/v1.0/social/cfmotoserversocial"
    private static let mine = "/v1.0/mine/cfmotoservermine"
    private static let postContent = "生尽欢，死无憾。"

    static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func isDoneToday(userId: String?) -> Bool {
        guard let userId, !userId.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: markKey(userId))
    }

    static func markDone(userId: String) {
        UserDefaults.standard.set(true, forKey: markKey(userId))
    }

    private static func markKey(_ userId: String) -> String {
        "jihe.community.done.\(userId).\(todayKey())"
    }

    struct Result {
        var success: Bool
        var summary: String
    }

    static func run(userId: String) async -> Result {
        var steps: [String] = []
        do {
            let create = try await ZeehoClient.shared.post(
                "\(base)/commonArticle",
                body: ["postcontent": postContent]
            )
            let createOK = ZeehoClient.codeString(create["code"]) == "10000"
            steps.append(createOK ? "发帖:OK" : "发帖:FAIL")

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
            let name = "\(item["name"] ?? item["integralName"] ?? item["ruleName"] ?? "")"
            let remarks = "\(item["remarks"] ?? "")"
            if (name + remarks).contains("社区任务") { return true }
            let when = "\(item["createDate"] ?? "")"
            guard when.contains(today) else { continue }
            if name.contains("发帖") || name.contains("帖子") || name.contains("发布") { post = true }
            else if name.contains("点赞") { like = true }
            else if name.contains("分享") { share = true }
        }
        return post && like && share
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

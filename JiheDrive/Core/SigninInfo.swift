import Foundation

struct SigninScoreRule: Identifiable, Hashable {
    var id: Int { days }
    let days: Int
    let score: Int
}

struct SigninInfo: Hashable {
    var days: Int = 0
    var continueDays: Int = 0
    var lastTime: String?
    var scoreList: [SigninScoreRule] = []

    var signedInToday: Bool { Self.isToday(lastTime) }

    var daysUntilLottery: Int {
        if continueDays <= 0 { return 30 }
        if continueDays % 30 == 0 { return 0 }
        return 30 - (continueDays % 30)
    }

    var cycleDayInRound: Int {
        if continueDays <= 0 { return 0 }
        return continueDays % 30 == 0 ? 30 : continueDays % 30
    }

    var todayRuleScore: Int {
        guard !scoreList.isEmpty, days > 0 else { return 0 }
        let current = days % 7 == 0 ? 7 : days % 7
        return scoreList.first(where: { $0.days == current })?.score ?? 0
    }

    var todayEarnedScore: Int { signedInToday ? todayRuleScore : 0 }

    static func isToday(_ lastTime: String?) -> Bool {
        guard let lastTime, !lastTime.isEmpty else { return false }
        return CommunityTask.dayKey(lastTime) == CommunityTask.todayKey()
    }

    static func parse(_ data: Any?) -> SigninInfo? {
        guard let root = data as? [String: Any] else { return nil }
        let map = (root["signinData"] as? [String: Any]) ?? root
        guard map["scoreList"] != nil || map["continueDays"] != nil
                || map["days"] != nil || map["lastTime"] != nil else {
            return nil
        }
        let rules = ((map["scoreList"] as? [[String: Any]]) ?? []).compactMap { item -> SigninScoreRule? in
            let days = Int("\(item["days"] ?? "")") ?? 0
            let score = Int("\(item["score"] ?? "")") ?? 0
            guard days > 0 else { return nil }
            return SigninScoreRule(days: days, score: score)
        }
        return SigninInfo(
            days: Int("\(map["days"] ?? "")") ?? 0,
            continueDays: Int("\(map["continueDays"] ?? "")") ?? 0,
            lastTime: {
                let text = "\(map["lastTime"] ?? "")".trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }(),
            scoreList: rules
        )
    }
}

struct SigninPrize: Identifiable, Hashable {
    var id: String
    var name: String
    var imageURL: URL?
    var createDate: String
    var distributed: Bool

    static func parse(_ data: Any?) -> [SigninPrize] {
        let items: [[String: Any]]
        if let list = data as? [[String: Any]] {
            items = list
        } else if let map = data as? [String: Any] {
            items = (map["list"] as? [[String: Any]])
                ?? (map["records"] as? [[String: Any]])
                ?? (map["rows"] as? [[String: Any]])
                ?? []
        } else {
            items = []
        }
        return items.compactMap { item in
            let id = Self.text(item["uuid"] ?? item["id"])
            let name = Self.text(item["prizesName"] ?? item["name"] ?? item["prizeName"])
            guard !id.isEmpty || !name.isEmpty else { return nil }
            let date = Self.text(item["createDate"])
            let dist = Self.text(item["distribute"])
            return SigninPrize(
                id: id.isEmpty ? name + date : id,
                name: name.isEmpty ? "盲盒奖品" : name,
                imageURL: Self.imageURL(item["fileurl"] ?? item["imageUrl"] ?? item["prizeUrl"] ?? item["url"]),
                createDate: date,
                distributed: dist == "1" || dist.lowercased() == "true"
            )
        }
    }

    private static func text(_ raw: Any?) -> String {
        guard let raw, !(raw is NSNull) else { return "" }
        let value = "\(raw)".trimmingCharacters(in: .whitespaces)
        return value == "<null>" ? "" : value
    }

    private static func imageURL(_ raw: Any?) -> URL? {
        let value = text(raw)
        if value.isEmpty { return nil }
        if value.hasPrefix("http") { return URL(string: value) }
        if value.hasPrefix("//") { return URL(string: "https:" + value) }
        if value.hasPrefix("/") { return URL(string: H5Client.host + value) }
        return URL(string: value)
    }
}

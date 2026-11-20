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
        if continueDays > 0, continueDays % 30 == 0 { return 0 }
        let left = 30 - (continueDays % 30)
        return left == 30 ? 0 : left
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

import Foundation
import SwiftUI

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
        let datePart = lastTime.split(separator: " ").first.map(String.init) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return datePart == formatter.string(from: Date())
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

@MainActor
final class SigninStore: ObservableObject {
    @Published private(set) var info: SigninInfo?
    @Published private(set) var totalSignCount: Int?
    @Published private(set) var signedTodayByCount: Bool?
    @Published private(set) var loading = false
    @Published private(set) var signingIn = false
    @Published private(set) var communityRunning = false
    @Published private(set) var communityDone = false
    @Published var error: String?

    var signedToday: Bool {
        signedTodayByCount ?? info?.signedInToday ?? false
    }

    func refresh() async {
        guard ZeehoClient.shared.isLoggedIn else {
            info = nil
            totalSignCount = nil
            signedTodayByCount = nil
            return
        }
        loading = true
        error = nil
        defer { loading = false }

        var parsed: SigninInfo?
        do {
            var res = try await H5Client.get("/cfmotoservermine/H5/signin/info")
            if ZeehoClient.codeString(res["code"]) != "10000" {
                res = try await H5Client.get("/cfmotoservermine/H5/signin")
            }
            if ZeehoClient.codeString(res["code"]) == "10000" {
                parsed = SigninInfo.parse(res["data"])
            } else {
                error = ZeehoClient.errorText(res) ?? "签到数据加载失败"
            }
        } catch {
            self.error = error.localizedDescription
        }

        info = parsed
        if let uid = ZeehoClient.shared.userId {
            var done = CommunityTask.isDoneToday(userId: uid)
            if !done {
                done = await CommunityTask.doneFromIntegral(userId: uid)
            }
            communityDone = done
        }

        do {
            let countRes = try await ZeehoClient.shared.get(
                "/v1.0/mine/cfmotoservermine/signin/count"
            )
            if ZeehoClient.codeString(countRes["code"]) == "10000",
               let data = countRes["data"] as? [String: Any] {
                totalSignCount = Int("\(data["count"] ?? "")")
                signedTodayByCount = "\(data["signStatus"] ?? "")" == "1"
            }
        } catch {
            // count 失败不挡主面板
        }
    }

    func signInToday() async {
        guard !signingIn, !signedToday else { return }
        signingIn = true
        defer { signingIn = false }
        do {
            let res = try await H5Client.post("/cfmotoservermine/H5/signin")
            let code = ZeehoClient.codeString(res["code"])
            guard code == "10000" else {
                error = ZeehoClient.errorText(res) ?? "签到失败"
                return
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runCommunity() async {
        guard !communityRunning, !communityDone else { return }
        guard let uid = ZeehoClient.shared.userId, !uid.isEmpty else {
            error = "缺少账号 ID，无法做社区任务"
            return
        }
        communityRunning = true
        defer { communityRunning = false }
        let result = await CommunityTask.run(userId: uid)
        communityDone = result.success || CommunityTask.isDoneToday(userId: uid)
        if !result.success {
            error = result.summary
        }
        await refresh()
    }
}

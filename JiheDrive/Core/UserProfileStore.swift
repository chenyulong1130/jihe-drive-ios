import Foundation
import SwiftUI

/// 对齐小程序「我的」：baseInfo 拿 userId，setting/{userId} 拿头像/昵称/积分。
@MainActor
final class UserProfileStore: ObservableObject {
    struct Profile: Equatable {
        var userId: String
        var nickName: String
        var signature: String
        var avatarURL: URL?
        var score: Int
        var userShowId: String
        var postsNum: Int
        var fansNum: Int
        var likeTimes: Int
    }

    @Published private(set) var profile: Profile?
    @Published private(set) var loading = false

    func refresh() async {
        guard ZeehoClient.shared.isLoggedIn else {
            profile = nil
            return
        }
        loading = profile == nil
        defer { loading = false }

        var uid = ZeehoClient.shared.userId ?? ""
        if uid.isEmpty {
            uid = await fetchUserId()
            if !uid.isEmpty { ZeehoClient.shared.userId = uid }
        }
        guard !uid.isEmpty else { return }

        let encoded = uid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uid
        guard let res = try? await ZeehoClient.shared.get("/v1.0/mine/cfmotoservermine/setting/\(encoded)"),
              ZeehoClient.codeString(res["code"]).isEmpty || ZeehoClient.codeString(res["code"]) == "10000",
              let data = res["data"] as? [String: Any] else {
            return
        }
        profile = Profile(
            userId: pick(data["id"], data["userId"], fallback: uid),
            nickName: pick(data["nickName"], data["memoName"], fallback: "极核骑手"),
            signature: pick(data["signature"]),
            avatarURL: url(data["avatar"], data["avatarUrl"], data["headImg"], data["headImage"]),
            score: int(data["score"]),
            userShowId: pick(data["userShowId"]),
            postsNum: int(data["postsNum"]),
            fansNum: int(data["fansNum"]),
            likeTimes: int(data["likeTimes"])
        )
    }

    func clear() {
        profile = nil
    }

    private func fetchUserId() async -> String {
        guard let res = try? await ZeehoClient.shared.get(
            "/v1.0/mine/cfmotoservermine/baseInfo",
            query: ["server_name": "SMART"]
        ) else { return "" }
        let data = res["data"] as? [String: Any]
        return pick(data?["id"], data?["userId"])
    }

    private func pick(_ values: Any?..., fallback: String = "") -> String {
        for value in values {
            guard let value, !(value is NSNull) else { continue }
            let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != "<null>" { return text }
        }
        return fallback
    }

    private func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        return Int("\(value ?? "")") ?? 0
    }

    private func url(_ values: Any?...) -> URL? {
        for value in values {
            let raw = pick(value)
            guard raw.hasPrefix("http") else { continue }
            return URL(string: raw)
        }
        return nil
    }
}

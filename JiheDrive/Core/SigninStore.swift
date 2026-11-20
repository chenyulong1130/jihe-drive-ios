import Foundation
import SwiftUI

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
    @Published private(set) var prizes: [SigninPrize] = []
    @Published private(set) var prizesLoading = false

    var signedToday: Bool {
        signedTodayByCount ?? info?.signedInToday ?? false
    }

    func applyWidgetSnap(_ snap: WidgetSnap) {
        signedTodayByCount = snap.signedToday
        communityDone = snap.communityDone
        if snap.totalSignCount > 0 {
            totalSignCount = snap.totalSignCount
        }
        if var current = info {
            if snap.continueDays > 0 { current.continueDays = snap.continueDays }
            info = current
        } else if snap.continueDays > 0 || snap.signedToday {
            info = SigninInfo(
                days: snap.totalSignCount,
                continueDays: snap.continueDays,
                lastTime: snap.signedToday ? CommunityTask.todayKey() : nil,
                scoreList: []
            )
        }
    }

    /// 小组件同步：复用车辆页已拉过的数据，不再打 list/homepage/胎压/今日骑行。
    func syncWidget(model: AppModel, ride: RideTrackService.RideExtra?) async {
        let snap = await WidgetLiveSync.refresh(
            existing: .init(
                vehicle: model.selectedVehicle,
                tire: model.tire,
                ride: ride,
                signedToday: signedToday,
                communityDone: communityDone,
                continueDays: info?.continueDays,
                totalSignCount: totalSignCount,
                todayScore: info?.todayRuleScore
            ),
            mode: .reuse
        )
        applyWidgetSnap(snap)
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
        if let uid = ZeehoClient.shared.userId, !uid.isEmpty {
            communityDone = await CommunityTask.resolveDone(userId: uid)
        } else {
            communityDone = false
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

    func loadPrizes() async {
        prizesLoading = true
        defer { prizesLoading = false }
        var query = H5Client.mineQuery
        query["page"] = "1"
        query["pageSize"] = "20"
        guard let res = try? await H5Client.get("/cfmotoservermine/H5/signin/prizesDetail", query: query) else {
            return
        }
        let code = ZeehoClient.codeString(res["code"])
        guard code.isEmpty || code == "10000" else { return }
        prizes = SigninPrize.parse(res["data"])
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
            await loadPrizes()
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

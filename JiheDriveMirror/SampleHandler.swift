import Foundation
import ReplayKit
import UIKit

/// 整屏镜像广播扩展：系统整屏（含高德等任意 App）→ 解码 → 缩放重编码
/// （1024×480 @25fps / 2.5Mbps，与 CarWithin 验证参数一致）→ 极核仪表 PXC。
///
/// 生命周期：控制中心发起广播 → broadcastStarted → processSampleBuffer(视频)
/// → broadcastFinished。仪表连接失败会自动重试（等待仪表打开投屏页）。
final class SampleHandler: RPBroadcastSampleHandler {

    private let link = ZeehoMirrorLink()
    private let transcoder = CPVideoTranscoder()
    private var feeder: Task<Void, Never>?
    private var started = false
    private var firstFrame = true
    private var nextFrameTime: TimeInterval = 0
    private var dashboardIP = "192.168.0.1"
    private var localIP: String?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 用户在主 App 里点过「开始投屏」才有广播入口；配置从 App Group 读取
        let group = UserDefaults(suiteName: MirrorLogStore.appGroupID)
        dashboardIP = group?.string(forKey: "mirror.dashboard.ip").flatMap {
            $0.isEmpty ? nil : $0
        } ?? "192.168.0.1"
        transcoder.scaleMode = group?.string(forKey: "mirror.crop") == "fit" ? .fit : .crop
        MirrorLogStore.append("整屏镜像广播启动（仪表 \(dashboardIP)，裁剪模式 \(transcoder.scaleMode == .fit ? "完整画面" : "居中裁剪")）",
                              source: "ext")
        writeStatus("正在连接极核仪表…")

        link.onLog = { [weak self] message in
            MirrorLogStore.append(message, source: "ext")
        }
        link.onState = { [weak self] state in
            switch state {
            case .listening: self?.writeStatus("已监听仪表回连端口…")
            case .announcing: self?.writeStatus("正在请求仪表投屏…")
            case .negotiating: self?.writeStatus("仪表协商中…")
            case .ready: self?.writeStatus("已就绪，等待仪表拉帧")
            case .streaming: self?.writeStatus("正在投屏 · 1024×480 · H.264")
            case .failed(let reason): self?.writeStatus("失败：\(reason)")
            case .closed: self?.writeStatus("已停止")
            default: break
            }
        }

        started = true
        link.start(localIP: localIP ?? "", targetIP: dashboardIP)
        startFeeder()

        // 仪表未开投屏页时自动重试连接（最多 60 秒）
        scheduleRetryLoop()
    }

    override func broadcastFinished() {
        MirrorLogStore.append("整屏镜像广播结束", source: "ext")
        writeStatus("已停止")
        feeder?.cancel()
        feeder = nil
        started = false
        link.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard started else { return }
        switch sampleBufferType {
        case .video:
            transcoder.append(sampleBuffer: sampleBuffer)
        case .audioApp, .audioMic:
            break // 音频留在手机
        @unknown default:
            break
        }
    }

    // MARK: - 喂帧循环（仪表拉一帧发一帧，25fps 节流）

    private func startFeeder() {
        feeder?.cancel()
        feeder = Task.detached { [weak self] in
            var first = true
            while !Task.isCancelled, let self, self.started, !self.link.isClosed {
                guard self.link.waitForFrameRequest() else {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                // 25fps 节流：仪表拉快也不超发
                let now = ProcessInfo.processInfo.systemUptime
                let remaining = self.nextFrameTime - now
                if remaining > 0 {
                    Thread.sleep(forTimeInterval: min(remaining, 0.04))
                    continue
                }
                self.nextFrameTime = ProcessInfo.processInfo.systemUptime + 1.0 / 25.0
                guard let frame = self.transcoder.encodeLatest(forceKeyframe: first) else {
                    continue
                }
                self.link.sendVideoFrame(frame, isFirstFrame: first)
                if first {
                    first = false
                    MirrorLogStore.append("已发送首帧（IDR）", source: "ext")
                }
            }
        }
    }

    /// 仪表侧失败时自动重试：每 3 秒重新发起 announce/监听，最多 20 次（约 60 秒）。
    private func scheduleRetryLoop() {
        let group = UserDefaults(suiteName: MirrorLogStore.appGroupID)
        var attempts = 0
        Task.detached { [weak self] in
            while !Task.isCancelled, let self, self.started {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.started, self.link.isClosed else { continue }
                attempts += 1
                guard attempts <= 20 else {
                    self.writeStatus("仪表连接失败：请打开仪表投屏页后重新发起广播")
                    self.finishBroadcastWithError(NSError(
                        domain: "com.liruixin.jihedrive.mirror", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "仪表连接失败，请打开仪表投屏页后重试"]))
                    return
                }
                self.writeStatus("第 \(attempts) 次重试连接仪表…")
                self.link.start(localIP: self.localIP ?? "", targetIP: self.dashboardIP)
                self.startFeeder()
            }
        }
        _ = group
    }

    // MARK: - 状态回传（主 App 轮询读取）

    private func writeStatus(_ text: String) {
        let group = UserDefaults(suiteName: MirrorLogStore.appGroupID)
        group?.set(text, forKey: "mirror.status")
        group?.set(Date().timeIntervalSince1970, forKey: "mirror.status.ts")
    }
}

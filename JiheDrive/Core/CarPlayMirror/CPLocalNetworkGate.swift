import Foundation
import Network

/// 触发 iOS「本地网络」权限弹窗，并粗测授权是否可用。
/// 日志里 -65555 NoAuth 就是没授权 / Info.plist 缺 NSBonjourServices。
enum CPLocalNetworkGate {

    private static var browser: NWBrowser?
    private static var probed = false

    /// 启动一次 Bonjour 浏览以弹出系统授权框（幂等）。
    static func requestAuthorizationIfNeeded() {
        guard !probed else { return }
        probed = true
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_tds-carkit._tcp", domain: "local."), using: params)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                MirrorLogStore.append("本地网络权限：Bonjour 浏览就绪")
            case .failed(let error):
                MirrorLogStore.append("本地网络权限：浏览失败 \(error.localizedDescription)")
            case .waiting(let error):
                MirrorLogStore.append("本地网络权限：等待中 \(error.localizedDescription)")
            default:
                break
            }
        }
        browser.start(queue: .main)
        Self.browser = browser
        // 几秒后停掉，只为触发授权
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            browser.cancel()
            if Self.browser === browser { Self.browser = nil }
        }
    }

    /// 粗测：能否在本机回环起一个临时 TCP 监听（不涉及 Bonjour）。
    static func probeTCPListen() async -> (ok: Bool, detail: String) {
        await withCheckedContinuation { cont in
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                var finished = false
                func finish(_ ok: Bool, _ detail: String) {
                    guard !finished else { return }
                    finished = true
                    listener.cancel()
                    cont.resume(returning: (ok, detail))
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(true, "本机 TCP 监听正常（端口 \(listener.port?.rawValue ?? 0)）")
                    case .failed(let error):
                        let text = error.localizedDescription
                        if text.contains("NoAuth") || text.contains("-65555") {
                            finish(false, "本地网络未授权（-65555 NoAuth）。请到 设置 → 极核智行 → 本地网络 打开。")
                        } else {
                            finish(false, "TCP 监听失败：\(text)")
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                    finish(false, "TCP 监听探测超时——请确认已允许本地网络权限")
                }
            } catch {
                cont.resume(returning: (false, "无法创建探测监听：\(error.localizedDescription)"))
            }
        }
    }
}

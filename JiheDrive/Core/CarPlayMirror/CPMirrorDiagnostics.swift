import Foundation
import Network

/// 投屏预检与诊断：启动前逐项检查，失败给出行内原因；
/// 另提供 CoreAccessories 传输探针（不启动 CarPlay，仅验证私有桥可用）。
enum CPMirrorDiagnostics {

    struct CheckResult: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
        /// 仅提示（不阻止启动），例如仪表未开投屏页
        let warning: Bool
    }

    // MARK: - 预检

    /// 逐项检查并等待全部完成（总超时约 5 秒）。
    static func preflight(dashboardIP: String) async -> [CheckResult] {
        async let identity = checkIdentity()
        async let wifi = checkWiFi()
        async let local = checkLocalIP()
        async let dashboard = checkDashboard(dashboardIP)
        return await [identity, wifi, local, dashboard]
    }

    /// 配件身份：直接走 load()——Keychain / 内置资源 / IdentityImport 暂存目录
    /// 都会被尝试导入，报错信息来自真实失败原因（缺失 / 不完整 / 不配对）。
    static func checkIdentity() async -> CheckResult {
        do {
            _ = try CPAccessoryIdentity.load()
            return CheckResult(name: "配件身份", passed: true, detail: "证书链与私钥配对自检通过", warning: false)
        } catch {
            return CheckResult(name: "配件身份", passed: false,
                               detail: error.localizedDescription, warning: false)
        }
    }

    /// Wi-Fi：当前 SSID 是否可读。
    static func checkWiFi() async -> CheckResult {
        await MainActor.run {
            if let ssid = MirrorStore.currentSSIDSnapshot(), !ssid.isEmpty {
                return CheckResult(name: "Wi-Fi 连接", passed: true, detail: "已连接 \(ssid)", warning: false)
            }
            return CheckResult(name: "Wi-Fi 连接", passed: false,
                detail: "未检测到 Wi-Fi。加入仪表热点需要定位权限（iOS 要求）；可在系统设置 → 隐私 → 定位服务中允许极核智行。",
                warning: false)
        }
    }

    /// 本机 IP：en0 是否拿到 IPv4（CarPlay StartSession 与 PXC 回连都需要）。
    static func checkLocalIP() async -> CheckResult {
        if let address = localIPv4() {
            return CheckResult(name: "本机地址", passed: true, detail: "en0 = \(address)", warning: false)
        }
        return CheckResult(name: "本机地址", passed: false,
                           detail: "未获取到 Wi-Fi 网段地址（请确认已加入仪表热点）", warning: false)
    }

    /// 仪表可达性：尝试连 10930 公告端口（仪表须已打开投屏页）。
    /// 失败仅提示不阻断——可以先启动投屏再开仪表。
    static func checkDashboard(_ ip: String) async -> CheckResult {
        guard !ip.isEmpty else {
            return CheckResult(name: "仪表可达", passed: false, detail: "未填写仪表 IP", warning: false)
        }
        let reachable = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(ip),
                                          port: NWEndpoint.Port(rawValue: 10930)!,
                                          using: .tcp)
            let box = NSLock()
            var finished = false
            func finish(_ value: Bool) {
                box.lock()
                let already = finished
                finished = true
                box.unlock()
                if !already { cont.resume(returning: value) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true); connection.cancel()
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                finish(false)
                connection.cancel()
            }
        }
        if reachable {
            return CheckResult(name: "仪表可达", passed: true, detail: "\(ip):10930 可连接（投屏页已开启）", warning: false)
        }
        return CheckResult(name: "仪表可达", passed: false,
            detail: "\(ip):10930 暂时连不上——请确认：① 已加入仪表热点 ② 仪表已打开投屏页。可稍后重试或直接启动投屏。",
            warning: true)
    }

    // MARK: - CoreAccessories 传输探针

    /// 只发布/销毁 iAP2 endpoint，验证私有桥在本机签名与系统版本下是否可用。
    static func transportProbe() async -> String {
        let transport = CPDirectAccessoryTransport()
        do {
            try transport.start(withIdentifier: CPDeviceID.persistent() + "-probe", transportType: 2)
            // 短暂保活，观察是否有异常（框架在主 run loop 上回调）
            try await Task.sleep(nanoseconds: 1_200_000_000)
            transport.stop()
            MirrorLogStore.append("传输探针：成功创建并销毁 protocol-4 iAP2 endpoint")
            return "探针通过：CoreAccessories 已成功发布 iAP2 endpoint（私有桥可用）"
        } catch {
            transport.stop()
            let reason = error.localizedDescription
            MirrorLogStore.append("传输探针失败：\(reason)")
            return "探针失败：\(reason)"
        }
    }

    // MARK: - 工具

    static func localIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let interface = ptr.pointee
            if let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                    }
                }
            }
            cursor = interface.ifa_next != nil ? ptr.pointee.ifa_next : nil
        }
        return address
    }
}

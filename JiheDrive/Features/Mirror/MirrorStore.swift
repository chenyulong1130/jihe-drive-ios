import Foundation
import CoreLocation
import NetworkExtension
import Security
import SystemConfiguration.CaptiveNetwork

/// 投屏页状态：Wi-Fi 自动检测（SSID）、按 SSID 记住密码、一键加入仪表热点、
/// 仪表地址设置与投屏状态回显。
final class MirrorStore: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published var currentSSID: String?
    /// 可手填的 Wi-Fi 名称：定位读不到 SSID 时也能发起 CarPlay 会话。
    @Published var wifiSSID: String = ""
    @Published var locationDenied = false
    @Published var dashboardIP: String
    @Published var wifiPassword: String = ""
    @Published var rememberedPassword = false
    @Published var hotspotStatus: String?
    @Published var identityReady = false
    @Published var identityHint: String?
    /// 整屏镜像裁剪：crop = 居中裁横幅（默认，导航信息区），fit = 完整画面加黑边
    @Published var cropMode: String
    /// 是否把 CarPlay 画面转投极核仪表；默认关——先把本机 CarPlay 唤起，再开仪表投屏。
    @Published var castToZeeho: Bool

    private let locationManager = CLLocationManager()
    private static let wifiService = "com.qianxu.jihedrive.wifi"

    override init() {
        let savedIP = UserDefaults.standard.string(forKey: "mirror.dashboard.ip")
        dashboardIP = savedIP?.isEmpty == false ? savedIP! : "192.168.0.1"
        let group = UserDefaults(suiteName: MirrorLogStore.appGroupID)
        cropMode = group?.string(forKey: "mirror.crop") == "fit" ? "fit" : "crop"
        // 默认关仪表投屏：避免仪表 IP/热点预检干扰本机 CarPlay 唤起
        castToZeeho = UserDefaults.standard.object(forKey: "mirror.cast.zeeho") as? Bool ?? false
        let presetSSID = UserDefaults.standard.string(forKey: "cp.wifi.ssid") ?? ""
        let presetPassword = UserDefaults.standard.string(forKey: "cp.wifi.password") ?? ""
        wifiSSID = presetSSID
        wifiPassword = presetPassword
        super.init()
        locationManager.delegate = self
        recheckIdentity()
        detectSSID()
    }

    // MARK: - SSID 检测（需要定位权限，iOS 13+ 系统要求）

    func detectSSID() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            locationDenied = true
        case .authorizedAlways, .authorizedWhenInUse:
            locationDenied = false
            refreshSSID()
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.detectSSID() }
    }

    /// 同步读取当前 SSID（预检用；需要定位权限已授权）。
    static func currentSSIDSnapshot() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for interface in interfaces {
            if let info = CNCopyCurrentNetworkInfo(interface as CFString) as? [String: Any],
               let name = info[kCNNetworkInfoKeySSID as String] as? String, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private func refreshSSID() {
        let ssid = Self.currentSSIDSnapshot()
        DispatchQueue.main.async {
            self.currentSSID = ssid
            if let ssid {
                // 检测成功时回填可编辑字段；已有手填内容不覆盖
                if self.wifiSSID.isEmpty { self.wifiSSID = ssid }
                let remembered = Self.savedPassword(for: ssid)
                self.rememberedPassword = remembered != nil
                if let remembered, self.wifiPassword.isEmpty {
                    self.wifiPassword = remembered
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 忽略单次定位失败
    }

    // MARK: - 密码按 SSID 记忆（Keychain）

    static func savedPassword(for ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: wifiService,
            kSecAttrAccount as String: "ssid-\(ssid)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else { return nil }
        return password
    }

    static func savePassword(_ password: String, for ssid: String) {
        let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: wifiService,
            kSecAttrAccount as String: "ssid-\(ssid)",
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(password.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrAccessGroup as String] = "com.qianxu.jihedrive"
            _ = SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// 保存 Wi-Fi 预设（StartSession 必需）。优先用手填 SSID，其次用系统检测到的。
    @discardableResult
    func commitWiFi() -> Bool {
        let ssid = resolvedSSID
        guard !ssid.isEmpty else { return false }
        wifiSSID = ssid
        Self.savePassword(wifiPassword, for: ssid)
        rememberedPassword = !wifiPassword.isEmpty
        CPWiFiDefaults.save(ssid: ssid, password: wifiPassword, channel: 36)
        return true
    }

    /// 实际用于会话的 SSID：手填 > 系统检测。
    var resolvedSSID: String {
        let typed = wifiSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return currentSSID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - 一键加入仪表热点

    /// 用 NEHotspotConfiguration 配置并加入仪表热点；配置成功后系统会自动重连，
    /// 密码同时按 SSID 记住——之后「自动获取 WiFi 名称和密码」无需重复输入。
    func joinDashboardHotspot(ssid: String?, password: String) {
        let targetSSID = (ssid?.isEmpty == false ? ssid : currentSSID) ?? ""
        guard !targetSSID.isEmpty else {
            hotspotStatus = "请先输入或检测到仪表热点名称"
            return
        }
        let configuration: NEHotspotConfiguration
        if password.isEmpty {
            configuration = NEHotspotConfiguration(ssid: targetSSID)
        } else {
            configuration = NEHotspotConfiguration(ssid: targetSSID, passphrase: password, isWEP: false)
        }
        hotspotStatus = "正在加入 \(targetSSID)…"
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.hotspotStatus = "加入失败：\(error.localizedDescription)"
                } else {
                    self.hotspotStatus = "已加入 \(targetSSID)（系统将自动重连）"
                    Self.savePassword(password, for: targetSSID)
                    CPWiFiDefaults.save(ssid: targetSSID, password: password, channel: 36)
                    // 热点配置在 iOS 视角是「本 App 配置的网络」，稍后可读回 SSID
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.detectSSID()
                    }
                }
            }
        }
    }

    // MARK: - 仪表地址

    func commitDashboardIP() {
        let trimmed = dashboardIP.trimmingCharacters(in: .whitespaces)
        dashboardIP = trimmed.isEmpty ? "192.168.0.1" : trimmed
        UserDefaults.standard.set(dashboardIP, forKey: "mirror.dashboard.ip")
        let group = UserDefaults(suiteName: MirrorLogStore.appGroupID)
        group?.set(dashboardIP, forKey: "mirror.dashboard.ip")
        group?.set(cropMode, forKey: "mirror.crop")
        group?.synchronize()
    }

    func commitCropMode() {
        let group = UserDefaults(suiteName: MirrorLogStore.appGroupID)
        group?.set(cropMode, forKey: "mirror.crop")
    }

    func commitCastToZeeho() {
        UserDefaults.standard.set(castToZeeho, forKey: "mirror.cast.zeeho")
    }

    /// 重新检查身份（进入页面时调用；IdentityImport/ 里有三件套会在这里真正导入）。
    func recheckIdentity() {
        do {
            _ = try CPAccessoryIdentity.load()
            identityReady = true
            identityHint = nil
        } catch {
            identityReady = false
            identityHint = error.localizedDescription
        }
    }
}

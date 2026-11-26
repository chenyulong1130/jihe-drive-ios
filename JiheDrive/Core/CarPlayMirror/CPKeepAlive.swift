import AVFoundation
import CryptoKit
import Security
import UIKit

// MARK: - 会话保活（黑屏修复的关键步骤）

/// CarPlay 会话保活：在前台、虚拟 CarPlay 路由被选中**之前**激活音频会话，
/// 并全程持有——切后台后才尝试激活常常拿不到音频会话，所有 socket 随
/// App 挂起死亡，表现恰为「RECORD 已接受但永远等不到视频」。
/// 组成：playback + mixWithOthers 激活、8 kHz 静音循环播放、
/// 2 秒看门狗、中断/路由变化/媒体服务重置自愈、切前台自动复活。
final class CPKeepAlive {
    static let shared = CPKeepAlive()

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    private var observing = false

    private init() {}

    /// 前台、启动会话前调用；此后中断/切后台由通知自愈。
    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.observeIfNeeded()
            self.revive()
        }
    }

    /// 停止投屏时调用：停播放与看门狗，释放音频会话。
    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.watchdog?.invalidate()
            self.watchdog = nil
            self.player?.stop()
            self.player = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// 重新激活（切前台/中断结束/路由恢复时调用）。
    private func revive() {
        guard activateSession(), let player = makePlayer() else { return }
        self.player = player
        player.play()
        restartWatchdog()
    }

    private func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    /// 8 kHz 单声道静音 WAV 循环：只为占用音频会话，不产出声音。
    private func makePlayer() -> AVAudioPlayer? {
        if let existing = player, existing.isPlaying { return existing }
        let sampleRate = 8000
        let samples = 800 // 0.1 s
        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: string.utf8) }
        func appendLE(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        func appendLE(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        append("RIFF")
        let dataSize = samples * 2
        appendLE(UInt32(36 + dataSize)); append("WAVE")
        append("fmt "); appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1))
        appendLE(UInt32(sampleRate)); appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2)); appendLE(UInt16(16))
        append("data"); appendLE(UInt32(dataSize))
        wav.append(Data(count: dataSize))
        let audio = try? AVAudioPlayer(data: wav)
        audio?.numberOfLoops = -1
        audio?.volume = 0
        return audio
    }

    private func restartWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.player?.isPlaying != true { self.revive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func observeIfNeeded() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.revive()
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // 切后台前抢先把会话扶起来（此时还有机会拿到音频会话）
            self?.revive()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: value) else { return }
            if type == .ended { self.revive() }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let value = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: value) else { return }
            if reason == .oldDeviceUnavailable || reason == .routeConfigurationChange { self.revive() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.player = nil
            self.revive()
        }
    }
}

// MARK: - AirPlay 身份（Bonjour 发布用）

/// `_airplay._tcp` TXT 记录需要的 pi/pk：pi 为持久 UUID，
/// pk 为 Ed25519 公钥（十六进制），私钥存 Keychain。
enum CPAirPlayIdentity {
    private static let keyService = "com.liruixin.jihedrive.airplay.identity.v1"
    private static let piKey = "cp.airplay.pi"

    static var identifier: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: piKey) { return existing }
        let value = UUID().uuidString
        defaults.set(value, forKey: piKey)
        return value
    }

    /// Ed25519 公钥的十六进制（32 字节 → 64 字符）。
    static var publicKeyHex: String? {
        guard let key = signingKey() else { return nil }
        return key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    private static func signingKey() -> Curve25519.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccount as String: "ed25519",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard let key = try? Curve25519.Signing.PrivateKey() else { return nil }
        let raw = key.rawRepresentation
        var add = query
        add[kSecReturnData as String] = false
        add.removeValue(forKey: kSecReturnData as String)
        add.removeValue(forKey: kSecMatchLimit as String)
        add[kSecValueData as String] = raw
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) != errSecSuccess { return nil }
        return key
    }
}

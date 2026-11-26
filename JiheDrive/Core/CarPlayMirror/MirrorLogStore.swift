import Foundation

/// 投屏日志收集：App 与广播扩展共用（App Group 容器）。
/// - 按天分文件：MirrorLogs/mirror-YYYY-MM-DD.log
/// - 自动清理 7 天前的旧日志
/// - 写入前做敏感信息脱敏（密码/签名/密钥类字段永不落盘）
/// - 可导出合并文件用于问题反馈
enum MirrorLogStore {

    static let appGroupID = "group.com.qianxu.jihedrive"

    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "jihedrive.mirror.log", qos: .utility)
    private static var currentDay: String = ""

    private static let redactionPatterns: [(String, String)] = [
        ("passphrase", "[REDACTED]"),
        ("password", "[REDACTED]"),
        ("encryptedHUID", "[REDACTED]"),
        ("pubkey", "[REDACTED]"),
        ("privateKey", "[REDACTED]"),
    ]

    /// 追加一行日志。`source`：app（主 App）/ ext（广播扩展）。
    static func append(_ message: String, source: String = "app") {
        let line = sanitized(message)
        queue.async {
            let url = logFileURL(day: today())
            let stamp = timestamp()
            let text = "\(stamp) [\(source)] \(line)\n"
            lock.lock()
            defer { lock.unlock() }
            if let handle = FileHandle(forWritingAtPath: url.path) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: url)
            }
            rotateIfNeeded()
        }
    }

    /// 合并最近 `days` 天的日志到单个可分享文件。
    static func exportFile(days: Int = 7) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var combined = "JiheDrive 投屏日志（导出时间 \(timestamp())）\n\n"
        var found = false
        for offset in 0..<days {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let day = formatter.string(from: date)
            let url = logFileURL(day: day)
            if let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
                combined += "===== \(day) =====\n\(content)\n"
                found = true
            }
        }
        guard found else { return nil }
        let output = logDirectory().appendingPathComponent("mirror-logs-export.txt")
        try? FileManager.default.removeItem(at: output)
        do {
            try combined.write(to: output, atomically: true, encoding: .utf8)
            return output
        } catch {
            return nil
        }
    }

    static func clearAll() {
        queue.async {
            lock.lock()
            defer { lock.unlock() }
            try? FileManager.default.removeItem(at: logDirectory())
        }
    }

    // MARK: - 内部

    private static func logDirectory() -> URL {
        let base: URL
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            base = group
        } else {
            // App Group 不可用（如免费证书）时退回沙盒文档目录
            base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
        }
        return base.appendingPathComponent("MirrorLogs", isDirectory: true)
    }

    private static func logFileURL(day: String) -> URL {
        logDirectory().appendingPathComponent("mirror-\(day).log")
    }

    private static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func rotateIfNeeded() {
        let day = today()
        guard day != currentDay else { return }
        currentDay = day
        // 清理 7 天前的日志
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return }
        let cutoffDay = formatter.string(from: cutoff)
        if let files = try? FileManager.default.contentsOfDirectory(at: logDirectory(),
                                                                   includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("mirror-")
                && file.lastPathComponent.hasSuffix(".log") {
                let fileDay = file.lastPathComponent
                    .replacingOccurrences(of: "mirror-", with: "")
                    .replacingOccurrences(of: ".log", with: "")
                if fileDay < cutoffDay {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    /// 脱敏：命中敏感字段名时整行降级为字段名提示。
    private static func sanitized(_ message: String) -> String {
        var text = message
        for (pattern, replacement) in redactionPatterns {
            if text.localizedCaseInsensitiveContains(pattern) {
                text = text.replacingOccurrences(of: pattern, with: replacement, options: .caseInsensitive)
            }
        }
        return text
    }
}

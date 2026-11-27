import Foundation
import QuartzCore
import UIKit

/// 主线程卡死监测：后台线程每秒检查主 RunLoop 是否超过阈值没进 BeforeWaiting，
/// 卡死发生瞬间先把「已卡时长 + 最近事件环」落盘（进程随后被 watchdog 杀掉也不丢），
/// 恢复后补一条「总时长」。随机复现的卡死靠报告里最后几条事件定位到具体子系统。
/// 报告文件：Documents/hang_report.log，「我的 → 诊断」里可查看/复制。
final class MainThreadHangMonitor: @unchecked Sendable {
    static let shared = MainThreadHangMonitor()

    /// 卡死判定阈值（秒）
    private static let threshold: CFTimeInterval = 3.5
    /// 事件环容量：卡死时落盘的最近事件条数
    private static let ringLimit = 60
    /// 报告文件大小上限，超过后截半重写
    private static let fileLimit = 128 * 1024

    private let queue = DispatchQueue(label: "jihedrive.hang-monitor", qos: .utility)
    private let lock = NSLock()
    private var lastBeat: CFTimeInterval = 0
    private var hangStart: CFTimeInterval?
    private var lastOngoingStamp: CFTimeInterval = 0
    private var ring: [String] = []

    private static let reportFile: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("hang_report.log")
    }()

    private init() {}

    /// App 启动时调用一次（必须在主线程）
    func start() {
        installRunloopObserver()
        queue.async { [weak self] in
            guard let self else { return }
            while true {
                Thread.sleep(forTimeInterval: 1.0)
                self.check()
            }
        }
    }

    /// 主线程事件埋点：切 Tab、BLE/CarPlay 日志、场景切换等高信号动作（任意线程可调）
    static func note(_ event: String) {
        shared.appendNote(event)
    }

    /// 报告全文（设置页展示/复制用）；无记录返回 nil
    static func reportText() -> String? {
        guard let text = try? String(contentsOf: reportFile, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - RunLoop 心跳

    private func installRunloopObserver() {
        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0,
            { _, _, info in
                guard let info else { return }
                let monitor = Unmanaged<MainThreadHangMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.lock.lock()
                monitor.lastBeat = CACurrentMediaTime()
                monitor.lock.unlock()
            },
            &context
        )
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        lock.lock()
        lastBeat = CACurrentMediaTime()
        lock.unlock()
    }

    // MARK: - 检查与落盘

    private func appendNote(_ event: String) {
        let line = "[\(Self.timeText(Date()))] \(event)"
        lock.lock()
        ring.append(line)
        if ring.count > Self.ringLimit {
            ring.removeFirst(ring.count - Self.ringLimit)
        }
        lock.unlock()
    }

    private func check() {
        let now = CACurrentMediaTime()
        lock.lock()
        let beat = lastBeat
        lock.unlock()
        let stall = now - beat

        if stall > Self.threshold {
            if hangStart == nil {
                // 首次判定卡死：立刻落盘起点报告，防止随后 watchdog 杀进程丢数据
                hangStart = beat
                lastOngoingStamp = now
                writeReport(lines: reportHeader(
                    title: "主线程疑似卡死（发生时实时记录）",
                    duration: stall,
                    tail: "\n（若进程随后被系统杀掉，本条就是卡死时的最后状态）"
                ))
            } else if now - lastOngoingStamp > 10 {
                // 持续卡死每 10 秒补一条进度
                lastOngoingStamp = now
                writeReport(lines: [
                    "[\(Self.timeText(Date()))] 仍卡死中，已卡 \(String(format: "%.1f", now - (hangStart ?? beat))) 秒"
                ])
            }
            return
        }

        // 主线程已恢复：卡死结束，补一条总时长
        guard let start = hangStart else { return }
        hangStart = nil
        let duration = beat - start
        writeReport(lines: [
            "[\(Self.timeText(Date()))] ✅ 主线程已恢复，本次卡死总时长约 \(String(format: "%.1f", duration)) 秒"
        ])
    }

    /// 卡死起点报告：时长 + 事件环
    private func reportHeader(title: String, duration: CFTimeInterval, tail: String) -> [String] {
        lock.lock()
        let snapshot = ring
        lock.unlock()
        var lines: [String] = []
        lines.append("")
        lines.append("======================================================")
        lines.append("==== \(title) · \(Self.timeText(Date())) · 已卡 \(String(format: "%.1f", duration)) 秒")
        lines.append("======================================================")
        lines.append("卡死前最近事件（新在下）：")
        if snapshot.isEmpty {
            lines.append("（无埋点事件）")
        } else {
            lines.append(contentsOf: snapshot)
        }
        lines.append(contentsOf: tail.split(separator: "\n").map(String.init))
        return lines
    }

    private func writeReport(lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        let file = Self.reportFile
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil)
        }
        // 超过上限截半重写，避免无限膨胀
        if let attrs = try? fm.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? Int, size > Self.fileLimit,
           let old = try? String(contentsOf: file, encoding: .utf8) {
            let half = old.index(old.startIndex, offsetBy: old.count / 2, limitedBy: old.endIndex) ?? old.startIndex
            try? String(old[half...]).write(to: file, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

import SwiftUI
import UIKit
import CoreImage

/// 预览 / 全屏上的 BMS 叠画卡片（玻璃 HUD，比参考 App 的纯文字条更清晰）。
struct BMSOverlayCard: View {
    let realtime: BMSRealtime?
    let connected: Bool
    var size: BMSOverlayConfig.Size = BMSOverlayConfig.size
    var fields: Set<BMSOverlayConfig.Field> = BMSOverlayConfig.fields
    /// 设置页缩略预览时略收紧阴影
    var compactChrome: Bool = false

    private var flow: String { realtime?.flowLabel ?? "—" }
    private var accent: Color {
        guard connected, let realtime else { return Theme.secondary }
        switch realtime.flowLabel {
        case "充电中": return Theme.green
        case "放电中": return Color(hex: 0x38BDF8)
        case "均衡中": return Theme.orange
        default: return Theme.brand
        }
    }

    var body: some View {
        // 2026-11-28 重设计：紧凑玻璃药丸（去掉左侧色条，半透明少遮挡）
        // 第一行：大字电量 + 状态；第二行：其余指标单行小字
        VStack(alignment: .leading, spacing: size == .compact ? 3 : 5) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size.titleSize, weight: .bold))
                    .foregroundStyle(accent)
                if fields.contains(.soc) {
                    Text(connected ? "\(realtime?.soc ?? 0)" : "--")
                        .font(.system(size: size.valueSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("%")
                        .font(.system(size: size.metricSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text("BMS")
                    .font(.system(size: size.metricSize - 1, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 4)
                Circle()
                    .fill(connected ? accent : Color.white.opacity(0.35))
                    .frame(width: 6, height: 6)
                Text(connected ? flow : "未连")
                    .font(.system(size: size.metricSize - 1, weight: .semibold))
                    .foregroundStyle(connected ? accent.opacity(0.9) : .white.opacity(0.45))
            }

            if metricsLineVisible {
                Text(metricsLine)
                    .font(.system(size: size.metricSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if footerVisible {
                Text(footerLine)
                    .font(.system(size: size.metricSize - 1, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, size.padding)
        .padding(.vertical, max(6, size.padding - 4))
        .background {
            RoundedRectangle(cornerRadius: compactChrome ? 10 : 14, style: .continuous)
                // 投屏烧录用实色（ImageRenderer 对 material 常渲成灰块），透明度调低少遮挡
                .fill(compactChrome
                      ? AnyShapeStyle(Color(red: 0.05, green: 0.08, blue: 0.12).opacity(0.55))
                      : AnyShapeStyle(.ultraThinMaterial.opacity(0.72)))
                .overlay(
                    RoundedRectangle(cornerRadius: compactChrome ? 10 : 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(compactChrome ? 0.14 : 0.25), radius: compactChrome ? 5 : 9, y: 2)
        }
    }

    /// 中排指标（总压/电流/功率，按显示字段开关拼接）
    private var metricsLineVisible: Bool {
        fields.contains(.voltage) || fields.contains(.current) || fields.contains(.power)
    }

    private var metricsLine: String {
        var parts: [String] = []
        if fields.contains(.voltage) {
            parts.append(connected ? String(format: "%.1fV", realtime?.totalVoltage ?? 0) : "--V")
        }
        if fields.contains(.current) {
            parts.append(connected ? String(format: "%.1fA", abs(realtime?.current ?? 0)) : "--A")
        }
        if fields.contains(.power) {
            parts.append(connected ? "\(abs(realtime?.power ?? 0))W" : "--W")
        }
        return parts.joined(separator: " · ")
    }

    private var footerVisible: Bool {
        (fields.contains(.cells) || fields.contains(.temperature)) && connected
    }

    private var footerLine: String {
        var parts: [String] = []
        if fields.contains(.cells) {
            let count = realtime?.cellCount ?? 0
            let diff = realtime?.voltageDiff ?? 0
            parts.append(count > 0 ? "\(count)串 压差\(String(format: "%.0f", diff * 1000))mV" : "无单体")
        }
        if fields.contains(.temperature) {
            let temps = realtime?.temperatures ?? []
            let mos = realtime?.mosTemperature ?? 0
            let shown = !temps.isEmpty ? "\(temps.max() ?? 0)°" : (mos != 0 ? "\(mos)°" : "--°")
            parts.append(shown)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 投屏烧录（JPEG / 极核 / 画中画）

/// 把叠画卡片渲成位图，供转码器合成进输出帧。
final class BMSOverlayBurnIn: @unchecked Sendable {
    static let shared = BMSOverlayBurnIn()

    private var cachedKey = ""
    private var lastRender: TimeInterval = 0
    private let lock = NSLock()
    private var lockedSnapshot: Snapshot?

    struct Snapshot: @unchecked Sendable {
        let image: CGImage
        let position: BMSOverlayConfig.Position
        let widthRatio: CGFloat
        let marginRatio: CGFloat
    }

    @MainActor
    func refresh(
        realtime: BMSRealtime?,
        connected: Bool,
        enabled: Bool = BMSOverlayConfig.enabled,
        position: BMSOverlayConfig.Position = BMSOverlayConfig.position,
        size: BMSOverlayConfig.Size = BMSOverlayConfig.size,
        fields: Set<BMSOverlayConfig.Field> = BMSOverlayConfig.fields
    ) {
        guard enabled else {
            cachedKey = ""
            lock.lock()
            lockedSnapshot = nil
            lock.unlock()
            return
        }

        let soc = realtime?.soc ?? -1
        let voltage = Int((realtime?.totalVoltage ?? 0) * 10)
        let current = Int((realtime?.current ?? 0) * 10)
        let power = realtime?.power ?? 0
        let flow = realtime?.flowLabel ?? "-"
        let key = "\(connected)|\(soc)|\(voltage)|\(current)|\(power)|\(flow)|\(size.rawValue)|\(fields.map(\.rawValue).sorted().joined())|\(position.rawValue)"
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let hasCache = lockedSnapshot != nil
        lock.unlock()
        if key == cachedKey, hasCache, now - lastRender < 0.8 {
            return
        }

        let card = BMSOverlayCard(
            realtime: realtime,
            connected: connected,
            size: size,
            fields: fields,
            compactChrome: true
        )
        .frame(width: size == .compact ? 168 : (size == .regular ? 210 : 260))
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        cachedKey = key
        lastRender = now
        let snap = Snapshot(
            image: cg,
            position: position,
            widthRatio: size.widthRatio,
            marginRatio: 0.028
        )
        lock.lock()
        lockedSnapshot = snap
        lock.unlock()
    }

    /// 转码线程安全读取。
    func currentSnapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return lockedSnapshot
    }
}

extension BMSOverlayBurnIn {
    /// 在画布坐标系合成叠画（原点左下，CI 惯例）。可在任意线程调用。
    nonisolated static func composite(
        base: CIImage,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        snapshot: Snapshot?
    ) -> CIImage {
        guard let snap = snapshot else { return base }
        let overlay = CIImage(cgImage: snap.image)
        let targetW = canvasWidth * snap.widthRatio
        let scale = targetW / max(overlay.extent.width, 1)
        let targetH = overlay.extent.height * scale
        let marginX = canvasWidth * snap.marginRatio
        let marginY = canvasHeight * snap.marginRatio
        let x: CGFloat
        let y: CGFloat
        switch snap.position {
        case .topLeading:
            x = marginX
            y = canvasHeight - marginY - targetH
        case .topTrailing:
            x = canvasWidth - marginX - targetW
            y = canvasHeight - marginY - targetH
        case .bottomLeading:
            x = marginX
            y = marginY
        case .bottomTrailing:
            x = canvasWidth - marginX - targetW
            y = marginY
        }
        let placed = overlay
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
        return placed.composited(over: base)
    }
}

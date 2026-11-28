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
        VStack(alignment: .leading, spacing: size == .compact ? 6 : 8) {
            header
            if fields.contains(.soc) || fields.contains(.voltage) {
                heroRow
            }
            if showsMetrics {
                metricsRow
            }
            if fields.contains(.cells) || fields.contains(.temperature) {
                footerRow
            }
        }
        .padding(size.padding)
        .background {
            RoundedRectangle(cornerRadius: compactChrome ? 12 : 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: compactChrome ? 12 : 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.35), accent.opacity(0.35), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: .black.opacity(compactChrome ? 0.18 : 0.35), radius: compactChrome ? 8 : 14, y: 4)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(accent)
                .frame(width: 3)
                .padding(.vertical, size.padding)
                .padding(.leading, 3)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.batteryblock.fill")
                .font(.system(size: size.titleSize, weight: .semibold))
                .foregroundStyle(accent)
            Text("BMS")
                .font(.system(size: size.titleSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Spacer(minLength: 4)
            Text(connected ? flow : "未连接")
                .font(.system(size: size.metricSize, weight: .semibold, design: .rounded))
                .foregroundStyle(connected ? accent : .white.opacity(0.45))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
    }

    private var heroRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            if fields.contains(.soc) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(connected ? "\(realtime?.soc ?? 0)" : "--")
                        .font(.system(size: size.valueSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("%")
                        .font(.system(size: size.metricSize, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            if fields.contains(.voltage) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("总压")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(connected ? String(format: "%.1f V", realtime?.totalVoltage ?? 0) : "-- V")
                        .font(.system(size: size.metricSize + 2, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var showsMetrics: Bool {
        fields.contains(.current) || fields.contains(.power)
    }

    private var metricsRow: some View {
        HStack(spacing: 8) {
            if fields.contains(.current) {
                metricChip(
                    title: "电流",
                    value: connected ? String(format: "%.1f A", abs(realtime?.current ?? 0)) : "-- A"
                )
            }
            if fields.contains(.power) {
                metricChip(
                    title: "功率",
                    value: connected ? "\(abs(realtime?.power ?? 0)) W" : "-- W"
                )
            }
        }
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(value)
                .font(.system(size: size.metricSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if fields.contains(.cells) {
                let count = realtime?.cellCount ?? 0
                let diff = realtime?.voltageDiff ?? 0
                Text(connected
                      ? (count > 0 ? "\(count)串 · 压差 \(String(format: "%.0f", diff * 1000)) mV" : "无单体")
                      : "单体 —")
                    .font(.system(size: size.metricSize - 1, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            if fields.contains(.temperature) {
                let temps = realtime?.temperatures ?? []
                let mos = realtime?.mosTemperature ?? 0
                let shown: String = {
                    if !temps.isEmpty { return "\(temps.max() ?? 0)°" }
                    if mos != 0 { return "\(mos)°" }
                    return "--°"
                }()
                Label(connected ? shown : "--°", systemImage: "thermometer.medium")
                    .font(.system(size: size.metricSize - 1, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - 投屏烧录（JPEG / 极核 / 画中画）

/// 把叠画卡片渲成位图，供转码器合成进输出帧。
@MainActor
final class BMSOverlayBurnIn {
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
    nonisolated func currentSnapshot() -> Snapshot? {
        // NSLock 保护；CGImage 只读引用跨线程安全
        let lock = MainActor.assumeIsolated { self.lock }
        lock.lock()
        let snap = MainActor.assumeIsolated { lockedSnapshot }
        lock.unlock()
        return snap
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

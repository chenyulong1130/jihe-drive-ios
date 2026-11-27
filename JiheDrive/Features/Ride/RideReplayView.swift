import Foundation
import MapKit
import SceneKit
import SwiftUI
import UIKit

/// 轨迹回放：Z-Link 弱化底图 + 自有速度着色轨迹，默认全览、不自动播。
struct RideReplayView: View {
    let vehicle: Vehicle
    let tracks: [RideTrack]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var progress: Double = 0
    @State private var playing = false
    @State private var rate: Double = 1
    @State private var follow = false
    @State private var showFullMap = false
    @State private var prefer3D: Bool
    @State private var liveAddress: String?
    @State private var replayScene: SCNScene?
    @State private var replayGLB: URL?

    init(vehicle: Vehicle, track: RideTrack) {
        self.vehicle = vehicle
        self.tracks = [track]
        _prefer3D = State(initialValue: vehicle.model3DURL != nil)
        _replayGLB = State(initialValue: Self.cachedGLB(for: vehicle))
        self.track = track
        clock = ReplayClock.make(track)
        coordinates = track.points.map { $0.mapCoordinate }
        speeds = Self.paddedSpeeds(track)
        wallReal = Self.realTimes(track)
        startClockText = Self.wallText(track, clock, wallReal, 0)
        endClockText = Self.wallText(track, clock, wallReal, 1)
    }

    init(vehicle: Vehicle, tracks: [RideTrack]) {
        self.vehicle = vehicle
        self.tracks = tracks
        _prefer3D = State(initialValue: vehicle.model3DURL != nil)
        _replayGLB = State(initialValue: Self.cachedGLB(for: vehicle))
        let merged = RideTrack.merged(tracks)
        track = merged
        clock = ReplayClock.make(merged)
        coordinates = merged.points.map { $0.mapCoordinate }
        speeds = Self.paddedSpeeds(merged)
        wallReal = Self.realTimes(merged)
        startClockText = Self.wallText(merged, clock, wallReal, 0)
        endClockText = Self.wallText(merged, clock, wallReal, 1)
    }

    private static func cachedGLB(for vehicle: Vehicle) -> URL? {
        guard vehicle.isGLBModel else { return nil }
        return GLBModelStore.cached(vin: vehicle.vinNo, remote: vehicle.model3DURL)
    }

    /// 合并后的轨迹与派生数据只算一次：回放播放时每帧刷新 body，
    /// 放在计算属性里会每帧重复 merge 全部轨迹点 + 重算时间轴，
    /// 长行程直接把主线程拖卡——回放页卡顿/卡死的主因
    private let track: RideTrack
    private let clock: (times: [TimeInterval], duration: TimeInterval)
    private let coordinates: [CLLocationCoordinate2D]
    private let speeds: [Double]
    /// realTimestamps 与点位等长且含有效时间戳时缓存为 Double 数组（否则 nil）
    private let wallReal: [Double]?
    private let startClockText: String
    private let endClockText: String

    /// 多段合并时的分段断点（points 下标），地图上段与段之间不连线。
    /// 顺序必须和 merged 内部的 startTime 升序一致。
    private var trackBreaks: [Int] {
        let sorted = tracks.sorted { ($0.startTime ?? "") < ($1.startTime ?? "") }
        var acc = 0
        var result: [Int] = []
        for (index, item) in sorted.enumerated() where index > 0 {
            acc += sorted[index - 1].points.count
            result.append(acc)
        }
        return result
    }

    // MARK: - 数据

    /// 速度采样补齐到与轨迹点等长（短了补最后一个值）
    private static func paddedSpeeds(_ track: RideTrack) -> [Double] {
        let n = track.points.count
        var samples = track.speedSamples
        if samples.count == n { return samples }
        if n == 0 { return samples }
        if samples.count > n { return Array(samples.prefix(n)) }
        samples.append(contentsOf: Array(repeating: samples.last ?? 0, count: n - samples.count))
        return samples
    }

    private static func realTimes(_ track: RideTrack) -> [Double]? {
        guard track.realTimestamps.count == track.points.count,
              track.realTimestamps.contains(where: { $0 > 1_000_000_000 }) else { return nil }
        return track.realTimestamps.map { Double($0) }
    }

    /// 墙钟文本：与 ReplayClock.wallDate 同逻辑，但吃缓存数据，不再每帧重新 make
    private static func wallText(
        _ track: RideTrack,
        _ clock: (times: [TimeInterval], duration: TimeInterval),
        _ real: [Double]?,
        _ ratio: Double
    ) -> String {
        let elapsed = clock.duration * min(max(ratio, 0), 1)
        var epoch: TimeInterval?
        if let real {
            let sample = ReplayClock.sampleValue(real, times: clock.times, duration: clock.duration, progress: ratio)
            if sample > 1_000_000_000 { epoch = sample }
        }
        if epoch == nil, let start = track.startedAt, start > 1_000_000_000 {
            epoch = start + elapsed
        }
        if epoch == nil, let first = track.timestamps.first(where: { $0 > 1_000_000_000 }) {
            epoch = first - (clock.times.first ?? 0) + elapsed
        }
        if let epoch {
            return clockFormatter.string(from: Date(timeIntervalSince1970: epoch))
        }
        let total = Int(elapsed.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// 回放墙钟时长：压缩真实行程（点与点之间的时间比例保持不变），
    /// 同时按采样点数兜底——点多的长行程按每点约 0.15 秒计算，
    /// 不再被 100 秒封顶压成快进；上限 10 分钟，可用倍速调节
    private var playbackSeconds: Double {
        let real = max(clock.duration, 1)
        let densityFloor = Double(max(track.points.count, 1)) * 0.15
        return min(600, max(40, max(real / 24, densityFloor)))
    }

    private var currentSpeed: Double {
        ReplayClock.sampleValue(speeds, times: clock.times, duration: clock.duration, progress: progress)
    }

    private var maxSpeedValue: Double {
        track.maxSpeed ?? (speeds.max() ?? 0)
    }

    private var averageSpeed: Double {
        guard track.durationMinutes > 0 else { return 0 }
        return track.mileage / (Double(track.durationMinutes) / 60)
    }

    // MARK: - 页面

    var body: some View {
        fullMap
        .task(id: playing) {
            guard playing else { return }
            if progress >= 1 { progress = 0 }
            var last = Date()
            while playing && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                if Task.isCancelled { break }
                let now = Date()
                let delta = now.timeIntervalSince(last)
                last = now
                let next = progress + delta * rate / playbackSeconds
                if next >= 1 {
                    playing = false
                    progress = 0
                    break
                }
                progress = next
            }
        }
        .task(id: Int(progress * 40)) {
            await refreshLiveAddress()
        }
        .task {
            await loadReplayAssets()
        }
    }

    private var cinematic: Bool { prefer3D }
    private var mapOnDark: Bool { colorScheme == .dark }

    private func loadReplayAssets() async {
        let vin = vehicle.vinNo
        if replayScene == nil, let cached = VehicleModelLoader.cachedScene(vin: vin) {
            replayScene = ReplayMapModel.prepared(from: cached)
        }
        if replayGLB == nil, vehicle.isGLBModel {
            if let file = GLBModelStore.cached(vin: vin, remote: vehicle.model3DURL) {
                replayGLB = file
                return
            }
            guard let remote = vehicle.model3DURL else { return }
            replayGLB = try? await GLBModelStore.localFile(for: remote, vin: vin)
            return
        }
        guard replayScene == nil, let remote = vehicle.model3DURL, !vehicle.isGLBModel else { return }
        var local = ResourceCache.existingFile(for: remote, folder: "models")
        if local == nil {
            local = await ResourceCache.file(for: remote, folder: "models")
        }
        if let local, let scene = ReplayMapModel.scene(from: local) {
            replayScene = scene
        }
    }

    private var traveledKm: Double {
        max(0, track.mileage * min(max(progress, 0), 1))
    }

    private var startPlace: String {
        AmapGeocode.placeDetail(track.startAddress)
            ?? track.startAddress
            ?? "起点"
    }

    private var endPlace: String {
        AmapGeocode.placeDetail(track.endAddress)
            ?? track.endAddress
            ?? "终点"
    }

    private func refreshLiveAddress() async {
        let sample = ReplayClock.sample(track, progress: progress)
        if let text = await AmapGeocode.reverse(
            longitude: sample.point.longitude,
            latitude: sample.point.latitude
        ) {
            liveAddress = text
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))

            VStack(alignment: .leading, spacing: 2) {
                Text("轨迹回放")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.label)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                showFullMap = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            .accessibilityLabel("全屏")
        }
    }

    private var subtitle: String {
        let time = track.startTime ?? "未记录时间"
        if tracks.count > 1 {
            return "\(tracks.count) 段 · \(time)"
        }
        return time
    }

    // MARK: - 路线卡

    private var routeCard: some View {
        ZStack {
            ReplayMap(
                points: coordinates,
                speeds: speeds,
                times: clock.times,
                duration: clock.duration,
                progress: progress,
                follow: false,
                breaks: trackBreaks
            )
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        if progress >= 1 { progress = 0 }
                        playing.toggle()
                    } label: {
                        chip(text: playing ? "暂停" : "回放", icon: playing ? "pause.fill" : "play.fill", tint: .white)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button {
                        showFullMap = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: 0x2563EB))
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
                            .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
                    }
                    .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                    .accessibilityLabel("全屏")
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    chip(text: String(format: "%.1f km", track.mileage), icon: "point.topleft.down.curvedto.point.bottomright.up", tint: .white)
                    Spacer(minLength: 0)
                    TrackSpeedLegend(compact: true)
                }
            }
            .padding(12)
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        )
        .shadow(color: Theme.cardShadow, radius: 20, x: 0, y: 6)
    }

    private func chip(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.48)))
    }

    // MARK: - 指标

    private var metricsCard: some View {
        AppleCard(padding: 14) {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    metric("里程", String(format: "%.1f", track.mileage), "km")
                    metricDivider
                    metric("时长", "\(track.durationMinutes)", "分钟")
                    metricDivider
                    metric("最高", String(format: "%.0f", maxSpeedValue), "km/h")
                }
                HairLine()
                HStack(spacing: 0) {
                    metric("均速", String(format: "%.0f", averageSpeed), "km/h")
                    metricDivider
                    metric("当前", String(format: "%.0f", currentSpeed), "km/h")
                    metricDivider
                    metric("轨迹点", "\(track.points.count)", "个")
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 0.5, height: 26)
    }

    // MARK: - 速度曲线

    private var speedCard: some View {
        AppleCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("速度曲线")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Text(speeds.count > 1 ? String(format: "峰值 %.0f km/h", maxSpeedValue) : "无速度采样")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                }

                if speeds.count > 1 {
                    SpeedCurve(
                        speeds: speeds,
                        times: clock.times,
                        duration: clock.duration,
                        progress: progress,
                        tint: Theme.brand
                    ) { value in
                        playing = false
                        progress = min(max(value, 0), 1)
                    }
                } else {
                    Text("这段轨迹没有速度采样，只能看路线")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 96)
                }

                HStack(spacing: 0) {
                    Text(timeText(0))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text("拖动曲线可定位")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 0)
                    Text(timeText(1))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - 起终点

    private var placeCard: some View {
        AppleCard(padding: 14) {
            VStack(spacing: 10) {
                placeRow(
                    icon: "location.fill",
                    tint: Theme.green,
                    title: "起点",
                    value: AmapGeocode.placeDetail(track.startAddress)
                        ?? track.startAddress
                        ?? "未记录地址"
                )
                HairLine()
                placeRow(
                    icon: "flag.checkered",
                    tint: Theme.orange,
                    title: "终点",
                    value: AmapGeocode.placeDetail(track.endAddress)
                        ?? track.endAddress
                        ?? "未记录地址"
                )
                HairLine()
                placeRow(
                    icon: "clock",
                    tint: Theme.secondary,
                    title: "出发",
                    value: track.startTime ?? "未记录时间"
                )
            }
        }
    }

    private func placeRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: some View {
        Text("轨迹点由车机通过 4G 上报，约 10 秒一个点，所以路线会有折角；速度与里程按轮胎校准还原，仅用于回看。")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.tertiary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: - 播放条

    private var playbackBar: some View {
        HStack(spacing: 12) {
            Button {
                if progress >= 1 { progress = 0 }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle().fill(
                            LinearGradient(
                                colors: [Theme.brand, Color(hex: 0x4B5BFF)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .shadow(color: Theme.brand.opacity(0.35), radius: 12, x: 0, y: 5)
            }
            .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))

            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    Text(timeText(progress))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f%%", progress * 100))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                }

                Slider(value: $progress, in: 0...1) { editing in
                    if editing { playing = false }
                }
                .tint(Theme.brand)
            }

            Button {
                rate = rate >= 4 ? 1 : rate * 2
            } label: {
                Text("\(Int(rate))x")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .frame(width: 38, height: 30)
                    .background(Capsule().fill(Theme.surfaceAlt))
            }
            .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
            .accessibilityLabel("播放速度")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 22, x: 0, y: 8)
        .padding(.horizontal, Theme.page)
        .padding(.bottom, 8)
    }

    // MARK: - 全屏地图（顶栏 + 速度折线 + 时间轴，按真实时间戳回放）

    private var fullMap: some View {
        ReplayMap(
            points: coordinates,
            speeds: speeds,
            times: clock.times,
            duration: clock.duration,
            progress: progress,
            follow: playing,
            cinematic: cinematic,
            modelScene: prefer3D ? replayScene : nil,
            glbFile: prefer3D ? replayGLB : nil,
            use3D: prefer3D,
            edgePadding: UIEdgeInsets(top: 120, left: 40, bottom: 280, right: 40),
            breaks: trackBreaks
        )
        .ignoresSafeArea()
        .safeAreaInset(edge: .top, spacing: 0) {
            fullMapChrome
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .trailing, spacing: 8) {
                TrackSpeedLegend(compact: true, onDark: mapOnDark)
                    .padding(.trailing, 16)
                fullMapBottomPanel
            }
        }
    }

    private var fullMapChrome: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.92)))
                    .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
            .accessibilityLabel("关闭")

            VStack(alignment: .leading, spacing: 6) {
                placeLine(color: Color(hex: 0x34D399), text: startPlace, onMap: false)
                placeLine(color: Color(hex: 0xFB923C), text: endPlace, onMap: false)
            }

            Spacer(minLength: 8)

            Button {
                prefer3D.toggle()
            } label: {
                HStack(spacing: 0) {
                    Text("3D")
                        .foregroundStyle(prefer3D ? Color.white : Theme.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(prefer3D ? Theme.brand : Color.clear)
                        )
                    Text("2D")
                        .foregroundStyle(!prefer3D ? Color.white : Theme.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(!prefer3D ? Theme.brand : Color.clear)
                        )
                }
                .font(.system(size: 12, weight: .bold))
                .padding(3)
                .background(Capsule().fill(Color.white.opacity(0.92)))
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 2)
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
            .accessibilityLabel(prefer3D ? "切换为2D圆点" : "切换为3D车模")
        }
        .padding(.horizontal, Theme.page)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [
                    Theme.groupedBackground.opacity(0.96),
                    Theme.groupedBackground.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        )
    }

    private func locationBanner(onMap: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: "%.1f km", track.mileage))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(onMap ? Color.white : Theme.label)
                    .shadow(color: onMap ? Color.black.opacity(0.45) : .clear, radius: 8, y: 2)
                    .monospacedDigit()
                if progress > 0.02, progress < 0.995 {
                    Text(String(format: "已骑 %.1f km", traveledKm))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(onMap ? Color.white.opacity(0.7) : Theme.secondary)
                        .monospacedDigit()
                }
                placeLine(
                    color: Color(hex: 0x34D399),
                    text: liveAddress ?? startPlace,
                    onMap: onMap
                )
                placeLine(
                    color: Color(hex: 0xFB923C),
                    text: endPlace,
                    onMap: onMap
                )
            }
            Spacer(minLength: 8)
        }
    }

    private func placeLine(color: Color, text: String, onMap: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(onMap ? Color.white.opacity(0.92) : Theme.label)
                .shadow(color: onMap ? Color.black.opacity(0.4) : .clear, radius: 6, y: 1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 底部：速度折线 + 时间轴，玻璃底板；图例单独叠在地图右下角
    private var fullMapBottomPanel: some View {
        let ink: Color = Theme.label
        let mute: Color = Theme.secondary
        let faint: Color = Theme.tertiary
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.1f", track.mileage))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .monospacedDigit()
                Text("km")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(mute)
                if progress > 0.02, progress < 0.995 {
                    Text(String(format: "已骑 %.1f", traveledKm))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(faint)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Text(RideTrackService.durationText(track.durationMinutes))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mute)
            }

            if speeds.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("速度")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(mute)
                        Spacer(minLength: 0)
                        Text(String(format: "峰值 %.0f km/h", maxSpeedValue))
                            .font(.system(size: 11))
                            .foregroundStyle(faint)
                            .monospacedDigit()
                    }

                    SpeedCurve(
                        speeds: speeds,
                        times: clock.times,
                        duration: clock.duration,
                        progress: progress,
                        tint: Theme.brand,
                        height: 72,
                        onDark: mapOnDark
                    ) { value in
                        playing = false
                        progress = min(max(value, 0), 1)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    if progress >= 1 { progress = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle().fill(
                                LinearGradient(
                                    colors: [Theme.brand, Color(hex: 0x4B5BFF)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )
                }
                .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))

                ReplayTimeline(
                    progress: $progress,
                    playing: $playing,
                    current: wallClock(progress),
                    start: startClockText,
                    end: endClockText,
                    speed: speeds.count > 1 ? currentSpeed : nil,
                    onDark: mapOnDark
                )

                Button {
                    rate = rate >= 4 ? 1 : rate * 2
                } label: {
                    Text("\(Int(rate))x")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(width: 40, height: 32)
                        .background(Capsule().fill(.ultraThinMaterial))
                }
                .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 22,
                style: .continuous
            )
            .fill(.thinMaterial)
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 22,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 22,
                    style: .continuous
                )
                .fill(Theme.surface.opacity(mapOnDark ? 0.18 : 0.55))
            }
            .overlay {
                UnevenRoundedRectangle(
                    topLeadingRadius: 22,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 22,
                    style: .continuous
                )
                .strokeBorder(Color.white.opacity(mapOnDark ? 0.16 : 0.45), lineWidth: 0.7)
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - 工具

    private func timeText(_ ratio: Double) -> String {
        wallClock(ratio)
    }

    /// 每帧调用的墙钟文本：走缓存数据 + 静态 formatter，
    /// 之前每次新建 DateFormatter + 重新 make 时间轴，回放时主线程吃不消
    private func wallClock(_ ratio: Double) -> String {
        Self.wallText(track, clock, wallReal, ratio)
    }
}

// MARK: - 抽象路线图

/// 卡片里的路线：不加载地图瓦片，只按经纬度等比投影画线 + 网格，
/// 回放进度用亮色段和光点表示。
private struct RouteCanvas: View {
    let coords: [Coordinate]
    let progress: Double

    private var plane: RoutePlane? { RoutePlane.make(coords) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let points = plane.map { $0.projected(in: size, inset: 30) } ?? []

            ZStack {
                grid(size: size)

                if points.count > 1 {
                    let full = polyline(points)
                    let traveled = polyline(traveledPoints(points))

                    full.stroke(
                        Color(hex: 0x4D9BFF).opacity(0.55),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
                    .blur(radius: 10)

                    full.stroke(
                        Color.white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                    )

                    traveled.stroke(
                        LinearGradient(
                            colors: [Color(hex: 0x8FC4FF), Color(hex: 0x3D7DFF)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                    )

                    marker(at: points[0], color: Theme.green, size: 9)
                    marker(at: points[points.count - 1], color: Theme.orange, size: 9)
                    marker(at: currentPoint(points), color: Color(hex: 0x3D7DFF), size: 13, ring: 3)
                }
            }
        }
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            for i in 1..<6 {
                let x = size.width * CGFloat(i) / 6
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for i in 1..<4 {
                let y = size.height * CGFloat(i) / 4
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
    }

    private func polyline(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func marker(at point: CGPoint, color: Color, size: CGFloat, ring: CGFloat = 2) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: ring))
            .shadow(color: color.opacity(0.7), radius: 6, x: 0, y: 0)
            .position(point)
    }

    /// 已回放的部分：按进度截断折线
    private func traveledPoints(_ points: [CGPoint]) -> [CGPoint] {
        let clamped = min(max(progress, 0), 1)
        guard points.count > 1 else { return points }
        let raw = clamped * Double(points.count - 1)
        let index = min(points.count - 2, max(0, Int(raw)))
        let fraction = CGFloat(raw - Double(index))
        let head = Array(points[0...index])
        let a = points[index]
        let b = points[index + 1]
        let tail = CGPoint(
            x: a.x + (b.x - a.x) * fraction,
            y: a.y + (b.y - a.y) * fraction
        )
        return head + [tail]
    }

    private func currentPoint(_ points: [CGPoint]) -> CGPoint {
        traveledPoints(points).last ?? points[0]
    }
}

/// 经纬度 → 等比平面坐标（0...w / 0...h，长边为 1）
private struct RoutePlane {
    let points: [CGPoint]
    let width: CGFloat
    let height: CGFloat

    static func make(_ coords: [Coordinate]) -> RoutePlane? {
        guard coords.count > 1 else { return nil }
        let lats = coords.map { $0.latitude }
        let lngs = coords.map { $0.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else { return nil }

        // 经度随纬度收缩，否则高纬度的路线会被拉扁
        let k = max(0.2, cos((minLat + maxLat) / 2 * .pi / 180))
        let rawWidth = max(0.0000001, (maxLng - minLng) * k)
        let rawHeight = max(0.0000001, maxLat - minLat)
        let norm = max(rawWidth, rawHeight)

        let points = coords.map { coordinate in
            CGPoint(
                x: CGFloat((coordinate.longitude - minLng) * k / norm),
                y: CGFloat((maxLat - coordinate.latitude) / norm)
            )
        }
        return RoutePlane(
            points: points,
            width: CGFloat(rawWidth / norm),
            height: CGFloat(rawHeight / norm)
        )
    }

    func projected(in size: CGSize, inset: CGFloat) -> [CGPoint] {
        let availableWidth = max(1, size.width - inset * 2)
        let availableHeight = max(1, size.height - inset * 2)
        let scale = min(availableWidth / max(width, 0.0001), availableHeight / max(height, 0.0001))
        let drawWidth = width * scale
        let drawHeight = height * scale
        let dx = (size.width - drawWidth) / 2
        let dy = (size.height - drawHeight) / 2
        return points.map { CGPoint(x: dx + $0.x * scale, y: dy + $0.y * scale) }
    }
}

// MARK: - 速度曲线

/// 面积 + 折线，峰值处标数值，进度竖线跟着回放走，拖动可定位
/// 时间轴：墙钟时刻 + 可拖进度，按真实时间戳走
private struct ReplayTimeline: View {
    @Binding var progress: Double
    @Binding var playing: Bool
    let current: String
    let start: String
    let end: String
    var speed: Double?
    var onDark: Bool = true

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Text(current)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(onDark ? Color.white : Theme.label)
                    .monospacedDigit()
                Spacer(minLength: 0)
                if let speed {
                    Text(String(format: "%.0f km/h", speed))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(onDark ? Color(hex: 0x7DD3FC) : Theme.brand)
                        .monospacedDigit()
                }
            }

            GeometryReader { geo in
                let x = geo.size.width * CGFloat(min(max(progress, 0), 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(onDark ? Color.white.opacity(0.16) : Theme.separator.opacity(0.7))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: 0x5B8CFF), Color(hex: 0x7DD3FC)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, x))
                    Circle()
                        .fill(onDark ? Color.white : Color(hex: 0x5B8CFF))
                        .frame(width: 14, height: 14)
                        .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                        .offset(x: min(max(x - 7, 0), geo.size.width - 14))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            playing = false
                            progress = min(max(Double(value.location.x / max(geo.size.width, 1)), 0), 1)
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(start)
                Spacer(minLength: 0)
                Text(end)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(onDark ? Color.white.opacity(0.55) : Theme.tertiary)
            .monospacedDigit()
        }
    }
}

private struct SpeedCurve: View {
    let speeds: [Double]
    var times: [TimeInterval] = []
    var duration: TimeInterval = 0
    let progress: Double
    var tint: Color = Theme.brand
    var height: CGFloat = 112
    var onDark: Bool = false
    let onScrub: (Double) -> Void

    private var maxValue: Double { max(1, speeds.max() ?? 1) }
    /// 和进度条、地图共用同一段墙钟，不能再用 times.last 另算一条轴
    private var span: TimeInterval { max(duration, 1) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let points = laid(out: size)

            ZStack(alignment: .topLeading) {
                grid(size: size)

                if points.count > 1 {
                    area(points, height: size.height)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    line(points)
                        .stroke(
                            tint,
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )

                    peakTag(points, size: size)
                    cursor(size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = Double(value.location.x / max(size.width, 1))
                        onScrub(ratio)
                    }
            )
        }
        .frame(height: height)
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            for i in 0..<3 {
                let y = size.height * CGFloat(i) / 2
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(
            (onDark ? Color.white : Theme.separator).opacity(onDark ? 0.22 : 0.6),
            style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
        )
    }

    /// 顶部留空给峰值标签；x 和回放 progress 共用同一段墙钟时长
    private func laid(out size: CGSize) -> [CGPoint] {
        guard speeds.count > 1 else { return [] }
        let top: CGFloat = 14
        let usable = max(1, size.height - top)
        let useTime = times.count == speeds.count && span > 0
        var points = speeds.enumerated().map { index, speed in
            let x: CGFloat
            if useTime {
                x = size.width * CGFloat(min(max(times[index] / span, 0), 1))
            } else {
                x = size.width * CGFloat(index) / CGFloat(speeds.count - 1)
            }
            let ratio = min(max(speed / maxValue, 0), 1)
            let y = top + usable * (1 - CGFloat(ratio))
            return CGPoint(x: x, y: y)
        }
        if let last = points.last, last.x < size.width - 1 {
            points.append(CGPoint(x: size.width, y: last.y))
        }
        return points
    }

    private func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func area(_ points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: height))
            path.addLine(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.closeSubpath()
        }
    }

    @ViewBuilder
    private func peakTag(_ points: [CGPoint], size: CGSize) -> some View {
        if let peak = points.max(by: { $0.y > $1.y }) {
            Text(String(format: "%.0f", maxValue))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
                .position(x: min(max(peak.x, 18), size.width - 18), y: max(peak.y - 9, 7))
        }
    }

    private func cursor(size: CGSize) -> some View {
        let clamped = min(max(progress, 0), 1)
        let x = size.width * CGFloat(clamped)
        let speed = ReplayClock.sampleValue(speeds, times: times, duration: span, progress: clamped)
        let top: CGFloat = 14
        let usable = max(1, size.height - top)
        let y = top + usable * (1 - CGFloat(min(max(speed / maxValue, 0), 1)))
        return ZStack {
            // 已播放区间淡色遮罩，和时间轴同 progress
            Rectangle()
                .fill(tint.opacity(0.08))
                .frame(width: max(0, x), height: size.height)
                .frame(maxWidth: .infinity, alignment: .leading)

            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: 1.2))

            Circle()
                .fill(Color.white)
                .frame(width: 12, height: 12)
                .shadow(color: tint.opacity(0.45), radius: 4, y: 1)
                .overlay(
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                )
                .position(x: x, y: y)
        }
    }
}

import Foundation
import MapKit
import SwiftUI

/// 轨迹回放：路线卡（点开全屏地图）+ 指标 + 速度曲线 + 起终点 + 脚注，
/// 底部常驻播放条，路线上的光点和曲线进度条跟着回放走。
struct RideReplayView: View {
    let vehicle: Vehicle
    let track: RideTrack

    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var playing = false
    @State private var rate: Double = 1
    @State private var follow = true
    @State private var showFullMap = false

    // MARK: - 数据

    private var coordinates: [CLLocationCoordinate2D] {
        track.points.map { $0.mapCoordinate }
    }

    private var speeds: [Double] { track.speedSamples }

    /// 回放时长：对齐小程序 8–20s，略放慢到 10–22s
    private var playbackSeconds: Double {
        let minutes = max(track.durationMinutes, 1)
        let byTrip = min(20, max(10, Double(minutes == 1 ? 12 : minutes) * 1.1))
        let byPoints = min(22, max(10, Double(max(track.points.count, 1)) * 0.16))
        return min(22, max(byTrip, byPoints))
    }

    private var currentSpeed: Double {
        let samples = speeds
        guard samples.count > 1 else { return 0 }
        let raw = min(max(progress, 0), 1) * Double(samples.count - 1)
        let index = min(samples.count - 2, max(0, Int(raw)))
        let fraction = raw - Double(index)
        return samples[index] + (samples[index + 1] - samples[index]) * fraction
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
        ZStack(alignment: .bottom) {
            Theme.groupedBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    routeCard
                    metricsCard
                    speedCard
                    placeCard
                    footnote
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 8)
                .padding(.bottom, 132)
            }

            playbackBar
        }
        .task(id: playing) {
            guard playing else { return }
            if progress >= 1 { progress = 0 }
            var last = Date()
            while playing && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                if Task.isCancelled { break }
                let now = Date()
                let delta = now.timeIntervalSince(last)
                last = now
                let next = progress + delta * rate / playbackSeconds
                if next >= 1 {
                    progress = 1
                    playing = false
                    break
                }
                progress = next
            }
        }
        .fullScreenCover(isPresented: $showFullMap) { fullMap }
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
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        let time = track.startTime ?? "未记录时间"
        return vehicle.name.isEmpty ? time : "\(vehicle.name) · \(time)"
    }

    // MARK: - 路线卡

    private var routeCard: some View {
        Button {
            showFullMap = true
        } label: {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x0B1728), Color(hex: 0x162C46)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RouteCanvas(coords: track.points, progress: progress)

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        chip(text: playing ? "回放中" : "轨迹", icon: playing ? "play.fill" : "map", tint: .white)
                        Spacer(minLength: 0)
                        chip(text: "全屏", icon: "arrow.up.left.and.arrow.down.right", tint: .white)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        chip(text: String(format: "%.1f km", track.mileage), icon: "point.topleft.down.curvedto.point.bottomright.up", tint: .white)
                        chip(text: "\(track.durationMinutes) 分钟", icon: "clock", tint: .white)
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
            }
            .frame(height: 208)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
            )
            .shadow(color: Theme.cardShadow, radius: 20, x: 0, y: 6)
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
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
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.28)))
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
                    value: track.startAddress ?? "未记录地址"
                )
                HairLine()
                placeRow(
                    icon: "flag.checkered",
                    tint: Theme.orange,
                    title: "终点",
                    value: track.endAddress ?? "未记录地址"
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
                .lineLimit(3)
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

    // MARK: - 全屏地图（放大回放：地图占满 + 底部速度曲线与时间轴联动）

    private var fullMap: some View {
        ZStack(alignment: .bottom) {
            ReplayMap(points: coordinates, speeds: speeds, progress: progress, follow: follow)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.38), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 140)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        showFullMap = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f km · %d 分钟", track.mileage, track.durationMinutes))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(vehicle.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Spacer(minLength: 0)

                    // 当前速度大字
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(speeds.count > 1 ? String(format: "%.0f", currentSpeed) : "--")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text("km/h")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        Text(playing ? "回放中" : "已暂停")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Button {
                        follow.toggle()
                    } label: {
                        Image(systemName: follow ? "location.fill" : "location")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.ultraThinMaterial))
                    }
                    .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 8)

                Spacer(minLength: 0)

                fullMapBottomPanel
            }
        }
    }

    /// 底部：速度折线 + 时间轴，共用 progress，拖曲线或滑条都会联动地图
    private var fullMapBottomPanel: some View {
        VStack(spacing: 10) {
            if speeds.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("速度")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                        Spacer(minLength: 0)
                        Text(String(format: "峰值 %.0f km/h", maxSpeedValue))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .monospacedDigit()
                    }

                    SpeedCurve(
                        speeds: speeds,
                        progress: progress,
                        tint: Theme.brand,
                        height: 88
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

                VStack(spacing: 4) {
                    HStack(spacing: 0) {
                        Text(timeText(progress))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text(" / \(timeText(1))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        if speeds.count > 1 {
                            Text(String(format: "%.0f km/h", currentSpeed))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.brand)
                                .monospacedDigit()
                        }
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
                        .frame(width: 40, height: 32)
                        .background(Capsule().fill(Theme.surfaceAlt))
                }
                .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 22,
                style: .continuous
            )
            .fill(.regularMaterial)
            .shadow(color: Color.black.opacity(0.18), radius: 20, y: -6)
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 工具

    private func timeText(_ ratio: Double) -> String {
        let total = Double(track.durationMinutes) * 60 * min(max(ratio, 0), 1)
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
private struct SpeedCurve: View {
    let speeds: [Double]
    let progress: Double
    var tint: Color = Theme.brand
    var height: CGFloat = 112
    let onScrub: (Double) -> Void

    private var maxValue: Double { max(1, speeds.max() ?? 1) }

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
                    cursor(points, size: size)
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
        .stroke(Theme.separator.opacity(0.6), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
    }

    /// 顶部留 12pt 给峰值标签
    private func laid(out size: CGSize) -> [CGPoint] {
        guard speeds.count > 1 else { return [] }
        let top: CGFloat = 14
        let usable = max(1, size.height - top)
        return speeds.enumerated().map { index, speed in
            let x = size.width * CGFloat(index) / CGFloat(speeds.count - 1)
            let ratio = min(max(speed / maxValue, 0), 1)
            let y = top + usable * (1 - CGFloat(ratio))
            return CGPoint(x: x, y: y)
        }
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

    private func cursor(_ points: [CGPoint], size: CGSize) -> some View {
        let clamped = min(max(progress, 0), 1)
        let x = size.width * CGFloat(clamped)
        let y = value(at: clamped, in: points)
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

    private func value(at ratio: Double, in points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        let raw = ratio * Double(points.count - 1)
        let index = min(points.count - 2, max(0, Int(raw)))
        let fraction = CGFloat(raw - Double(index))
        let a = points[index]
        let b = points[index + 1]
        return a.y + (b.y - a.y) * fraction
    }
}

import MapKit
import SwiftUI

struct RideReplayView: View {
    let vehicle: Vehicle
    var track: RideTrack?

    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var playing = false
    @State private var rate: Double = 1
    @State private var follow = true

    private var resolved: RideTrack {
        track ?? RideDemo.make(near: vehicle.coordinate)
    }

    private var coordinates: [CLLocationCoordinate2D] {
        resolved.points.map { $0.mapCoordinate }
    }

    /// 回放时长：按真实时长收敛到 8–45 秒，太短看不清、太长会闷
    private var playbackSeconds: Double {
        let raw = Double(max(1, resolved.durationMinutes)) * 1.4
        return min(45, max(8, raw))
    }

    private var averageSpeed: Double {
        let hours = Double(max(1, resolved.durationMinutes)) / 60
        return resolved.mileage / hours
    }

    var body: some View {
        ZStack {
            ReplayMap(points: coordinates, progress: progress, follow: follow)
                .ignoresSafeArea()

            edgeGradient

            VStack(spacing: 0) {
                header
                statsCard.padding(.top, 10)
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .background(Theme.groupedBackground)
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
                    progress = 1
                    playing = false
                    break
                }
                progress = next
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.ultraThinMaterial))
                    .shadow(color: Theme.cardShadow, radius: 12, x: 0, y: 4)
            }
            .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))

            Spacer(minLength: 0)

            Button {
                follow.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: follow ? "location.fill" : "location")
                        .font(.system(size: 11, weight: .bold))
                    Text(follow ? "跟随" : "自由")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(follow ? Theme.brand : Theme.secondary)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(Capsule().fill(.ultraThinMaterial))
            }
            .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
        }
    }

    private var statsCard: some View {
        HStack(spacing: 0) {
            statBlock(title: "里程", value: String(format: "%.1f", resolved.mileage), unit: "km")
            statDivider
            statBlock(title: "时长", value: "\(resolved.durationMinutes)", unit: "min")
            statDivider
            statBlock(title: "均速", value: String(format: "%.0f", averageSpeed), unit: "km/h")
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: Theme.cardShadow, radius: 18, x: 0, y: 6)
    }

    private func statBlock(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 0.5, height: 26)
    }

    // MARK: - 控制

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Button {
                    if progress >= 1 { progress = 0 }
                    playing.toggle()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Theme.brand, Color(hex: 0x4B5BFF)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: Theme.brand.opacity(0.45), radius: 14, x: 0, y: 6)
                }
                .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(timeText(progress))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()
                    }

                    Slider(value: $progress, in: 0...1) { editing in
                        if editing { playing = false }
                    }
                    .tint(Theme.brand)
                }
            }

            HStack(spacing: 8) {
                ForEach([1.0, 2.0, 4.0], id: \.self) { value in
                    Button {
                        rate = value
                    } label: {
                        Text("\(Int(value))x")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(rate == value ? .white : Theme.secondary)
                            .frame(width: 46, height: 30)
                            .background(
                                Capsule()
                                    .fill(rate == value ? Theme.brand : Theme.surfaceAlt)
                            )
                    }
                    .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
                }

                Spacer(minLength: 0)

                if track == nil {
                    Text("示例轨迹")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 24, x: 0, y: 10)
    }

    private var edgeGradient: some View {
        VStack {
            LinearGradient(
                colors: [Color.black.opacity(0.22), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.20)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 220)
        }
        .allowsHitTesting(false)
    }

    private func timeText(_ value: Double) -> String {
        let total = Double(resolved.durationMinutes) * 60 * value
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// 没有云端轨迹时用的示例路线：围绕车辆位置画一条环路
enum RideDemo {
    static func make(near origin: Coordinate?) -> RideTrack {
        let base = origin ?? Coordinate(latitude: 30.2741, longitude: 120.1551)
        var points: [Coordinate] = []
        let count = 160
        for index in 0..<count {
            let t = Double(index) / Double(count) * .pi * 2
            let radiusLat = 0.0075 + 0.0016 * sin(t * 3)
            let radiusLng = 0.0105 + 0.0020 * cos(t * 2)
            points.append(
                Coordinate(
                    latitude: base.latitude + sin(t) * radiusLat + 0.0006 * cos(t * 5),
                    longitude: base.longitude + cos(t) * radiusLng
                )
            )
        }
        return RideTrack(
            id: "demo",
            startTime: "示例路线",
            mileage: 8.6,
            durationMinutes: 23,
            points: points
        )
    }
}

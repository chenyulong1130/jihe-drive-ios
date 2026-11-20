import MapKit
import SwiftUI

struct RideReplayView: View {
    let vehicle: Vehicle
    let track: RideTrack

    @Environment(\.dismiss) private var dismiss

    @State private var progress: Double = 0
    @State private var playing = false
    @State private var rate: Double = 1
    @State private var follow = true

    private var coordinates: [CLLocationCoordinate2D] {
        track.points.map { $0.mapCoordinate }
    }

    /// 回放时长：按采样点数（与安卓版一致，每点 0.12 秒），收敛到 4–45 秒
    private var playbackSeconds: Double {
        min(45, max(4, Double(track.points.count) * 0.12))
    }

    /// 当前播放位置的速度（两侧采样线性插值）
    private var currentSpeed: Double {
        let samples = track.speedSamples
        guard samples.count > 1 else { return 0 }
        let raw = min(max(progress, 0), 1) * Double(samples.count - 1)
        let index = min(samples.count - 2, max(0, Int(raw)))
        let fraction = raw - Double(index)
        return samples[index] + (samples[index + 1] - samples[index]) * fraction
    }

    private var maxSpeedValue: Double {
        track.maxSpeed ?? (track.speedSamples.max() ?? 0)
    }

    private var averageSpeed: Double {
        let hours = Double(max(1, track.durationMinutes)) / 60
        return track.mileage / hours
    }

    var body: some View {
        ZStack {
            ReplayMap(points: coordinates, speeds: track.speedSamples, progress: progress, follow: follow)
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
            statBlock(title: "当前", value: String(format: "%.0f", currentSpeed), unit: "km/h")
            statDivider
            statBlock(title: "里程", value: String(format: "%.1f", track.mileage), unit: "km")
            statDivider
            statBlock(title: "最高", value: String(format: "%.0f", maxSpeedValue), unit: "km/h")
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
        let total = Double(track.durationMinutes) * 60 * value
        let minutes = Int(total) / 60
        let seconds = Int(total) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

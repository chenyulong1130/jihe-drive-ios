import SwiftUI
import UIKit

/// 当前主视觉背景的来源
enum BackdropSelection: Equatable {
    case video
    case photo
    case animated(AnimatedBackdropKind)
    case theme(VehicleTheme)
}

/// 车辆主视觉：背景是视频 / 照片 / 动态主题 / 静态主题，底部一条半透明材质数据条。
struct HeroStage: View {
    let vehicle: Vehicle
    let selection: BackdropSelection
    let videoURL: URL?
    let videoPoster: UIImage?
    let photo: UIImage?
    let onPickVehicle: () -> Void
    let onOpenTheme: () -> Void

    /// 照片、视频这类真实画面是主角，车图收一点
    private var isMedia: Bool {
        switch selection {
        case .video, .photo: return true
        default: return false
        }
    }

    private var carHeight: CGFloat { isMedia ? 96 : 126 }

    private let primary = Color.white
    private let secondaryText = Color.white.opacity(0.78)

    var body: some View {
        ZStack {
            backgroundLayer
            carLayer

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                dataBar
            }
            .padding(14)
        }
        .frame(height: 268)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
    }

    // MARK: - 背景

    @ViewBuilder
    private var backgroundLayer: some View {
        switch selection {
        case .video:
            if let videoURL {
                ZStack {
                    if let videoPoster {
                        Image(uiImage: videoPoster)
                            .resizable()
                            .scaledToFill()
                    }
                    LoopingVideoView(url: videoURL)
                }
                .overlay(scrim)
            } else {
                fallbackBackground
            }

        case .photo:
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .overlay(scrim)
            } else {
                fallbackBackground
            }

        case .animated(let kind):
            AnimatedBackdrop(kind: kind)
                .overlay(scrim)

        case .theme(let theme):
            themeBackground(theme)
        }
    }

    @ViewBuilder
    private func themeBackground(_ theme: VehicleTheme) -> some View {
        if let poster = theme.posterURL {
            ZStack {
                gradient(theme.colors)
                AsyncImage(url: poster) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
            .overlay(scrim)
        } else {
            gradient(theme.colors)
        }
    }

    private func gradient(_ colors: [Color]) -> some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Color.white.opacity(0.16), .clear],
                center: .init(x: 0.3, y: 0.2),
                startRadius: 4,
                endRadius: 220
            )
        }
    }

    /// 视频被删掉、照片未授权时兜底
    private var fallbackBackground: some View {
        gradient(VehicleThemeCatalog.all[0].colors)
    }

    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.32), location: 0),
                .init(color: Color.black.opacity(0.06), location: 0.42),
                .init(color: Color.black.opacity(0.52), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 车

    private var carLayer: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)

            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(Color.black.opacity(0.24))
                    .frame(width: 156, height: 12)
                    .blur(radius: 10)
                    .offset(y: 8)

                Group {
                    if let url = vehicle.imageURL {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFit()
                            } else {
                                placeholder
                            }
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(height: carHeight)
            }

            Spacer(minLength: 70)
        }
        .frame(maxWidth: .infinity)
    }

    private var placeholder: some View {
        Image(systemName: "bolt.car.fill")
            .font(.system(size: 52, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.85))
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onPickVehicle) {
                HStack(spacing: 4) {
                    Text(vehicle.name)
                        .font(Theme.title2)
                        .foregroundStyle(primary)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
                .frame(minHeight: Theme.tap, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

            Spacer(minLength: 0)

            Button(action: onOpenTheme) {
                ZStack {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 78, height: 34)

                    HStack(spacing: 5) {
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 12, weight: .medium))
                        Text("主题")
                            .font(Theme.captionStrong)
                    }
                    .foregroundStyle(primary)
                }
                .frame(width: 92, height: Theme.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
            .accessibilityLabel("更换背景主题")
        }
    }

    // MARK: - 数据条

    private var dataBar: some View {
        HStack(spacing: 12) {
            RingProgress(
                progress: Double(min(max(vehicle.soc, 0), 100)) / 100,
                color: vehicle.isCharging ? Theme.green : .white,
                track: Color.white.opacity(0.25),
                lineWidth: 4,
                size: 38
            )

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(min(max(vehicle.soc, 0), 100))")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                Text("%")
                    .font(Theme.caption)
                    .foregroundStyle(secondaryText)
            }

            divider

            bottomStat(title: "续航", value: "\(vehicle.rangeKm)", unit: "km")

            Spacer(minLength: 0)

            statusTag
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.22))
            .frame(width: 0.5, height: 22)
    }

    private func bottomStat(title: String, value: String, unit: String?, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.caption)
                .foregroundStyle(secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint ?? primary)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(Theme.caption)
                        .foregroundStyle(secondaryText)
                }
            }
        }
    }

    private var statusTag: some View {
        Group {
            if vehicle.isCharging {
                GlassTag(text: "充电", icon: "bolt.fill", tint: .white)
            } else if !vehicle.isOnline {
                GlassTag(text: "离线", icon: "wifi.slash", tint: secondaryText)
            } else if !vehicle.isLocked {
                GlassTag(text: "未锁", icon: "lock.open.fill", tint: Theme.yellow)
            } else {
                GlassTag(text: "在线", icon: "dot.radiowaves.left.and.right", tint: .white)
            }
        }
    }
}

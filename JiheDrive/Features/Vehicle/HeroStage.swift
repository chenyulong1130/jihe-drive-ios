import SwiftUI
import UIKit

/// 主视觉背景来源
enum BackdropSelection: Equatable {
    case video
    case photo
    case animated(AnimatedBackdropKind)
    case builtin(BuiltInWallpaper)
    case theme(VehicleTheme)

    var isMedia: Bool {
        switch self {
        case .video, .photo: return true
        default: return false
        }
    }
}

/// 车辆主视觉：整块铺满的背景 + 车辆图 + 左上角电量 + 底部一行数据
struct HeroStage: View {
    let vehicle: Vehicle
    let selection: BackdropSelection
    let videoURL: URL?
    let videoPoster: UIImage?
    let photo: UIImage?
    let onPickVehicle: () -> Void
    let onOpenTheme: () -> Void

    private var carHeight: CGFloat { selection.isMedia ? 176 : 196 }

    private let primary = Color.white
    private let secondaryText = Color.white.opacity(0.76)

    var body: some View {
        ZStack {
            backgroundLayer

            carLayer

            VStack(spacing: 0) {
                topBar
                socBadge.padding(.top, 10)
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .frame(height: 360)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 8)
    }

    // MARK: - 背景

    @ViewBuilder
    private var backgroundLayer: some View {
        Group {
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
                } else {
                    fallbackBackground
                }

            case .photo:
                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                } else {
                    fallbackBackground
                }

            case .animated(let kind):
                AnimatedBackdrop(kind: kind)

            case .builtin(let wallpaper):
                BuiltInWallpaperView(wallpaper: wallpaper)

            case .theme(let theme):
                themeBackground(theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .overlay(scrim)
    }

    @ViewBuilder
    private func themeBackground(_ theme: VehicleTheme) -> some View {
        if let poster = theme.posterURL {
            ZStack {
                LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                AsyncImage(url: poster) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        } else {
            LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var fallbackBackground: some View {
        LinearGradient(
            colors: [Color(hex: 0x04121F), Color(hex: 0x0A2A4A), Color(hex: 0x1D6FB8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 上暗下更暗，保证白字在任何背景上都读得清
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.38), location: 0),
                .init(color: Color.black.opacity(0.04), location: 0.34),
                .init(color: Color.black.opacity(0.10), location: 0.62),
                .init(color: Color.black.opacity(0.55), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 车

    private var carLayer: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(Color.black.opacity(0.32))
                .frame(width: 210, height: 16)
                .blur(radius: 12)
                .offset(y: 6)

            Group {
                if let url = vehicle.imageURL {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFit()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: carHeight)
            .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 12)
        }
        .frame(maxWidth: .infinity)
        .offset(y: 26)
        .allowsHitTesting(false)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "bolt.car.fill")
                .font(.system(size: 66, weight: .regular))
            Text("暂未获取车辆图片")
                .font(Theme.caption)
        }
        .foregroundStyle(primary.opacity(0.8))
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onPickVehicle) {
                HStack(spacing: 6) {
                    Text(vehicle.name)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(primary)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(secondaryText)
                }
                .frame(minHeight: 34, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))

            Spacer(minLength: 0)

            Button(action: onOpenTheme) {
                HStack(spacing: 5) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("背景")
                        .font(Theme.captionStrong)
                }
                .foregroundStyle(primary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .frame(height: Theme.tap)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
            .accessibilityLabel("更换车辆背景")
        }
    }

    // MARK: - 左上角电量

    private var socBadge: some View {
        HStack(spacing: 10) {
            ZStack {
                RingProgress(
                    progress: Double(min(max(vehicle.soc, 0), 100)) / 100,
                    color: socColor,
                    track: Color.white.opacity(0.22),
                    lineWidth: 3.5,
                    size: 42
                )

                Image(systemName: vehicle.isCharging ? "bolt.fill" : "battery.50percent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(vehicle.isCharging ? "充电中" : "剩余电量")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(min(max(vehicle.soc, 0), 100))")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(primary)
                        .monospacedDigit()
                    Text("%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(secondaryText)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var socColor: Color {
        if vehicle.isCharging { return Theme.green }
        if vehicle.soc <= 15 { return Theme.red }
        if vehicle.soc <= 30 { return Theme.orange }
        return Color.white
    }

    // MARK: - 底部数据

    private var bottomBar: some View {
        HStack(spacing: 10) {
            heroStat(title: "续航", value: "\(vehicle.rangeKm)", unit: "km")
            divider
            heroStat(title: "总里程", value: String(format: "%.0f", vehicle.totalMileKm), unit: "km")
            Spacer(minLength: 0)
            statusTag
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 0.5, height: 20)
    }

    private func heroStat(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(primary)
                    .monospacedDigit()
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(secondaryText)
            }
        }
    }

    private var statusTag: some View {
        Group {
            if vehicle.isCharging {
                GlassTag(text: "充电中", icon: "bolt.fill", tint: .white)
            } else if !vehicle.isOnline {
                GlassTag(text: "离线", icon: "wifi.slash", tint: secondaryText)
            } else if !vehicle.isLocked {
                GlassTag(text: "未锁车", icon: "lock.open.fill", tint: Theme.yellow)
            } else {
                GlassTag(text: "已上锁", icon: "lock.fill", tint: .white)
            }
        }
    }
}

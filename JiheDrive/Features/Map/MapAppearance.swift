import MapKit
import SwiftUI

/// 浅色底图，保留建筑和地名；关掉交通，轨迹仍自己画。
enum MapAppearance {
    static func apply(to map: MKMapView) {
        map.mapType = .standard
        map.overrideUserInterfaceStyle = .light
        map.showsCompass = false
        map.showsScale = false
        map.showsBuildings = true
        map.showsTraffic = false
        map.pointOfInterestFilter = .includingAll

        let config = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        config.pointOfInterestFilter = .includingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.backgroundColor = UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
    }

    /// 全屏回放追车：深色 + 真实地形，方便 3D 俯仰
    static func applyCinematic(to map: MKMapView) {
        map.mapType = .standard
        map.overrideUserInterfaceStyle = .dark
        map.showsCompass = false
        map.showsScale = false
        map.showsBuildings = true
        map.showsTraffic = false
        map.pointOfInterestFilter = .includingAll
        let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)
        config.pointOfInterestFilter = .includingAll
        config.showsTraffic = false
        map.preferredConfiguration = config
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.backgroundColor = UIColor(red: 0.07, green: 0.12, blue: 0.14, alpha: 1)
    }
}

/// 轨迹速度配色图例（低蓝 → 高红）
struct TrackSpeedLegend: View {
    var compact: Bool = false
    var onDark: Bool = true

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            Text("慢")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(onDark ? Color.white.opacity(0.9) : Theme.secondary)
            HStack(spacing: 0) {
                ForEach(Array(Self.colors.enumerated()), id: \.offset) { _, color in
                    Rectangle().fill(color)
                }
            }
            .frame(width: compact ? 72 : 88, height: compact ? 6 : 7)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder((onDark ? Color.white : Color.black).opacity(0.18), lineWidth: 0.6))
            Text("快")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(onDark ? Color.white.opacity(0.9) : Theme.secondary)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(Capsule(style: .continuous).fill(onDark ? Color.black.opacity(0.48) : Color.white.opacity(0.92)))
        .accessibilityLabel("速度图例，从慢到快")
    }

    static let colors: [Color] = [
        Color(hex: 0x3B82F6),
        Color(hex: 0x06B6D4),
        Color(hex: 0x22C55E),
        Color(hex: 0xF5A524),
        Color(hex: 0xE5484D)
    ]
}

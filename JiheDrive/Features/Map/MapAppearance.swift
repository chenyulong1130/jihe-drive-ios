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
    }
}

/// 轨迹速度配色图例（低蓝 → 高红）
struct TrackSpeedLegend: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            Text("慢")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 0) {
                ForEach(Array(Self.colors.enumerated()), id: \.offset) { _, color in
                    Rectangle().fill(color)
                }
            }
            .frame(width: compact ? 72 : 88, height: compact ? 6 : 7)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6))
            Text("快")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.48)))
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

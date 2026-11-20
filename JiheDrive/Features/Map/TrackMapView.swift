import MapKit
import SwiftUI

/// 车辆位置全屏地图（MapKit，零第三方依赖）
struct TrackMapView: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @State private var recenterToken = 0
    @State private var showNavOptions = false

    private var coordinate: Coordinate? { vehicle.coordinate }

    var body: some View {
        ZStack {
            VehicleMapView(coordinate: coordinate, showsUser: true, recenterToken: recenterToken)
                .ignoresSafeArea()

            if coordinate == nil {
                emptyHint
            }

            VStack(spacing: 10) {
                actions
                infoCard
                Spacer(minLength: 0)
                if coordinate != nil {
                    PrimaryButton(
                        label: "导航到车辆",
                        icon: "arrow.triangle.turn.up.right.diamond.fill",
                        color: Theme.brand
                    ) {
                        showNavOptions = true
                    }
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .background(Theme.groupedBackground)
        .sheetChrome()
        .onAppear { LocationPermissionRequester.shared.request() }
        .confirmationDialog("选择导航应用", isPresented: $showNavOptions, titleVisibility: .visible) {
            if let coordinate {
                ForEach(NavigationLauncher.options(
                    lat: coordinate.latitude,
                    lon: coordinate.longitude,
                    name: vehicle.name
                )) { option in
                    Button(option.title) { option.action() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("车辆坐标是高德坐标，已按各 App 坐标系转换")
        }
    }

    // MARK: - 顶部

    private var actions: some View {
        HStack(spacing: 8) {
            circleButton(icon: "chevron.down") { dismiss() }
            Spacer(minLength: 0)
            circleButton(icon: "location.fill") { recenterToken += 1 }
        }
    }

    private var infoCard: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(Theme.brand.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                Text(coordinateText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)

                Text(reportText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                Image(systemName: vehicle.isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(vehicle.isLocked ? "已上锁" : "未上锁")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(vehicle.isLocked ? Theme.brand : Theme.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.85)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8)
        )
        .shadow(color: Theme.ink.opacity(0.10), radius: 16, x: 0, y: 6)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "location.slash")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            Text("车辆未上报位置")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.label)
            Text("车辆联网后会自动更新")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.label)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8))
                .shadow(color: Theme.ink.opacity(0.10), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
    }

    // MARK: - 动作

    // MARK: - 文案

    private var coordinateText: String {
        guard let coordinate else { return "暂无坐标" }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private var reportText: String {
        guard let raw = vehicle.locationTime, !raw.isEmpty else { return "暂无上报时间" }
        return "\(raw) 上报"
    }
}

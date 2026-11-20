import SwiftUI

struct RideHomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 从车辆页以弹层方式打开时显示关闭按钮
    var showsClose: Bool = false

    @State private var tracks: [RideTrack] = []
    @State private var loading = false
    @State private var days = 7
    @State private var errorText: String?
    @State private var selected: RideTrack?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                header

                if let vehicle = model.selectedVehicle {
                    summaryCard(vehicle)
                    SectionHeader("轨迹记录")
                    trackList(vehicle)
                } else {
                    Text("先在车辆页登录并选择一台车")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.top, showsClose ? 10 : 4)
            .padding(.bottom, 120)
        }
        .background(Theme.groupedBackground)
        .refreshable { await load(days: days) }
        .task(id: model.selectedVehicle?.vinNo) { await load(days: days) }
        .fullScreenCover(item: $selected) { track in
            if let vehicle = model.selectedVehicle {
                RideReplayView(vehicle: vehicle, track: track)
            }
        }
    }

    private var header: some View {
        Group {
            if showsClose {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("骑行记录")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.label)
                        Text(model.selectedVehicle?.name ?? "尚未选择车辆")
                            .font(Theme.footnote)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Theme.surfaceAlt))
                    }
                    .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
                }
                .padding(.bottom, 6)
            } else {
                LargeTitle("骑行", subtitle: model.selectedVehicle?.name ?? "尚未选择车辆")
            }
        }
    }

    // MARK: - 概览

    private func summaryCard(_ vehicle: Vehicle) -> some View {
        AppleCard {
            VStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                    Text("里程概览")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                    Spacer(minLength: 0)
                    Text("数据来自极核云端")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.tertiary)
                }

                HStack(spacing: 10) {
                    MetricChip(title: "本月", value: vehicle.monthMileage ?? "--", unit: "km", icon: "calendar")
                    MetricChip(title: "总里程", value: String(format: "%.0f", vehicle.totalMileKm), unit: "km", icon: "speedometer")
                    MetricChip(title: "续航", value: "\(vehicle.rangeKm)", unit: "km", icon: "bolt.fill")
                }
            }
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private func trackList(_ vehicle: Vehicle) -> some View {
        VStack(spacing: 10) {
            if let errorText {
                SoftBanner(text: errorText, icon: "exclamationmark.triangle.fill", tone: Theme.orange)
            }

            if loading && tracks.isEmpty {
                loadingRow
            } else if tracks.isEmpty {
                emptyCard
            } else {
                ForEach(tracks) { track in
                    Button {
                        selected = track
                    } label: {
                        trackRow(track)
                    }
                    .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
                }

                Button {
                    days += 7
                    Task { await load(days: days) }
                } label: {
                    HStack(spacing: 6) {
                        if loading {
                            ProgressView().scaleEffect(0.7)
                        }
                        Text(loading ? "正在读取" : "查看更早的记录")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.brand)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Theme.brand.opacity(0.08))
                    }
                }
                .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
                .disabled(loading)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text("正在读取轨迹")
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func trackRow(_ track: RideTrack) -> some View {
        HStack(spacing: 12) {
            RouteThumbnail(points: track.points)
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(track.startTime ?? "未命名行程")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)

                if let from = track.startAddress, !from.isEmpty {
                    Text(track.endAddress.map { "\(from) → \($0)" } ?? from)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 12) {
                    label(icon: "point.topleft.down.curvedto.point.bottomright.up", text: String(format: "%.1f km", track.mileage))
                    label(icon: "clock", text: "\(track.durationMinutes) 分钟")
                    if let speed = track.maxSpeed, speed > 0 {
                        label(icon: "speedometer", text: String(format: "%.0f km/h", speed))
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.brand)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
        .shadow(color: Theme.cardShadow, radius: 20, x: 0, y: 4)
    }

    private func label(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5))
        }
        .foregroundStyle(Theme.secondary)
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "map")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.tertiary)
            Text("最近 \(days) 天没有骑行轨迹")
                .font(Theme.headline)
                .foregroundStyle(Theme.label)
            Text("车辆上报轨迹后会出现在这里")
                .font(Theme.footnote)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - 数据

    private func load(days: Int) async {
        guard let vehicle = model.selectedVehicle else { return }
        loading = true
        errorText = nil
        defer { loading = false }

        guard let items = await RideTrackService.tracks(vin: vehicle.vinNo, days: days) else {
            tracks = []
            errorText = "骑行记录接口没有返回数据，检查网络后下拉重试。"
            return
        }

        tracks = items
        errorText = items.isEmpty ? "最近 \(days) 天云端没有骑行记录。" : nil
    }

    private func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter.string(from: date)
    }
}

/// 用轨迹点画的缩略图
struct RouteThumbnail: View {
    let points: [Coordinate]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0E1B2E), Color(hex: 0x17324F)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Canvas { context, size in
                guard points.count > 1 else { return }
                let lats = points.map { $0.latitude }
                let lngs = points.map { $0.longitude }
                guard let minLat = lats.min(), let maxLat = lats.max(),
                      let minLng = lngs.min(), let maxLng = lngs.max() else { return }

                let spanLat = max(0.000001, maxLat - minLat)
                let spanLng = max(0.000001, maxLng - minLng)
                let inset: CGFloat = 9
                let width = size.width - inset * 2
                let height = size.height - inset * 2

                var path = Path()
                for (index, point) in points.enumerated() {
                    let x = inset + width * CGFloat((point.longitude - minLng) / spanLng)
                    let y = inset + height * CGFloat(1 - (point.latitude - minLat) / spanLat)
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                context.stroke(
                    path,
                    with: .color(Color(hex: 0x4D9BFF)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            .padding(2)
        }
    }
}

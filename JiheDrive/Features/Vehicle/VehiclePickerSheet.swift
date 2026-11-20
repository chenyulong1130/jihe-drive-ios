import SwiftUI

/// 车辆切换：分组列表式卡片，点选即切
struct VehiclePickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetShell(
            title: "切换车辆",
            subtitle: "共 \(model.vehicles.count) 台",
            onClose: { dismiss() }
        ) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    ForEach(model.vehicles) { vehicle in
                        row(vehicle)
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
        .sheetChrome(detents: [.medium, .large])
    }

    private func row(_ vehicle: Vehicle) -> some View {
        let selected = model.selectedVehicle?.vinNo == vehicle.vinNo

        return Button {
            withAnimation(Motion.spring) {
                model.selectedVin = vehicle.vinNo
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                thumb(vehicle)

                VStack(alignment: .leading, spacing: 4) {
                    Text(vehicle.name)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("VIN \(vehicle.vinNo.suffix(6))")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondary)
                            .monospacedDigit()

                        Text(vehicle.isOnline ? "在线" : "离线")
                            .font(Theme.caption)
                            .foregroundStyle(vehicle.isOnline ? Theme.green : Theme.secondary)

                        Text(vehicle.isLocked ? "已上锁" : "未上锁")
                            .font(Theme.caption)
                            .foregroundStyle(vehicle.isLocked ? Theme.secondary : Theme.orange)
                    }
                }

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(vehicle.soc)")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .monospacedDigit()
                    Text("%")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(selected ? Theme.brand : Theme.tertiary.opacity(0.6))
            }
            .padding(14)
            .frame(minHeight: 76)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(selected ? Theme.brand.opacity(0.06) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(selected ? Theme.brand.opacity(0.32) : Color.clear, lineWidth: 1)
            )
            .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private func thumb(_ vehicle: Vehicle) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                .fill(Theme.surfaceAlt)

            if let url = vehicle.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(4)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 58, height: 58)
    }

    private var placeholder: some View {
        Image(systemName: "bolt.car")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(Theme.tertiary)
    }
}

import SwiftUI

/// 车辆切换：型号 + 共享标记，不展示车架号/锁态
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
                VStack(spacing: 8) {
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

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(vehicle.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.label)
                            .lineLimit(1)
                        if vehicle.isShared {
                            Text("共享")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.orange.opacity(0.14)))
                        }
                    }

                    HStack(spacing: 8) {
                        if let modelName = vehicle.modelName, !modelName.isEmpty {
                            Text(modelName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        } else {
                            Text(vehicle.isCarMaster ? "我的车辆" : "共享车辆")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                        }

                        Circle()
                            .fill(vehicle.isOnline ? Theme.green : Theme.tertiary)
                            .frame(width: 5, height: 5)
                        Text(vehicle.isOnline ? "在线" : "离线")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(vehicle.isOnline ? Theme.green : Theme.tertiary)
                    }

                    if vehicle.isShared, let nick = vehicle.shareNickName, !nick.isEmpty {
                        Text("来自 \(nick)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(vehicle.soc)")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.label)
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Text("\(vehicle.rangeKm) km")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                        .monospacedDigit()
                }

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(selected ? Theme.brand : Theme.tertiary.opacity(0.55))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(selected ? Theme.brand.opacity(0.07) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? Theme.brand.opacity(0.35) : Theme.separator.opacity(0.4), lineWidth: 0.8)
            )
        }
        .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    private func thumb(_ vehicle: Vehicle) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .frame(width: 64, height: 52)
    }

    private var placeholder: some View {
        Image(systemName: "bolt.car")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Theme.tertiary)
    }
}

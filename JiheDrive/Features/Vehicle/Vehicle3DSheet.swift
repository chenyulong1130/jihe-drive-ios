import SwiftUI
import UIKit

struct Vehicle3DSheet: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss
    @State private var paintIndex = 0

    private struct Paint: Identifiable {
        let id: Int
        let name: String
        let color: UIColor
    }

    private let paints: [Paint] = [
        Paint(id: 0, name: "竞速蓝", color: UIColor(red: 0.10, green: 0.45, blue: 0.92, alpha: 1)),
        Paint(id: 1, name: "曜石黑", color: UIColor(white: 0.16, alpha: 1)),
        Paint(id: 2, name: "珍珠白", color: UIColor(white: 0.92, alpha: 1)),
        Paint(id: 3, name: "熔岩橙", color: UIColor(red: 0.94, green: 0.38, blue: 0.14, alpha: 1))
    ]

    var body: some View {
        SheetShell(title: "3D 看车", subtitle: vehicle.name, onClose: { dismiss() }) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    stage

                    paintPicker
                        .padding(.top, 16)

                    AppleCard {
                        VStack(spacing: 12) {
                            InfoRow(title: "车型", value: vehicle.name)
                            HairLine()
                            InfoRow(title: "VIN", value: vehicle.vinNo, mono: true)
                            HairLine()
                            InfoRow(title: "当前涂装", value: paints[paintIndex].name)
                            HairLine()
                            InfoRow(
                                title: "车锁",
                                value: vehicle.isLocked ? "已上锁" : "未上锁",
                                valueColor: vehicle.isLocked ? Theme.label : Theme.orange
                            )
                        }
                    }
                    .padding(.top, 16)

                    Text("拖动旋转，双指缩放。模型按极核踏板车比例用几何体拼出，用于展示姿态与涂装。")
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 32)
            }
        }
    }

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x0B1220), Color(hex: 0x16233A), Color(hex: 0x0A1526)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                        center: .center,
                        startRadius: 2,
                        endRadius: 120
                    )
                )
                .frame(width: 300, height: 56)
                .offset(y: 96)
                .blur(radius: 6)

            Vehicle3DView(paint: paints[paintIndex].color)
                .frame(height: 320)

            VStack {
                HStack(spacing: 5) {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("拖动旋转")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(10)

                Spacer(minLength: 0)
            }
        }
        .frame(height: 380)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 8)
    }

    private var paintPicker: some View {
        HStack(spacing: 10) {
            ForEach(paints) { paint in
                Button {
                    withAnimation(Motion.quick) { paintIndex = paint.id }
                } label: {
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(Color(uiColor: paint.color))
                                .frame(width: 34, height: 34)
                            Circle()
                                .strokeBorder(
                                    paintIndex == paint.id ? Theme.brand : Theme.separator,
                                    lineWidth: paintIndex == paint.id ? 2.2 : 0.8
                                )
                                .frame(width: 42, height: 42)
                        }
                        Text(paint.name)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(paintIndex == paint.id ? Theme.label : Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
            }
        }
    }
}

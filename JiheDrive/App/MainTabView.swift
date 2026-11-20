import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case vehicle
    case ride
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vehicle: return "车辆"
        case .ride: return "骑行"
        case .settings: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .vehicle: return "bolt.car"
        case .ride: return "point.topleft.down.curvedto.point.bottomright.up"
        case .settings: return "person"
        }
    }

    var activeIcon: String {
        switch self {
        case .vehicle: return "bolt.car.fill"
        case .ride: return "point.topleft.down.curvedto.point.bottomright.up.fill"
        case .settings: return "person.fill"
        }
    }
}

struct MainTabView: View {
    @State private var tab: MainTab = .vehicle

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.groupedBackground.ignoresSafeArea()

            ZStack {
                page(.vehicle) { VehicleView() }
                page(.ride) { RideHomeView() }
                page(.settings) { SettingsView() }
            }

            LiquidTabBar(tab: $tab)
        }
    }

    private func page<Content: View>(
        _ target: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            // 三个页面同时存在，必须把各自尺寸钳到屏幕内，否则任一页过宽会把整页撑开
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .opacity(tab == target ? 1 : 0)
            .scaleEffect(tab == target ? 1 : 0.985)
            .allowsHitTesting(tab == target)
            .animation(Motion.quick, value: tab)
    }
}

/// 液态悬浮导航：胶囊玻璃底 + 选中项胶囊随动，选中项展开文字
private struct LiquidTabBar: View {
    @Binding var tab: MainTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases) { item in
                itemButton(item)
            }
        }
        .padding(6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), Color.white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.16), radius: 24, x: 0, y: 10)
        .padding(.horizontal, 36)
        .padding(.bottom, 8)
    }

    private func itemButton(_ item: MainTab) -> some View {
        let selected = tab == item
        return Button {
            withAnimation(Motion.liqid) { tab = item }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selected ? item.activeIcon : item.icon)
                    .font(.system(size: 15, weight: .semibold))

                if selected {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .foregroundStyle(selected ? Color.white : Theme.secondary)
            .padding(.horizontal, selected ? 16 : 14)
            .frame(height: 44)
            .background {
                if selected {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.brand, Color(hex: 0x4B5BFF)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Theme.brand.opacity(0.45), radius: 12, x: 0, y: 5)
                        .matchedGeometryEffect(id: "liqid-pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle(scale: 0.93, brightness: 0))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityLabel(item.title)
    }
}

extension Motion {
    /// 液态导航：带一点过冲的回弹
    static let liqid: Animation = .spring(response: 0.36, dampingFraction: 0.72)
}

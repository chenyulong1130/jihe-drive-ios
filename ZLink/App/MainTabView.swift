import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case vehicle
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vehicle: return "车辆"
        case .settings: return "我的"
        }
    }

    var icon: String {
        switch self {
        case .vehicle: return "car"
        case .settings: return "person"
        }
    }

    var activeIcon: String {
        switch self {
        case .vehicle: return "car.fill"
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
                page(.settings) { SettingsView() }
            }

            TabBar(tab: $tab)
        }
    }

    private func page<Content: View>(
        _ target: MainTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(tab == target ? 1 : 0)
            .offset(y: tab == target ? 0 : 8)
            .allowsHitTesting(tab == target)
            .animation(Motion.quick, value: tab)
    }
}

/// 系统风格标签栏：regularMaterial + 顶部 0.5pt 分隔线
private struct TabBar: View {
    @Binding var tab: MainTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { item in
                Button {
                    withAnimation(Motion.quick) { tab = item }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab == item ? item.activeIcon : item.icon)
                            .font(.system(size: 22, weight: .regular))
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(tab == item ? Theme.brand : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 49)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.94, brightness: 0))
                .accessibilityAddTraits(tab == item ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
        }
        .padding(.horizontal, 8)
        .background(alignment: .bottom) {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            HairLine()
        }
    }
}

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
    /// 手指拖动时的临时位移（左滑为负），松手后归零
    @State private var dragOffset: CGFloat = 0

    private var tabs: [MainTab] { MainTab.allCases }
    private var index: Int { tabs.firstIndex(of: tab) ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)

            ZStack(alignment: .bottom) {
                Theme.groupedBackground.ignoresSafeArea()

                // 三个页面并排摆放，整条 HStack 跟着索引位移，拖动时再叠加手指位移
                HStack(alignment: .top, spacing: 0) {
                    ForEach(tabs.indices, id: \.self) { i in
                        page(tabs[i], width: w, pageIndex: i)
                    }
                }
                .frame(width: w * CGFloat(tabs.count), height: geo.size.height, alignment: .topLeading)
                .offset(x: -CGFloat(index) * w + dragOffset)
                .frame(width: w, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(pageDrag(width: w))

                LiquidTabBar(tab: $tab)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sensoryFeedback(.selection, trigger: tab)
    }

    @ViewBuilder
    private func page(_ item: MainTab, width: CGFloat, pageIndex i: Int) -> some View {
        // travel：该页相对视口的水平偏移，0 表示正中对齐
        let travel: CGFloat = CGFloat(i - index) * width + dragOffset
        let progress: CGFloat = min(1, abs(travel) / width)
        let fade: CGFloat = 1 - progress * 0.3
        let zoom: CGFloat = 1 - progress * 0.04

        pageContent(item)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(width: width)
            .clipped()
            // 越远越缩小、变淡，滑动时有纵深，不会两张图硬切
            .opacity(fade)
            .scaleEffect(zoom)
            .allowsHitTesting(progress < 0.5)
    }

    @ViewBuilder
    private func pageContent(_ item: MainTab) -> some View {
        switch item {
        case .vehicle: VehicleView()
        case .ride: RideHomeView()
        case .settings: SettingsView()
        }
    }

    private func pageDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // 只认水平意图，纵向手势留给页面里的 ScrollView
                guard abs(dx) > abs(dy) * 1.2 else { return }

                var offset = dx
                // 首尾再往外拖时给阻尼，拖不动但有余量
                if (index == 0 && offset > 0) || (index == tabs.count - 1 && offset < 0) {
                    offset *= 0.3
                }
                dragOffset = offset
            }
            .onEnded { value in
                let dx = value.translation.width
                let projected = value.predictedEndTranslation.width
                let delta = abs(projected) > abs(dx) ? projected : dx
                let threshold = width * 0.22   // 轻扫即可翻页，不用拖满半屏

                var target = index
                if delta < -threshold {
                    target = min(index + 1, tabs.count - 1)
                } else if delta > threshold {
                    target = max(index - 1, 0)
                }

                // 位移复位和换页放在同一事务里，避免回弹与翻页分成两段
                withAnimation(Motion.liqid) {
                    dragOffset = 0
                    tab = tabs[target]
                }
            }
    }
}

/// 液态悬浮导航：胶囊玻璃底 + 选中项胶囊随动，选中项展开文字
private struct LiquidTabBar: View {
    @Binding var tab: MainTab
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { item in
                itemButton(item)
            }
        }
        .padding(5)
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
        .frame(maxWidth: 320)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func itemButton(_ item: MainTab) -> some View {
        let selected = tab == item
        return Button {
            withAnimation(Motion.liqid) { tab = item }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? item.activeIcon : item.icon)
                    .font(.system(size: 15, weight: .semibold))

                if selected {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .foregroundStyle(selected ? Color.white : Theme.secondary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            // 胶囊只在内容宽度内绘制，视觉保持紧凑
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
            // 但点击区域横向撑满整段 1/3，不再是图标周围那一小块
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
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

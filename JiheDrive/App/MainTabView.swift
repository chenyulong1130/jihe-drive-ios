import SwiftUI
import UIKit

enum MainTab: String, CaseIterable, Identifiable {
    case vehicle
    case device
    case mirror
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vehicle: return "车辆"
        case .device: return "设备"
        case .mirror: return "CarPlay"
        case .settings: return "我的"
        }
    }

    /// 仅使用系统确认存在的 SF Symbol；`bluetooth` / `carplay.fill` 无效会导致空白图标。
    /// mirror 用投屏图标（airplayvideo，SF Symbols 1 起存在，无 fill 变体）
    var icon: String {
        switch self {
        case .vehicle: return "bolt.car"
        case .device: return "antenna.radiowaves.left.and.right"
        case .mirror: return "airplayvideo"
        case .settings: return "person"
        }
    }

    var activeIcon: String {
        switch self {
        case .vehicle: return "bolt.car.fill"
        case .device: return "antenna.radiowaves.left.and.right"
        case .mirror: return "airplayvideo"
        case .settings: return "person.fill"
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var tab: MainTab = .vehicle
    /// 手指拖动时的临时位移（左滑为负），松手后归零
    @State private var dragOffset: CGFloat = 0
    /// 手势方向锁：起点判定一次，之后整个手势只认这个方向
    @State private var panAxis: Axis? = nil
    /// 手指还在屏幕上：拖动位移绝不跟动画，避免「贴着乱抖」
    @State private var isDragging = false
    /// 设备详情页已推入：隐藏悬浮 Tab 栏、禁用横滑翻页，把横滑还给系统返回手势
    @State private var detailActive = false

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
                // 拖动中关掉隐式动画，否则 spring 会和手指抢位移，看起来像贴着乱抖
                .animation(isDragging ? nil : Motion.page, value: tab)
                .animation(isDragging ? nil : Motion.page, value: dragOffset)
                .animation(nil, value: appearance.resolvedScheme)
                .frame(width: w, height: geo.size.height, alignment: .topLeading)
                .clipShape(HorizontalClip())
                .contentShape(Rectangle())
                // 全页横滑翻页：与页面内部手势并行，方向锁决定归属；
                // 车辆页上半（3D 车模）不响应，边缘热区兜底
                .simultaneousGesture(pageDrag(width: w, canStart: { start in
                    if start.x < 28 || start.x > w - 28 { return true }
                    if tab == .mirror {
                        // CarPlay 预览占满本页：横滑全部交给预览的触控转发，
                        // 翻页只走左右边缘热区，否则滑预览就把主界面切页了
                        return false
                    }
                    if tab == .vehicle {
                        return start.y > geo.size.height * 0.56
                    }
                    return true
                }))

                // 左右边缘热区翻页：与全页手势并行，边缘起手永远允许翻页
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 28)
                        .contentShape(Rectangle())
                        .gesture(pageDrag(width: w))
                    Spacer(minLength: 0)
                    Color.clear
                        .frame(width: 28)
                        .contentShape(Rectangle())
                        .gesture(pageDrag(width: w))
                }
                .allowsHitTesting(true)

                // 详情页推入时 Tab 栏收起，详情页获得完整的二级页面视口
                if !detailActive {
                    LiquidTabBar(tab: $tab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .environment(\.activeMainTab, tab)
        .onPreferenceChange(DeviceDetailActiveKey.self) { active in
            withAnimation(Motion.page) { detailActive = active }
        }
        .sensoryFeedback(.selection, trigger: tab)
        .onAppear(perform: applyStatusBar)
        .onChange(of: tab) { _, newTab in
            // 点底栏切页时清掉残留位移，避免和翻页动画叠在一起抖一下
            if !isDragging { dragOffset = 0 }
            applyStatusBar()
            MainThreadHangMonitor.note("切Tab→\(newTab.title)")
        }
    }

    /// 车辆页顶部是深色主视觉铺到状态栏，图标文字要白色才看得清；
    /// 其余页是浅色底，用系统默认（浅色模式黑字 / 深色模式白字）。
    private func applyStatusBar() {
        UIApplication.shared.statusBarStyle = (tab == .vehicle) ? .lightContent : .default
    }

    @ViewBuilder
    private func page(_ item: MainTab, width: CGFloat, pageIndex i: Int) -> some View {
        // travel：该页相对视口的水平偏移，0 表示正中对齐
        let travel: CGFloat = CGFloat(i - index) * width + dragOffset
        let progress: CGFloat = min(1, abs(travel) / width)
        pageContent(item)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .frame(width: width)
            .background(Theme.groupedBackground)
            .clipShape(HorizontalClip())
            .allowsHitTesting(progress < 0.45)
    }

    @ViewBuilder
    private func pageContent(_ item: MainTab) -> some View {
        switch item {
        case .vehicle: VehicleView()
        case .device: DeviceTabView()
        case .mirror: MirrorView()
        case .settings: SettingsView()
        }
    }

    private func pageDrag(width: CGFloat, canStart: @escaping (CGPoint) -> Bool = { _ in true }) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                // 详情页里横滑属于系统返回手势，主界面不再抢
                guard !detailActive else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                // 方向锁：只判一次。水平要明显强于纵向，否则整段交给页面内 ScrollView。
                if panAxis == nil {
                    guard abs(dx) > 12 || abs(dy) > 12 else { return }
                    // 起手点白名单：车辆页上半是 3D 车模拖拽区，不从中间起手翻页
                    if !canStart(value.startLocation) {
                        panAxis = .vertical
                        return
                    }
                    if abs(dx) > abs(dy) * 1.6 {
                        panAxis = .horizontal
                        isDragging = true
                    } else {
                        panAxis = .vertical
                    }
                }
                // 纵向：不碰 dragOffset，让 ScrollView 自己滚
                guard panAxis == .horizontal else { return }

                var offset = dx
                // 首尾再往外拖时给阻尼，拖不动但有余量
                if (index == 0 && offset > 0) || (index == tabs.count - 1 && offset < 0) {
                    offset *= 0.28
                }
                // 直接赋值，无 animation，跟手
                dragOffset = offset
            }
            .onEnded { value in
                let horizontal = panAxis == .horizontal
                panAxis = nil
                isDragging = false

                // 纵向手势直接放弃，不做任何翻页动作
                guard horizontal else {
                    if dragOffset != 0 { dragOffset = 0 }
                    return
                }

                let dx = value.translation.width
                let projected = value.predictedEndTranslation.width
                let delta = abs(projected) > abs(dx) ? projected : dx
                let threshold = width * 0.2

                var target = index
                if delta < -threshold {
                    target = min(index + 1, tabs.count - 1)
                } else if delta > threshold {
                    target = max(index - 1, 0)
                }

                // 位移复位和换页放在同一事务里，避免回弹与翻页分成两段
                withAnimation(Motion.page) {
                    dragOffset = 0
                    tab = tabs[target]
                }
            }
    }
}

/// 只裁左右：翻页时不让邻页漏进来，但上下不裁——
/// 页面内容要能顶进状态栏（车辆页的背景视频/壁纸必须铺到屏幕顶），
/// 之前用 `.clipped()` 把 `ignoresSafeArea` 撑出去的部分全裁了，视频就到不了顶。
private struct HorizontalClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(
            CGRect(
                x: rect.minX,
                y: rect.minY - 3000,
                width: rect.width,
                height: rect.height + 6000
            )
        )
    }
}

/// 设备详情推入时由 DeviceTabView 上抛 true：主界面隐藏 Tab 栏并停用横滑翻页
struct DeviceDetailActiveKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
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
            ZStack {
                // 材质兜底底色：快速滚动列表时 .ultraThinMaterial 的采样可能
                // 失效变全透明，导航栏会"隐形"。下面垫一层 85% 不透明的页面底色，
                // 材质正常时它被盖住不影响观感，材质失效时保住可见性。
                Capsule(style: .continuous)
                    .fill(Theme.groupedBackground.opacity(0.85))
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
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
            }
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
        .shadow(color: Theme.softShadow, radius: 24, x: 0, y: 10)
        // 4 个 tab：选中项带文字，每格至少 ~80pt，避免「CarPlay」被压扁
        .frame(maxWidth: 340)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func itemButton(_ item: MainTab) -> some View {
        let selected = tab == item
        return Button {
            withAnimation(Motion.page) { tab = item }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? item.activeIcon : item.icon)
                    .font(.system(size: 15, weight: .semibold))

                if selected {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .foregroundStyle(selected ? Color.white : Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 44)
            // 胶囊只在内容宽度内绘制，视觉保持紧凑
            .background {
                if selected {
                    Capsule(style: .continuous)
                        .fill(Theme.brand)
                        .shadow(color: Theme.brand.opacity(0.30), radius: 10, x: 0, y: 4)
                        .matchedGeometryEffect(id: "liqid-pill", in: pill)
                }
            }
            // 但点击区域横向撑满整格，不再是图标周围那一小块
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.93, brightness: 0))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityLabel(item.title)
    }
}

private struct ActiveMainTabKey: EnvironmentKey {
    static let defaultValue: MainTab = .vehicle
}

extension EnvironmentValues {
    var activeMainTab: MainTab {
        get { self[ActiveMainTabKey.self] }
        set { self[ActiveMainTabKey.self] = newValue }
    }
}

extension Motion {
    /// 翻页：重页面（WebGL/视频层）跟手拖动时合成开销大，动画拖得越长卡顿越明显；
    /// 收紧到 0.35/0.88，切页更干脆，重层被拖动的时间窗口更短。
    static let page: Animation = .interactiveSpring(response: 0.35, dampingFraction: 0.88, blendDuration: 0.1)
    /// 保留旧名给别处，避免编译炸
    static let liqid: Animation = page
}

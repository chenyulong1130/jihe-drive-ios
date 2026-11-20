import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var themeStore = ThemeStore()
    @StateObject private var wallpaperStore = WallpaperStore()
    @StateObject private var videoStore = VideoBackdropStore()

    var body: some View {
        ZStack {
            Theme.groupedBackground.ignoresSafeArea()

            if model.isLoggedIn {
                MainTabView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
        .environmentObject(model)
        .environmentObject(themeStore)
        .environmentObject(wallpaperStore)
        .environmentObject(videoStore)
        .tint(Theme.brand)
        .animation(Motion.spring, value: model.isLoggedIn)
        .task { await model.bootstrap() }
        .onAppear(perform: paintWindow)
    }

    /// 状态栏那一条（灵动岛左右）是透出 window 底色的，
    /// 把它设成页面同色，整页才真正铺满屏幕，不再露出系统白/黑。
    private func paintWindow() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.backgroundColor = UIColor.systemGroupedBackground
            }
        }
    }
}

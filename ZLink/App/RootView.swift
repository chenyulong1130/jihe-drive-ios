import SwiftUI

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
    }
}

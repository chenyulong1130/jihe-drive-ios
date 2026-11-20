import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var themeStore = ThemeStore()
    @StateObject private var wallpaperStore = WallpaperStore()
    @StateObject private var videoStore = VideoBackdropStore()
    @StateObject private var appearance = AppearanceStore()

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
        .environmentObject(appearance)
        .preferredColorScheme(appearance.mode.colorScheme)
        .tint(Theme.brand)
        .animation(Motion.spring, value: model.isLoggedIn)
        .animation(Motion.quick, value: appearance.mode)
        .task { await model.bootstrap() }
        .onAppear { appearance.applyToWindows() }
        .onChange(of: appearance.mode) { _, _ in
            appearance.applyToWindows()
        }
    }
}

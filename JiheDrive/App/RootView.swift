import SwiftUI
import UIKit

struct RootView: View {
    @StateObject private var model = AppModel()
    @StateObject private var themeStore = ThemeStore()
    @StateObject private var wallpaperStore = WallpaperStore()
    @StateObject private var videoStore = VideoBackdropStore()
    @StateObject private var appearance = AppearanceStore()
    @StateObject private var messages = MessageStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.groupedBackground.ignoresSafeArea()

            if model.isLoggedIn {
                MainTabView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .ignoresSafeArea(.keyboard)
                    .transition(.opacity)
            }
        }
        .environmentObject(model)
        .environmentObject(themeStore)
        .environmentObject(wallpaperStore)
        .environmentObject(videoStore)
        .environmentObject(appearance)
        .environmentObject(messages)
        .preferredColorScheme(appearance.resolvedScheme)
        .tint(Theme.brand)
        .animation(Motion.spring, value: model.isLoggedIn)
        .animation(nil, value: appearance.resolvedScheme)
        .task {
            await model.bootstrap()
            if let video = themeStore.resolvedVideoURL(local: videoStore.url) {
                _ = await ResourceCache.file(for: video, folder: "videos")
            }
            _ = await ResourceCache.image(for: themeStore.current.posterURL)
            _ = await ResourceCache.image(for: model.selectedVehicle?.imageURL)
        }
        .onAppear {
            appearance.applyToWindows(setStyle: true)
            KeyboardAvoidance.setKeyboardRegion(!model.isLoggedIn)
        }
        .onChange(of: model.isLoggedIn) { _, loggedIn in
            KeyboardAvoidance.setKeyboardRegion(!loggedIn)
        }
        .task(id: model.isLoggedIn) {
            guard model.isLoggedIn else { return }
            LocationPermissionRequester.shared.request()
            messages.requestPermission()
            await messages.refresh()
            // 前台约 2 分钟轮询消息（对齐几何面板 10 分钟偏慢，收件箱要更勤）
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { break }
                await messages.refresh()
            }
        }
        .onChange(of: appearance.mode) { _, _ in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                appearance.refreshResolved()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                appearance.applyToWindows(setStyle: false)
            }
        }
        .animation(nil, value: scenePhase)
    }
}

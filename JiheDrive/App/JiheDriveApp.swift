import SwiftUI
import UserNotifications

@main
struct JiheDriveApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        ResourceCache.bootstrap()
        UNUserNotificationCenter.current().delegate = NotificationGate.shared
        // 主线程卡死监测：卡死时自动把时长+事件环写入 Documents/hang_report.log
        MainThreadHangMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onChange(of: scenePhase) { _, phase in
                    MainThreadHangMonitor.note("场景→\(phase)")
                }
        }
    }
}

/// 方向门控：全 App 默认竖屏；CarPlay 全屏呈现期间放行横屏（由 fullscreen 开关切换）
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

/// 前台也弹出横幅，否则人在 App 里时新消息没提示
final class NotificationGate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationGate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge, .list]
    }
}

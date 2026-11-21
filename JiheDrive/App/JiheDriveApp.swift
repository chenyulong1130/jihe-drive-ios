import SwiftUI
import UserNotifications

@main
struct JiheDriveApp: App {
    init() {
        ResourceCache.bootstrap()
        UNUserNotificationCenter.current().delegate = NotificationGate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
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

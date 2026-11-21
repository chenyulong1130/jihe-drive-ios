import SwiftUI

@main
struct JiheDriveApp: App {
    init() {
        ResourceCache.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

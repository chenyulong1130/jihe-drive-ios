import SwiftUI
import UIKit

@main
struct JiheDriveApp: App {
    init() {
        ResourceCache.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootHost()
                .ignoresSafeArea()
        }
    }
}

private struct RootHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LockedHosting {
        LockedHosting(rootView: RootView())
    }

    func updateUIViewController(_ uiViewController: LockedHosting, context: Context) {}
}

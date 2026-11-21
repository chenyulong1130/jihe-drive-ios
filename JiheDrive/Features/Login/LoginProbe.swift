import SwiftUI
import UIKit

/// 临时诊断条：只在登录页显示，用来确认窗口 / 宿主视图 / 卡片的真实屏幕坐标。
/// 定位完成后整份文件删除。
struct LoginProbe: View {
    let cardFrame: CGRect
    let pageSize: CGSize
    let keyboardHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            let snap = Snapshot.read()
            VStack(alignment: .leading, spacing: 1) {
                Text("card y\(Int(cardFrame.minY)) h\(Int(cardFrame.height)) page h\(Int(pageSize.height))")
                Text("win y\(Int(snap.winY)) h\(Int(snap.winH)) host y\(Int(snap.hostY)) h\(Int(snap.hostH))")
                Text("safeB\(Int(snap.safeBottom)) kb\(Int(keyboardHeight)) tx\(snap.transformed ? 1 : 0)")
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.yellow)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .padding(.top, 2)
    }

    private struct Snapshot {
        var winY: CGFloat = -999
        var winH: CGFloat = 0
        var hostY: CGFloat = -999
        var hostH: CGFloat = 0
        var safeBottom: CGFloat = -1
        var transformed = false

        static func read() -> Snapshot {
            var snap = Snapshot()
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    guard let root = window.rootViewController,
                          String(describing: type(of: root)).contains("Hosting") else { continue }
                    snap.winY = window.frame.origin.y
                    snap.winH = window.frame.height
                    let host = root.view!
                    snap.hostY = host.frame.origin.y
                    snap.hostH = host.frame.height
                    snap.safeBottom = host.safeAreaInsets.bottom
                    snap.transformed = host.transform != .identity
                    return snap
                }
            }
            return snap
        }
    }
}

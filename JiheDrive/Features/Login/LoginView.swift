import SwiftUI
import UIKit

/// 登录页：SwiftUI 只留一层壳，界面与键盘避让全部交给 UIKit 实现，
/// 避免 SwiftUI 侧布局/渲染异常导致整页空白。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        LoginPanelHost(model: model)
            .ignoresSafeArea()
    }
}

private struct LoginPanelHost: UIViewControllerRepresentable {
    let model: AppModel

    func makeUIViewController(context: Context) -> LoginPanelController {
        LoginPanelController(model: model)
    }

    func updateUIViewController(_ controller: LoginPanelController, context: Context) {}
}

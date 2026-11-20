import SwiftUI

/// 页面底：系统分组背景
struct AmbientBackground: View {
    var body: some View {
        Theme.groupedBackground
            .ignoresSafeArea()
    }
}

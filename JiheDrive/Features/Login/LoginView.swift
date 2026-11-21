import SwiftUI
import UIKit

/// 弹窗式登录：遮罩 + 浮动卡片。
/// 卡片放在 ScrollView 里，键盘弹出时系统只压缩滚动区（必要时自动滚动到焦点），页面本身不动，
/// 不再用任何私有 API 硬关键盘避让。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    private enum Mode: String, CaseIterable, Identifiable {
        case phone, token
        var id: String { rawValue }
        var title: String { self == .phone ? "手机号" : "Token" }
    }

    private enum Field: Hashable {
        case phone, code, token
    }

    @State private var mode: Mode = .phone
    @State private var phone = ""
    @State private var code = ""
    @State private var token = ""
    @State private var countdown = 0
    @State private var sending = false
    @State private var submitting = false
    @State private var message: String?
    @State private var countdownTask: Task<Void, Never>?
    @FocusState private var focus: Field?
    @Namespace private var modePill
    @State private var keyboardHeight: CGFloat = 0
    @State private var cardFrame: CGRect = .zero
    @State private var pageSize: CGSize = .zero

    private var phoneValid: Bool { phone.count == 11 && phone.hasPrefix("1") }
    private var canSendCode: Bool { phoneValid && countdown == 0 && !sending }
    private var canSubmit: Bool {
        switch mode {
        case .phone: return phoneValid && code.count >= 4 && !submitting
        case .token: return token.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 && !submitting
        }
    }

    var body: some View {
        ZStack {
            Theme.groupedBackground
                .ignoresSafeArea()

            // 遮罩：压暗背景，衬出弹窗
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 110)
                    dialog
                        .padding(.horizontal, 26)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: CardFrameKey.self, value: geo.frame(in: .global))
                            }
                        )
                    Color.clear.frame(height: 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)

            LoginProbe(cardFrame: cardFrame, pageSize: pageSize, keyboardHeight: keyboardHeight)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onTapGesture { focus = nil }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { pageSize = geo.size }
                    .onChange(of: geo.size) { _, size in pageSize = size }
            }
        )
        .onPreferenceChange(CardFrameKey.self) { cardFrame = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            keyboardHeight = max(0, screenHeight - frame.minY)
        }
    }

    // MARK: - 弹窗卡片

    private var dialog: some View {
        VStack(spacing: 0) {
            header

            modeSwitch
                .padding(.top, 18)

            Group {
                if mode == .phone {
                    phoneRows
                } else {
                    tokenRow
                }
            }
            .padding(.top, 14)

            if let message {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }

            PrimaryButton(
                label: submitting ? "登录中" : (mode == .phone ? "登录" : "用 Token 进入"),
                icon: submitting ? nil : "arrow.right",
                enabled: canSubmit,
                loading: submitting
            ) {
                submit()
            }
            .padding(.top, 16)
        }
        .padding(18)
        .frame(maxWidth: 380)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.softShadow, radius: 28, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.separator.opacity(0.7), lineWidth: 0.5)
        )
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.brand.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: "bolt.car.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
            Text("极核智行")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.label)
            Text("验证手机号，或粘贴 Token 进入")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var modeSwitch: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { item in
                Button {
                    withAnimation(Motion.spring) {
                        mode = item
                        message = nil
                        focus = nil
                    }
                } label: {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(mode == item ? Theme.label : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if mode == item {
                                Capsule(style: .continuous)
                                    .fill(Theme.surfaceAlt)
                                    .matchedGeometryEffect(id: "login-mode", in: modePill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Theme.surfaceAlt.opacity(0.6)))
    }

    // MARK: - 表单行

    private var phoneRows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 20)
                TextField("手机号", text: $phone)
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                    .focused($focus, equals: .phone)
                    .font(.system(size: 16))
                    .onChange(of: phone) { _, value in
                        let filtered = String(value.filter(\.isNumber).prefix(11))
                        if filtered != phone { phone = filtered }
                    }
            }
            .padding(.horizontal, 4)
            .frame(height: 48)

            HairLine(inset: 4)

            HStack(spacing: 8) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 20)
                TextField("短信验证码", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                    .font(.system(size: 16))
                    .onChange(of: code) { _, value in
                        let filtered = String(value.filter(\.isNumber).prefix(6))
                        if filtered != code { code = filtered }
                    }
                Button(action: sendCode) {
                    Text(countdown > 0 ? "\(countdown)s" : (sending ? "发送中" : "获取验证码"))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(canSendCode ? Theme.brand : Theme.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(canSendCode ? Theme.brand.opacity(0.10) : Theme.surfaceAlt)
                        )
                }
                .buttonStyle(PressableStyle(scale: 0.93))
                .disabled(!canSendCode)
            }
            .padding(.horizontal, 4)
            .frame(height: 48)
        }
    }

    private var tokenRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 20)
                .padding(.top, 10)
            ZStack(alignment: .topLeading) {
                if token.isEmpty {
                    Text("粘贴 access token")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $token)
                    .focused($focus, equals: .token)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .frame(height: 84)
        }
    }

    // MARK: - 动作

    private func sendCode() {
        guard canSendCode else { return }
        sending = true
        withAnimation(Motion.quick) { message = nil }
        Task {
            do {
                try await model.requestCode(phone: phone)
                startCountdown()
                focus = .code
            } catch {
                withAnimation(Motion.quick) { message = error.localizedDescription }
            }
            sending = false
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task {
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        submitting = true
        withAnimation(Motion.quick) { message = nil }
        Task {
            do {
                switch mode {
                case .phone:
                    try await model.login(phone: phone, code: code)
                case .token:
                    try await model.loginWithToken(token)
                    token = ""
                }
            } catch {
                withAnimation(Motion.quick) { message = error.localizedDescription }
            }
            submitting = false
        }
    }
}

private struct CardFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

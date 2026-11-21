import SwiftUI
import UIKit

/// 整页登录：顶部品牌区 + 白色表单卡。输入框用 UIKit，避免键盘把页面顶没。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    private enum Mode: String, CaseIterable, Identifiable {
        case phone, token
        var id: String { rawValue }
        var title: String { self == .phone ? "手机号" : "Token" }
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
    @Namespace private var modePill

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
            loginBackdrop
                .onTapGesture { hideKeyboard() }

            VStack(spacing: 0) {
                header
                    .padding(.top, 28)
                    .padding(.bottom, 26)

                dialog
                    .padding(.horizontal, 22)

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 36)
        }
        .locksKeyboardAvoidance()
        .onAppear { KeyboardAvoidance.setKeyboardRegion(false) }
        .onDisappear { KeyboardAvoidance.setKeyboardRegion(true) }
    }

    private var loginBackdrop: some View {
        ZStack(alignment: .top) {
            Theme.groupedBackground
            LinearGradient(
                colors: [
                    Theme.brand.opacity(0.18),
                    Theme.brand.opacity(0.05),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 340)
        }
        .ignoresSafeArea()
    }

    // MARK: - 表单卡

    private var dialog: some View {
        VStack(spacing: 0) {
            modeSwitch

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
        .padding(20)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.softShadow, radius: 32, x: 0, y: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.7), lineWidth: 0.8)
        )
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 86, height: 86)
                    .shadow(color: Theme.cardShadow, radius: 22, y: 6)
                Circle()
                    .fill(Theme.brand.opacity(0.12))
                    .frame(width: 62, height: 62)
                Image(systemName: "bolt.car.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
            Text("极核智行")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.label)
            Text("验证手机号，或粘贴 Token 进入")
                .font(.system(size: 14, weight: .medium))
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
                LoginKitField(text: $phone, placeholder: "手机号", keyboard: .numberPad)
                    .frame(height: 22)
            }
            .padding(.horizontal, 4)
            .frame(height: 48)

            HairLine(inset: 4)

            HStack(spacing: 8) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 20)
                LoginKitField(text: $code, placeholder: "短信验证码", keyboard: .numberPad)
                    .frame(height: 22)
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
                .padding(.top, 14)
            LoginKitArea(text: $token, placeholder: "粘贴 access token")
                .frame(height: 84)
        }
    }

    // MARK: - 动作

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func sendCode() {
        guard canSendCode else { return }
        sending = true
        withAnimation(Motion.quick) { message = nil }
        Task {
            do {
                try await model.requestCode(phone: phone)
                startCountdown()
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
        hideKeyboard()
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

private struct LoginKitField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var keyboard: UIKeyboardType

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.keyboardType = keyboard
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.tintColor = .systemBlue
        field.borderStyle = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.textContentType = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        field.keyboardType = keyboard
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func changed(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            guard textField.keyboardType == .numberPad else { return true }
            let current = textField.text ?? ""
            let next = (current as NSString).replacingCharacters(in: range, with: string)
            return next.count <= 11 && next.allSatisfy(\.isNumber)
        }
    }
}

private struct LoginKitArea: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textColor = .label
        view.tintColor = .systemBlue
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.textContentType = .none
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.placeholder.text = placeholder
        view.addSubview(context.coordinator.placeholder)
        context.coordinator.placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            context.coordinator.placeholder.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            context.coordinator.placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4)
        ])
        context.coordinator.syncPlaceholder(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.placeholder.text = placeholder
        if view.text != text { view.text = text }
        context.coordinator.syncPlaceholder(view)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        let placeholder = UILabel()
        init(text: Binding<String>) {
            self.text = text
            super.init()
            placeholder.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            placeholder.textColor = .placeholderText
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            syncPlaceholder(textView)
        }

        func syncPlaceholder(_ textView: UITextView) {
            placeholder.isHidden = !textView.text.isEmpty
        }
    }
}

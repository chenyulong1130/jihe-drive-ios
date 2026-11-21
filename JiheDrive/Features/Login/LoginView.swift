import SwiftUI
import UIKit

struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    private enum Mode: String, CaseIterable, Identifiable {
        case phone
        case token

        var id: String { rawValue }
        var title: String { self == .phone ? "手机号" : "Token" }
    }

    private enum Field: Hashable {
        case phone
        case code
        case token
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
            AmbientBackground()
                .onTapGesture { focus = nil }

            VStack(spacing: 0) {
                emblem.staggerIn(0)
                    .padding(.top, 40)

                Text("极核智行")
                    .font(Theme.largeTitle)
                    .foregroundStyle(Theme.label)
                    .padding(.top, 20)
                    .staggerIn(1)

                modeSwitch
                    .padding(.top, 26)
                    .staggerIn(2)

                Group {
                    if mode == .phone {
                        phoneForm
                    } else {
                        tokenForm
                    }
                }
                .padding(.top, 12)
                .staggerIn(3)

                if let message {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11))
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.red)
                    .padding(.top, 12)
                    .transition(.opacity)
                }

                PrimaryButton(
                    label: buttonTitle,
                    icon: submitting ? nil : "arrow.right",
                    enabled: canSubmit,
                    loading: submitting
                ) {
                    submit()
                }
                .padding(.top, 18)
                .staggerIn(4)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 22)
        }
    }

    private var buttonTitle: String {
        if submitting { return "登录中" }
        return mode == .phone ? "登录" : "用 Token 登录"
    }

    // MARK: - 徽标

    private var emblem: some View {
        ZStack {
            Circle()
                .fill(Theme.surface)
                .frame(width: 88, height: 88)
                .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)

            Circle()
                .fill(Theme.brand.opacity(0.10))
                .frame(width: 60, height: 60)

            Image(systemName: "bolt.car.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.brand)
        }
    }

    // MARK: - 方式切换

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
                        .frame(height: 38)
                        .background {
                            if mode == item {
                                Capsule(style: .continuous)
                                    .fill(Theme.surface)
                                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)
                                    .matchedGeometryEffect(id: "login-mode", in: modePill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.97, brightness: 0))
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Theme.surfaceAlt.opacity(0.7)))
    }

    // MARK: - 手机号

    private var phoneForm: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(focus == .phone ? Theme.brand : Theme.tertiary)
                    .frame(width: 20)

                TextField("手机号", text: $phone)
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                    .focused($focus, equals: .phone)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.label)
                    .tint(Theme.brand)

                Button {
                    sendCode()
                } label: {
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
            .padding(.horizontal, 14)
            .frame(height: 56)

            HairLine(inset: 44)

            HStack(spacing: 10) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(focus == .code ? Theme.brand : Theme.tertiary)
                    .frame(width: 20)

                TextField("短信验证码", text: $code)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .code)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.label)
                    .tint(Theme.brand)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
        }
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
        .animation(Motion.quick, value: focus)
    }

    // MARK: - Token

    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(focus == .token ? Theme.brand : Theme.tertiary)
                    .frame(width: 20)

                TextField("粘贴 access token", text: $token, axis: .vertical)
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .token)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.label)
                    .tint(Theme.brand)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            if !token.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                    Text("已输入 \(token.trimmingCharacters(in: .whitespacesAndNewlines).count) 个字符")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer(minLength: 0)
                    Button("清空") {
                        token = ""
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
        .animation(Motion.quick, value: focus)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.surface)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(
                focus == nil ? Color.clear : Theme.brand.opacity(0.6),
                lineWidth: focus == nil ? 0 : 1.5
            )
    }

    // MARK: - 动作

    private func sendCode() {
        guard canSendCode else { return }
        focus = .code
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

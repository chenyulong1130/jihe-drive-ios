import SwiftUI
import UIKit

/// 登录页用 UIKit 自绘，避免 SwiftUI TextField 把整页顶出屏幕。
struct LoginView: UIViewControllerRepresentable {
    @EnvironmentObject private var model: AppModel

    func makeUIViewController(context: Context) -> LoginViewController {
        let vc = LoginViewController()
        vc.model = model
        return vc
    }

    func updateUIViewController(_ vc: LoginViewController, context: Context) {
        vc.model = model
    }
}

final class LoginViewController: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    var model: AppModel?

    private enum Mode { case phone, token }

    private var mode: Mode = .phone {
        didSet { applyMode() }
    }

    private let canvas = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1)
            : UIColor(red: 0.933, green: 0.945, blue: 0.961, alpha: 1)
    }
    private let surface = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.145, blue: 0.204, alpha: 1)
            : UIColor.white
    }
    private let track = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(red: 0.47, green: 0.52, blue: 0.59, alpha: 0.12)
    }

    private let header = UIView()
    private let mark = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let modeTrack = UIView()
    private let phoneTab = UIButton(type: .system)
    private let tokenTab = UIButton(type: .system)
    private let card = UIView()
    private let phoneField = UITextField()
    private let codeField = UITextField()
    private let codeButton = UIButton(type: .system)
    private let phoneBlock = UIStackView()
    private let tokenView = UITextView()
    private let tokenPlaceholder = UILabel()
    private let tokenBlock = UIView()
    private let submit = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    private var countdown = 0
    private var timer: Timer?
    private var sending = false
    private var submitting = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = canvas
        view.keyboardLayoutGuide.followsUndockedKeyboard = false

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        buildHeader()
        buildMode()
        buildCard()
        buildSubmit()
        layout()
        applyMode()
        refreshSubmit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        KeyboardAvoidance.setKeyboardRegion(false)
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Layout

    private func layout() {
        let stack = UIStackView(arrangedSubviews: [
            header, modeTrack, card, submit, errorLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            modeTrack.heightAnchor.constraint(equalToConstant: 42),
            submit.heightAnchor.constraint(equalToConstant: 50)
        ])
        stack.setCustomSpacing(22, after: header)
    }

    private func buildHeader() {
        mark.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        mark.layer.cornerRadius = 16
        mark.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "bolt.car.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        mark.addSubview(icon)

        titleLabel.text = "极核智行"
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .label

        subtitleLabel.text = "验证手机号，或粘贴 Token 进入"
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = .secondaryLabel

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 4

        let row = UIStackView(arrangedSubviews: [mark, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(row)

        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 52),
            mark.heightAnchor.constraint(equalToConstant: 52),
            icon.centerXAnchor.constraint(equalTo: mark.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: mark.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            row.topAnchor.constraint(equalTo: header.topAnchor),
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
    }

    private func buildMode() {
        modeTrack.backgroundColor = track
        modeTrack.layer.cornerRadius = 21

        configureTab(phoneTab, title: "手机号")
        configureTab(tokenTab, title: "Token")
        phoneTab.addTarget(self, action: #selector(pickPhone), for: .touchUpInside)
        tokenTab.addTarget(self, action: #selector(pickToken), for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [phoneTab, tokenTab])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        modeTrack.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: modeTrack.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: modeTrack.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: modeTrack.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: modeTrack.trailingAnchor, constant: -4)
        ])
    }

    private func configureTab(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        button.layer.cornerRadius = 17
        button.clipsToBounds = true
    }

    private func buildCard() {
        card.backgroundColor = surface
        card.layer.cornerRadius = 14
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.08
        card.layer.shadowRadius = 18
        card.layer.shadowOffset = CGSize(width: 0, height: 6)

        phoneField.placeholder = "手机号"
        phoneField.keyboardType = .numberPad
        phoneField.textContentType = .telephoneNumber
        phoneField.font = .systemFont(ofSize: 17)
        phoneField.delegate = self
        phoneField.addTarget(self, action: #selector(fieldsChanged), for: .editingChanged)
        phoneField.leftView = fieldIcon("iphone")
        phoneField.leftViewMode = .always
        phoneField.clearButtonMode = .whileEditing

        codeField.placeholder = "短信验证码"
        codeField.keyboardType = .numberPad
        codeField.font = .systemFont(ofSize: 17)
        codeField.delegate = self
        codeField.addTarget(self, action: #selector(fieldsChanged), for: .editingChanged)
        codeField.leftView = fieldIcon("lock.rotation")
        codeField.leftViewMode = .always

        codeButton.setTitle("获取验证码", for: .normal)
        codeButton.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .bold)
        codeButton.addTarget(self, action: #selector(sendCode), for: .touchUpInside)
        codeButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        codeButton.layer.cornerRadius = 8
        codeButton.translatesAutoresizingMaskIntoConstraints = false
        codeButton.setContentHuggingPriority(.required, for: .horizontal)

        let codeRow = UIStackView(arrangedSubviews: [codeField, codeButton])
        codeRow.axis = .horizontal
        codeRow.alignment = .center
        codeRow.spacing = 8

        let line = UIView()
        line.backgroundColor = UIColor.separator.withAlphaComponent(0.6)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true

        phoneBlock.axis = .vertical
        phoneBlock.spacing = 0
        [wrap(phoneField), line, wrap(codeRow)].forEach { phoneBlock.addArrangedSubview($0) }

        tokenView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tokenView.backgroundColor = .clear
        tokenView.delegate = self
        tokenView.textContainerInset = UIEdgeInsets(top: 14, left: 8, bottom: 14, right: 12)
        tokenView.translatesAutoresizingMaskIntoConstraints = false
        tokenView.heightAnchor.constraint(equalToConstant: 92).isActive = true

        tokenPlaceholder.text = "粘贴 access token"
        tokenPlaceholder.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        tokenPlaceholder.textColor = .placeholderText
        tokenPlaceholder.translatesAutoresizingMaskIntoConstraints = false

        let tokenIcon = fieldIcon("key.horizontal.fill")
        tokenIcon.translatesAutoresizingMaskIntoConstraints = false

        tokenBlock.addSubview(tokenIcon)
        tokenBlock.addSubview(tokenView)
        tokenBlock.addSubview(tokenPlaceholder)
        NSLayoutConstraint.activate([
            tokenIcon.leadingAnchor.constraint(equalTo: tokenBlock.leadingAnchor, constant: 4),
            tokenIcon.topAnchor.constraint(equalTo: tokenBlock.topAnchor, constant: 16),
            tokenView.leadingAnchor.constraint(equalTo: tokenIcon.trailingAnchor, constant: 2),
            tokenView.trailingAnchor.constraint(equalTo: tokenBlock.trailingAnchor),
            tokenView.topAnchor.constraint(equalTo: tokenBlock.topAnchor),
            tokenView.bottomAnchor.constraint(equalTo: tokenBlock.bottomAnchor),
            tokenPlaceholder.leadingAnchor.constraint(equalTo: tokenView.leadingAnchor, constant: 14),
            tokenPlaceholder.topAnchor.constraint(equalTo: tokenView.topAnchor, constant: 14)
        ])

        let body = UIStackView(arrangedSubviews: [phoneBlock, tokenBlock])
        body.axis = .vertical
        body.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12)
        ])
    }

    private func wrap(_ view: UIView) -> UIView {
        let box = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 54),
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            view.centerYAnchor.constraint(equalTo: box.centerYAnchor)
        ])
        return box
    }

    private func fieldIcon(_ name: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: name))
        image.tintColor = .tertiaryLabel
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.addSubview(image)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 36),
            box.heightAnchor.constraint(equalToConstant: 24),
            image.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18)
        ])
        return box
    }

    private func buildSubmit() {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .continuous
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        config.title = "登录"
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 17, weight: .semibold)
            return out
        }
        submit.configuration = config
        submit.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)

        spinner.hidesWhenStopped = true
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        submit.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: submit.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: submit.centerYAnchor)
        ])

        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
    }

    // MARK: - Mode / state

    @objc private func pickPhone() {
        mode = .phone
        tokenView.resignFirstResponder()
        phoneField.becomeFirstResponder()
    }

    @objc private func pickToken() {
        mode = .token
        phoneField.resignFirstResponder()
        codeField.resignFirstResponder()
        tokenView.becomeFirstResponder()
    }

    private func applyMode() {
        let phoneOn = mode == .phone
        phoneBlock.isHidden = !phoneOn
        tokenBlock.isHidden = phoneOn
        paintTab(phoneTab, on: phoneOn)
        paintTab(tokenTab, on: !phoneOn)
        refreshSubmit()
        showError(nil)
    }

    private func paintTab(_ button: UIButton, on: Bool) {
        button.backgroundColor = on ? surface : .clear
        button.setTitleColor(on ? .label : .secondaryLabel, for: .normal)
        button.layer.shadowOpacity = on ? 0.08 : 0
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowColor = UIColor.black.cgColor
    }

    @objc private func fieldsChanged() {
        refreshSubmit()
        refreshCodeButton()
        showError(nil)
    }

    func textViewDidChange(_ textView: UITextView) {
        tokenPlaceholder.isHidden = !textView.text.isEmpty
        refreshSubmit()
        showError(nil)
    }

    private var phoneValid: Bool {
        let phone = phoneField.text ?? ""
        return phone.count == 11 && phone.hasPrefix("1")
    }

    private func refreshSubmit() {
        let ok: Bool
        switch mode {
        case .phone:
            ok = phoneValid && (codeField.text ?? "").count >= 4 && !submitting
        case .token:
            ok = tokenView.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 && !submitting
        }
        submit.isEnabled = ok
        submit.alpha = ok ? 1 : 0.4
        var config = submit.configuration
        config?.title = submitting ? "" : (mode == .phone ? "登录" : "用 Token 进入")
        submit.configuration = config
        if submitting { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func refreshCodeButton() {
        let idle = countdown == 0 && !sending
        let can = phoneValid && idle
        codeButton.isEnabled = can
        if countdown > 0 {
            codeButton.setTitle("\(countdown)s", for: .normal)
        } else {
            codeButton.setTitle(sending ? "发送中" : "获取验证码", for: .normal)
        }
        codeButton.setTitleColor(can ? .systemBlue : .tertiaryLabel, for: .normal)
        codeButton.backgroundColor = can
            ? UIColor.systemBlue.withAlphaComponent(0.10)
            : track
    }

    private func showError(_ text: String?) {
        errorLabel.text = text
        errorLabel.isHidden = text == nil
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if textField === phoneField {
            let current = textField.text ?? ""
            let next = (current as NSString).replacingCharacters(in: range, with: string)
            return next.count <= 11 && next.allSatisfy(\.isNumber)
        }
        return true
    }

    // MARK: - Actions

    @objc private func sendCode() {
        guard phoneValid, countdown == 0, !sending else { return }
        sending = true
        refreshCodeButton()
        showError(nil)
        codeField.becomeFirstResponder()
        Task { @MainActor in
            do {
                try await model?.requestCode(phone: phoneField.text ?? "")
                startCountdown()
            } catch {
                showError(error.localizedDescription)
            }
            sending = false
            refreshCodeButton()
        }
    }

    private func startCountdown() {
        timer?.invalidate()
        countdown = 60
        refreshCodeButton()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.countdown -= 1
            if self.countdown <= 0 {
                self.countdown = 0
                timer.invalidate()
            }
            self.refreshCodeButton()
        }
    }

    @objc private func submitTapped() {
        guard !submitting else { return }
        submitting = true
        refreshSubmit()
        showError(nil)
        view.endEditing(true)
        Task { @MainActor in
            do {
                switch mode {
                case .phone:
                    try await model?.login(phone: phoneField.text ?? "", code: codeField.text ?? "")
                case .token:
                    try await model?.loginWithToken(tokenView.text)
                    tokenView.text = ""
                    tokenPlaceholder.isHidden = false
                }
            } catch {
                showError(error.localizedDescription)
            }
            submitting = false
            refreshSubmit()
        }
    }
}

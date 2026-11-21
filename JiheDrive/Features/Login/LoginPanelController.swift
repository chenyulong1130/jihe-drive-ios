import UIKit

/// 登录面板（原生 UIKit 实现）。
/// 键盘避让用 view.keyboardLayoutGuide：键盘弹起只压缩滚动区，卡片固定在顶部区域，页面不会被顶走。
@MainActor
final class LoginPanelController: UIViewController {

    // MARK: - 配色（与 Theme 保持一致，动态深浅色）

    private enum Palette {
        static var page: UIColor {
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.067, green: 0.094, blue: 0.145, alpha: 1)
                    : UIColor(red: 0.933, green: 0.945, blue: 0.961, alpha: 1)
            }
        }
        static var surface: UIColor {
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.110, green: 0.145, blue: 0.204, alpha: 1)
                    : .white
            }
        }
        static var alt: UIColor {
            UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.08)
                    : UIColor(red: 0.47, green: 0.52, blue: 0.59, alpha: 0.12)
            }
        }
    }

    private enum Mode {
        case phone, token
    }

    private let model: AppModel

    private var mode: Mode = .phone
    private var countdown = 0
    private var countdownTimer: Timer?
    private var sending = false
    private var submitting = false

    // MARK: - 控件

    private let card = UIView()
    private let phoneField = UITextField()
    private let codeField = UITextField()
    private let tokenView = UITextView()
    private let tokenPlaceholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let primaryButton = UIButton(type: .system)
    private let messageLabel = UILabel()
    private let phoneRow = UIView()
    private let codeRow = UIView()
    private let tokenRow = UIView()
    private var modeButtons: [UIButton] = []
    private let scrollView = UIScrollView()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.page
        buildLayout()
        refreshControls()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        card.layer.shadowPath = UIBezierPath(
            roundedRect: card.bounds,
            cornerRadius: 16
        ).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        card.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    // MARK: - 布局

    private func buildLayout() {
        // 遮罩
        let dim = UIView()
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        dim.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dim)

        // 滚动容器：底部贴键盘顶边
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)

        // 卡片
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = Palette.surface
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        card.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.45 : 0.06
        card.layer.shadowRadius = 28
        card.layer.shadowOffset = CGSize(width: 0, height: 10)
        scrollView.addSubview(card)

        NSLayoutConstraint.activate([
            dim.topAnchor.constraint(equalTo: view.topAnchor),
            dim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            card.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 110),
            card.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -40),
            card.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 26),
            card.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -26),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])

        let fillWidth = card.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -52)
        fillWidth.priority = .defaultHigh
        fillWidth.isActive = true

        let content = UIStackView()
        content.axis = .vertical
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        // 头部
        let iconBox = UIView()
        iconBox.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        iconBox.layer.cornerRadius = 14
        iconBox.layer.cornerCurve = .continuous
        iconBox.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: "bolt.car.fill"))
        iconView.tintColor = .systemBlue
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconView)

        let titleLabel = UILabel()
        titleLabel.text = "极核智行"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.text = "验证手机号，或粘贴 Token 进入"
        subtitleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center

        let header = UIStackView(arrangedSubviews: [iconBox, titleLabel, subtitleLabel])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 10

        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 48),
            iconBox.heightAnchor.constraint(equalToConstant: 48),
            iconView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])

        content.addArrangedSubview(header)
        content.setCustomSpacing(18, after: header)

        // 模式切换
        let modeBar = UIView()
        modeBar.backgroundColor = Palette.alt.withAlphaComponent(0.6)
        modeBar.layer.cornerRadius = 22
        modeBar.layer.cornerCurve = .continuous
        modeBar.translatesAutoresizingMaskIntoConstraints = false

        let modeStack = UIStackView()
        modeStack.axis = .horizontal
        modeStack.spacing = 4
        modeStack.distribution = .fillEqually
        modeStack.translatesAutoresizingMaskIntoConstraints = false
        modeBar.addSubview(modeStack)

        for (index, title) in ["手机号", "Token"].enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.layer.cornerRadius = 18
            button.layer.cornerCurve = .continuous
            button.tag = index
            button.addTarget(self, action: #selector(modeTapped(_:)), for: .touchUpInside)
            modeStack.addArrangedSubview(button)
            modeButtons.append(button)
        }

        NSLayoutConstraint.activate([
            modeBar.heightAnchor.constraint(equalToConstant: 44),
            modeStack.topAnchor.constraint(equalTo: modeBar.topAnchor, constant: 4),
            modeStack.leadingAnchor.constraint(equalTo: modeBar.leadingAnchor, constant: 4),
            modeStack.trailingAnchor.constraint(equalTo: modeBar.trailingAnchor, constant: -4),
            modeStack.bottomAnchor.constraint(equalTo: modeBar.bottomAnchor, constant: -4),
        ])

        content.addArrangedSubview(modeBar)
        content.setCustomSpacing(14, after: modeBar)

        // 手机号行
        buildRow(phoneRow, icon: "iphone", field: phoneField, trailing: nil, height: 48)
        content.addArrangedSubview(phoneRow)

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let separatorBox = UIView()
        separatorBox.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            separator.leadingAnchor.constraint(equalTo: separatorBox.leadingAnchor, constant: 4),
            separator.trailingAnchor.constraint(equalTo: separatorBox.trailingAnchor),
            separator.topAnchor.constraint(equalTo: separatorBox.topAnchor),
            separator.bottomAnchor.constraint(equalTo: separatorBox.bottomAnchor),
        ])
        content.addArrangedSubview(separatorBox)

        // 验证码行
        buildSendButton()
        buildRow(codeRow, icon: "lock.rotation", field: codeField, trailing: sendButton, height: 48)
        content.addArrangedSubview(codeRow)

        // Token 行
        buildTokenRow()
        content.addArrangedSubview(tokenRow)

        // 错误信息
        messageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.textColor = .systemRed
        messageLabel.numberOfLines = 0
        messageLabel.isHidden = true
        content.addArrangedSubview(messageLabel)
        content.setCustomSpacing(10, after: messageLabel)

        // 主按钮
        buildPrimaryButton()
        content.addArrangedSubview(primaryButton)
        content.setCustomSpacing(16, after: primaryButton)

        // 输入框配置
        for field in [phoneField, codeField] {
            field.font = .systemFont(ofSize: 16)
            field.keyboardType = .numberPad
            field.autocorrectionType = .no
            field.delegate = self
            field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        }
        codeField.textContentType = .oneTimeCode
        phoneField.textContentType = .telephoneNumber
        phoneField.placeholder = "手机号"
        codeField.placeholder = "短信验证码"

        refreshMode()
    }

    private func buildRow(_ container: UIView, icon: String, field: UITextField, trailing: UIButton?, height: CGFloat) {
        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = .tertiaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        field.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, field])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(trailing)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: height),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func buildSendButton() {
        sendButton.setTitle("获取验证码", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .bold)
        sendButton.layer.cornerRadius = 8
        sendButton.layer.cornerCurve = .continuous
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        sendButton.addTarget(self, action: #selector(sendCodeTapped), for: .touchUpInside)
    }

    private func buildTokenRow() {
        let iconView = UIImageView(image: UIImage(systemName: "key.horizontal.fill"))
        iconView.tintColor = .tertiaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        tokenView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tokenView.textColor = .label
        tokenView.backgroundColor = .clear
        tokenView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        tokenView.autocorrectionType = .no
        tokenView.autocapitalizationType = .none
        tokenView.delegate = self
        tokenView.translatesAutoresizingMaskIntoConstraints = false

        tokenPlaceholder.text = "粘贴 access token"
        tokenPlaceholder.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tokenPlaceholder.textColor = .placeholderText
        tokenPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        tokenRow.addSubview(tokenPlaceholder)

        let stack = UIStackView(arrangedSubviews: [iconView, tokenView])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        tokenRow.addSubview(stack)

        NSLayoutConstraint.activate([
            tokenRow.heightAnchor.constraint(equalToConstant: 92),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            stack.topAnchor.constraint(equalTo: tokenRow.topAnchor),
            stack.leadingAnchor.constraint(equalTo: tokenRow.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: tokenRow.trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: tokenRow.bottomAnchor),
            tokenView.heightAnchor.constraint(equalToConstant: 92),
            tokenPlaceholder.topAnchor.constraint(equalTo: tokenRow.topAnchor, constant: 8),
            tokenPlaceholder.leadingAnchor.constraint(equalTo: tokenRow.leadingAnchor, constant: 32),
        ])
    }

    private func buildPrimaryButton() {
        primaryButton.setTitle("登录", for: .normal)
        primaryButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        primaryButton.setTitleColor(.white, for: .normal)
        primaryButton.backgroundColor = .systemBlue
        primaryButton.layer.cornerRadius = 10
        primaryButton.layer.cornerCurve = .continuous
        primaryButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        primaryButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
    }

    // MARK: - 状态刷新

    private var phoneText: String { phoneField.text ?? "" }
    private var codeText: String { codeField.text ?? "" }
    private var tokenText: String { tokenView.text ?? "" }

    private var phoneValid: Bool { phoneText.count == 11 && phoneText.hasPrefix("1") }
    private var canSend: Bool { phoneValid && countdown == 0 && !sending }
    private var canSubmit: Bool {
        switch mode {
        case .phone: return phoneValid && codeText.count >= 4 && !submitting
        case .token: return tokenText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 && !submitting
        }
    }

    private func refreshControls() {
        sendButton.isEnabled = canSend
        sendButton.setTitleColor(canSend ? .systemBlue : .tertiaryLabel, for: .normal)
        sendButton.backgroundColor = canSend
            ? UIColor.systemBlue.withAlphaComponent(0.10)
            : Palette.alt

        primaryButton.isEnabled = canSubmit
        primaryButton.alpha = canSubmit ? 1 : 0.4
        primaryButton.setTitle(
            submitting ? "登录中" : (mode == .phone ? "登录" : "用 Token 进入"),
            for: .normal
        )

        tokenPlaceholder.isHidden = !tokenText.isEmpty
    }

    private func refreshMode() {
        phoneRow.isHidden = mode == .token
        codeRow.isHidden = mode == .token
        tokenRow.isHidden = mode == .phone
        for button in modeButtons {
            let selected = (button.tag == 0 && mode == .phone) || (button.tag == 1 && mode == .token)
            button.setTitleColor(selected ? .label : .secondaryLabel, for: .normal)
            button.backgroundColor = selected ? Palette.alt : .clear
        }
        messageLabel.isHidden = true
        refreshControls()
    }

    private func showMessage(_ text: String) {
        messageLabel.text = text
        messageLabel.isHidden = false
    }

    // MARK: - 交互

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: card)
        if !card.bounds.contains(point) {
            view.endEditing(true)
        }
    }

    @objc private func modeTapped(_ sender: UIButton) {
        mode = sender.tag == 0 ? .phone : .token
        refreshMode()
    }

    @objc private func fieldChanged() {
        refreshControls()
    }

    @objc private func sendCodeTapped() {
        guard canSend else { return }
        sending = true
        refreshControls()
        Task {
            do {
                try await model.requestCode(phone: phoneText)
                startCountdown()
                codeField.becomeFirstResponder()
            } catch {
                showMessage(error.localizedDescription)
            }
            sending = false
            refreshControls()
        }
    }

    @objc private func submitTapped() {
        guard canSubmit else { return }
        view.endEditing(true)
        submitting = true
        messageLabel.isHidden = true
        refreshControls()
        Task {
            do {
                switch mode {
                case .phone:
                    try await model.login(phone: phoneText, code: codeText)
                case .token:
                    try await model.loginWithToken(tokenText)
                    tokenView.text = ""
                }
            } catch {
                showMessage(error.localizedDescription)
            }
            submitting = false
            refreshControls()
        }
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdown = 60
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if countdown > 0 {
                countdown -= 1
                sendButton.setTitle(countdown > 0 ? "\(countdown)s" : "获取验证码", for: .normal)
                refreshControls()
            } else {
                timer.invalidate()
                sendButton.setTitle("获取验证码", for: .normal)
            }
        }
    }

    deinit {
        countdownTimer?.invalidate()
    }
}

// MARK: - UITextFieldDelegate / UITextViewDelegate

extension LoginPanelController: UITextFieldDelegate, UITextViewDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        let limit = textField === phoneField ? 11 : 6
        let current = textField.text ?? ""
        let next = (current as NSString).replacingCharacters(in: range, with: string)
        return next.count <= limit && next.allSatisfy(\.isNumber)
    }

    func textViewDidChange(_ textView: UITextView) {
        refreshControls()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n" {
            view.endEditing(true)
            submitTapped()
            return false
        }
        return true
    }
}

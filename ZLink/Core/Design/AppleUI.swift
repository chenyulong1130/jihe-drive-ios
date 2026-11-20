import SwiftUI

// MARK: - 卡片

/// 分组卡片：secondarySystemGroupedBackground + 12 圆角 + 极淡扩散阴影
struct AppleCard<Content: View>: View {
    private let padding: EdgeInsets
    private let tint: Color?
    private let onTap: (() -> Void)?
    private let content: Content

    init(
        padding: CGFloat = 16,
        tint: Color? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
        self.tint = tint
        self.onTap = onTap
        self.content = content()
    }

    init(
        padding: EdgeInsets,
        tint: Color? = nil,
        onTap: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.tint = tint
        self.onTap = onTap
        self.content = content()
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { inner }
                    .buttonStyle(PressableStyle(scale: 0.99, brightness: 0))
            } else {
                inner
            }
        }
    }

    private var inner: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(tint ?? Theme.surface)
            )
            .shadow(color: Theme.cardShadow, radius: 24, x: 0, y: 4)
    }
}

// MARK: - 标题

struct LargeTitle<Trailing: View>: View {
    private let text: String
    private let subtitle: String?
    private let trailing: Trailing

    init(_ text: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(Theme.largeTitle)
                    .foregroundStyle(Theme.label)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

extension LargeTitle where Trailing == EmptyView {
    init(_ text: String, subtitle: String? = nil) {
        self.init(text, subtitle: subtitle) { EmptyView() }
    }
}

/// 分组标题：13pt 次要色，左缩进与卡片内文字对齐
struct SectionHeader: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}

// MARK: - 小件

struct HairLine: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

struct IconBadge: View {
    let icon: String
    var color: Color = Theme.brand
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(12, size * 0.28), style: .continuous)
                .fill(Theme.surfaceAlt)
            Image(systemName: icon)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var pulsing: Bool = false

    @State private var breathe = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .scaleEffect(pulsing && breathe ? 1.35 : 1)
                .animation(pulsing ? Motion.breathe : nil, value: breathe)

            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(color.opacity(0.12))
        )
        .onAppear { if pulsing { breathe = true } }
    }
}

// MARK: - 按钮

struct PrimaryButton: View {
    let label: String
    var icon: String?
    var color: Color = Theme.brand
    var filled: Bool = true
    var enabled: Bool = true
    var loading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(filled ? .white : color)
                } else {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text(label)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .foregroundStyle(filled ? Color.white : color)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                    .fill(filled ? color : Theme.surfaceAlt)
            )
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(PressableStyle(scale: 0.985, brightness: 0))
        .disabled(!enabled || loading)
    }
}

/// 头部圆形按钮：44×44 触控区 + 半透明材质
struct HeaderAction: View {
    let icon: String
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.label)
                .frame(width: Theme.tap, height: Theme.tap)
                .background(
                    Circle().fill(.ultraThinMaterial)
                )
        }
        .buttonStyle(PressableStyle(scale: 0.92, brightness: 0))
        .accessibilityLabel(label ?? icon)
    }
}

// MARK: - 提示

struct SoftBanner: View {
    let text: String
    var icon: String = "exclamationmark.triangle.fill"
    var tone: Color = Theme.orange

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(tone.opacity(0.10))
        )
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.label)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 6)
    }
}

// MARK: - 数据小件

/// 指标块：弱填充底 + 次要色标题 + 主标签数值，颜色只用于图标
struct MetricChip: View {
    let title: String
    let value: String
    var unit: String?
    var icon: String?
    var color: Color = Theme.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.buttonRadius, style: .continuous)
                .fill(Theme.surfaceAlt)
        )
    }
}

/// 主视觉上的玻璃标签
struct GlassTag: View {
    let text: String
    var icon: String?
    var tint: Color = Theme.label

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        )
    }
}

/// 环形进度
struct RingProgress: View {
    let progress: Double
    var color: Color = Theme.brand
    var track: Color = Color(uiColor: .tertiarySystemFill)
    var lineWidth: CGFloat = 8
    var size: CGFloat = 54

    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            Circle()
                .trim(from: 0, to: max(0.001, min(1, shown)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(Motion.gauge) { shown = max(0, min(1, progress)) }
        }
        .onChange(of: progress) { _, value in
            withAnimation(Motion.gauge) { shown = max(0, min(1, value)) }
        }
    }
}

/// 卡片内的标题行
struct CardTitle: View {
    let text: String
    var icon: String?
    var tint: Color = Theme.brand
    var trailing: String?

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(Theme.headline)
                .foregroundStyle(Theme.label)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}

// MARK: - 表单行 / 弹层

struct InfoRow: View {
    let title: String
    let value: String
    var valueColor: Color = Theme.label
    var mono: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct SheetHeader: View {
    let title: String
    var subtitle: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Theme.opaqueSeparator)
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.title2)
                        .foregroundStyle(Theme.label)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.surfaceAlt))
                }
                .buttonStyle(PressableStyle(scale: 0.9, brightness: 0))
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }
}

struct SheetShell<Content: View>: View {
    let title: String
    var subtitle: String?
    let onClose: () -> Void
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: subtitle, onClose: onClose)
            content
        }
        .background(Theme.groupedBackground.ignoresSafeArea())
    }
}

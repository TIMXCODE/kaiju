import SwiftUI
import KaijuKit

/// The one card shape used everywhere. Consistency here is most of what makes an
/// interface feel considered rather than assembled.
struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var padding: CGFloat?
    var tinted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding ?? theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .fill(Color.kaijuSurface)
                    .overlay {
                        if tinted {
                            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                                .fill(theme.subtleGradient)
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .strokeBorder(Color.kaijuSeparator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled control row. Keeps every settings page aligned without each one
/// re-inventing its own layout.
struct SettingRow<Control: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var detail: String?
    var systemImage: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.accent)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.vertical, theme.density == .compact ? 3 : 6)
    }
}

struct StatTile: View {
    @Environment(\.theme) private var theme
    var label: String
    var value: String
    var caption: String?
    var systemImage: String?
    var accent: Color?
    /// 0…1 fill shown as a thin bar under the value.
    var fill: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
            }
            .foregroundStyle(.tertiary)

            Text(value)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent ?? .primary)
                .contentTransition(.numericText())

            if let fill {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.kaijuSeparator.opacity(0.5))
                        Capsule()
                            .fill(accent ?? theme.accent)
                            .frame(width: max(2, proxy.size.width * min(1, max(0, fill))))
                    }
                }
                .frame(height: 3)
            }

            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryActionButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var title: String
    var systemImage: String
    var shortcut: String?
    var prominent = true
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(prominent ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(theme.gradient)
                                    : AnyShapeStyle(Color.kaijuSeparator.opacity(0.35)))
            }
            .foregroundStyle(prominent ? .white : .primary)
            .opacity(isEnabled ? (isHovering ? 0.92 : 1) : 0.45)
            .scaleEffect(isHovering && isEnabled ? 1.012 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(theme.animation(.easeOut(duration: 0.15))) { isHovering = hovering }
        }
    }
}

struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    var systemImage: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(theme.accent.opacity(0.55))
            VStack(spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

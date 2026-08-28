import SwiftUI
import KaijuKit

/// The small confirmation that appears when a clip lands, and the one place an
/// error shows up with its fix attached.
struct ToastOverlay: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        if let toast = app.toast {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: symbol(for: toast.kind))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint(for: toast.kind))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(toast.title)
                        .font(.system(size: 13, weight: .semibold))
                    if let detail = toast.detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let fix = toast.fix {
                        Text(fix)
                            .font(.system(size: 11))
                            .foregroundStyle(tint(for: toast.kind))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    app.dismissToast()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint(for: toast.kind).opacity(0.30), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            .padding(.top, 14)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(theme.animation(), value: app.toast)
        }
    }

    private func symbol(for kind: ToastMessage.Kind) -> String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private func tint(for kind: ToastMessage.Kind) -> Color {
        switch kind {
        case .success: return theme.accent
        case .warning: return .yellow
        case .failure: return .red
        }
    }
}

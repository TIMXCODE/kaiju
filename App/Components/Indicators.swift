import SwiftUI
import KaijuKit

/// The pulsing dot that says whether the buffer is live. Deliberately small and
/// deliberately everywhere — sidebar, menu bar, floating indicator — so the answer
/// to "is it recording?" is never more than a glance away.
struct BufferStatusDot: View {
    @Environment(\.theme) private var theme
    var state: ReplayEngineState
    var size: CGFloat = 8

    @State private var isPulsing = false

    private var color: Color {
        switch state {
        case .running:  return theme.accent
        case .starting, .stopping: return .yellow
        case .failed:   return .red
        case .idle:     return .secondary
        }
    }

    var body: some View {
        ZStack {
            if state.isRunning {
                Circle()
                    .fill(color.opacity(0.30))
                    .frame(width: size * 2.1, height: size * 2.1)
                    .scaleEffect(isPulsing ? 1.0 : 0.55)
                    .opacity(isPulsing ? 0 : 0.9)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size * 2.1, height: size * 2.1)
        .onAppear { startPulse() }
        .onChange(of: state) { _, _ in startPulse() }
    }

    private func startPulse() {
        isPulsing = false
        guard state.isRunning, theme.animationScale > 0 else { return }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
            isPulsing = true
        }
    }
}

/// A stereo level meter driven by real RMS and peak from the mixer.
struct AudioLevelMeter: View {
    @Environment(\.theme) private var theme
    var rms: Float
    var peak: Float
    var isActive: Bool
    var label: String?

    private func normalise(_ value: Float) -> Double {
        // Linear amplitude reads as almost nothing on a meter; dB is what the ear
        // and the eye both expect. −60 dB floor.
        guard value > 0.0001 else { return 0 }
        let db = 20 * log10(Double(value))
        return min(1, max(0, (db + 60) / 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.kaijuSeparator.opacity(0.45))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [theme.accent, theme.secondaryAccent, .orange, .red],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * normalise(rms))
                        .animation(theme.animation(.linear(duration: 0.06)), value: rms)
                    if peak > 0.001 {
                        Capsule()
                            .fill(.white.opacity(0.85))
                            .frame(width: 2)
                            .offset(x: max(0, proxy.size.width * normalise(peak) - 2))
                            .animation(theme.animation(.easeOut(duration: 0.12)), value: peak)
                    }
                }
            }
            .frame(height: 6)
            .opacity(isActive ? 1 : 0.35)
        }
    }
}

struct KeyCapView: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.kaijuSeparator.opacity(0.35))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.kaijuSeparator.opacity(0.6), lineWidth: 0.5)
            }
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

struct BadgeView: View {
    @Environment(\.theme) private var theme
    var text: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule().fill((tint ?? theme.accent).opacity(0.16))
        }
        .foregroundStyle(tint ?? theme.accent)
    }
}

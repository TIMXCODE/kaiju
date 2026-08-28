import SwiftUI
import KaijuKit

struct SidebarView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: ReplayEngine
    @EnvironmentObject private var library: ClipLibrary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            brand
            List(selection: Binding<AppSection?>(
                get: { app.section },
                set: { app.section = $0 ?? .home })) {

                Section {
                    ForEach(AppSection.primary) { row(for: $0) }
                }
                Section("Configure") {
                    ForEach(AppSection.configuration) { row(for: $0) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)
            BufferStatusCard()
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            KaijuMark()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Kaiju")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("Instant replay")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func row(for section: AppSection) -> some View {
        Label {
            HStack(spacing: 6) {
                Text(section.title)
                if section == .clips, !library.clips.isEmpty {
                    Spacer()
                    Text("\(library.clips.count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        } icon: {
            Image(systemName: section.symbol)
                .foregroundStyle(app.section == section ? theme.accent : .secondary)
        }
        .tag(section)
    }
}

/// The little always-there status block at the foot of the sidebar.
struct BufferStatusCard: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: ReplayEngine
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                BufferStatusDot(state: engine.state, size: 7)
                Text(engine.state.label)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if engine.isRunning {
                    Text(engine.bufferStatus.bufferedSeconds.durationLabel)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if engine.isRunning {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.kaijuSeparator.opacity(0.5))
                        Capsule()
                            .fill(theme.gradient)
                            .frame(width: max(3, proxy.size.width * engine.bufferStatus.fillFraction))
                    }
                }
                .frame(height: 4)
                .animation(theme.animation(.easeOut(duration: 0.3)),
                           value: engine.bufferStatus.bufferedSeconds)

                Text(engine.activeGame?.name ?? engine.sourceLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if case .failed(let error) = engine.state {
                Text(error.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("\(Int(settings.settings.replay.effectiveBufferSeconds))s buffer ready")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.kaijuSurface.opacity(0.85))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(engine.isRunning ? theme.accent.opacity(0.35)
                                               : Color.kaijuSeparator.opacity(0.5),
                              lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.section = .home }
    }
}

/// The three-necked mark, drawn in SwiftUI so it picks up the theme accent
/// wherever it appears.
struct KaijuMark: View {
    @Environment(\.theme) private var theme
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Path { path in
                    func neck(_ startX: CGFloat, _ controlX: CGFloat, _ tipX: CGFloat,
                              _ tipY: CGFloat, _ width: CGFloat) {
                        path.move(to: CGPoint(x: startX - width, y: h * 0.80))
                        path.addQuadCurve(to: CGPoint(x: tipX, y: tipY),
                                          control: CGPoint(x: controlX - width * 0.6, y: h * 0.46))
                        path.addQuadCurve(to: CGPoint(x: startX + width, y: h * 0.80),
                                          control: CGPoint(x: controlX + width * 0.9, y: h * 0.50))
                        path.closeSubpath()
                    }
                    neck(w * 0.34, w * 0.16, w * 0.19, h * 0.30, w * 0.055)
                    neck(w * 0.50, w * 0.50, w * 0.50, h * 0.13, w * 0.065)
                    neck(w * 0.66, w * 0.84, w * 0.81, h * 0.30, w * 0.055)
                    path.addRoundedRect(in: CGRect(x: w * 0.22, y: h * 0.76,
                                                   width: w * 0.56, height: h * 0.15),
                                        cornerSize: CGSize(width: w * 0.05, height: w * 0.05))
                }
                .fill(theme.gradient)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

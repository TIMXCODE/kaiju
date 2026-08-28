import SwiftUI
import AppKit
import KaijuKit

/// The menu-bar panel. Everything you need mid-game without leaving the game:
/// buffer state, what's being captured, and the two save actions.
struct MenuBarPanel: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: ReplayEngine
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: ClipLibrary
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            actions
            if let clip = library.clips.first {
                Divider()
                recent(clip)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 288)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                KaijuMark().frame(width: 18, height: 18)
                Text("Kaiju").font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                BufferStatusDot(state: engine.state, size: 7)
                Text(engine.state.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if engine.isRunning {
                HStack(spacing: 6) {
                    Text(engine.activeGame?.name ?? engine.sourceLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(engine.bufferStatus.bufferedSeconds.durationLabel)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.kaijuSeparator.opacity(0.5))
                        Capsule().fill(theme.gradient)
                            .frame(width: max(3, proxy.size.width * engine.bufferStatus.fillFraction))
                    }
                }
                .frame(height: 4)
            } else if case .failed(let error) = engine.state {
                Text(error.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                Text("Buffer is off. Start it before you want to clip something.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 7) {
            PrimaryActionButton(title: "Instant Replay",
                                systemImage: "bolt.fill",
                                shortcut: app.hotkeys.displayString(for: .instantReplay)) {
                Task { await engine.saveInstantReplay() }
            }
            .disabled(!engine.canSaveClip)

            PrimaryActionButton(title: "Capture Clip",
                                systemImage: "scissors",
                                shortcut: app.hotkeys.displayString(for: .captureClip),
                                prominent: false) {
                Task { await engine.saveCaptureClip() }
            }
            .disabled(!engine.canSaveClip)

            PrimaryActionButton(title: engine.isRunning ? "Stop Buffer" : "Start Buffer",
                                systemImage: engine.isRunning ? "stop.circle" : "record.circle",
                                shortcut: app.hotkeys.displayString(for: .toggleBuffer),
                                prominent: false) {
                Task { await engine.toggle() }
            }
            .disabled(engine.state.isBusy)
        }
    }

    private func recent(_ clip: Clip) -> some View {
        Button {
            app.openMainWindow(section: .clips)
            app.selectedClipIDs = [clip.id]
        } label: {
            HStack(spacing: 9) {
                ClipThumbnail(clip: clip)
                    .frame(width: 62, height: 35)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text("\(clip.durationLabel) · \(clip.relativeDateLabel)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Clips") { app.openMainWindow(section: .clips) }
            Button("Settings") { app.openMainWindow(section: .settings) }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
    }
}

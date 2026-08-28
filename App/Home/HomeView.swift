import SwiftUI
import KaijuKit

struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: ReplayEngine
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var performance: PerformanceMonitor
    @EnvironmentObject private var storage: StorageManager
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                statusHero
                quickActions
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)],
                          spacing: 14) {
                    settingsSummary
                    performancePanel
                }
                recentClips
            }
            .padding(theme.contentPadding)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: - Hero

    private var statusHero: some View {
        Card(tinted: engine.isRunning) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        BufferStatusDot(state: engine.state, size: 9)
                        Text(engine.state.label)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        if engine.isRunning {
                            BadgeView(text: engine.backend.displayName,
                                      systemImage: engine.backend == .memory ? "memorychip" : "internaldrive")
                        }
                    }

                    if engine.isRunning {
                        Text("Capturing \(engine.activeGame?.name ?? engine.sourceLabel)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Holding the last \(engine.bufferStatus.bufferedSeconds.durationLabel) of \(Int(settings.settings.replay.effectiveBufferSeconds))s. Hit \(app.hotkeys.displayString(for: .instantReplay)) and the moment is yours.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if case .failed(let error) = engine.state {
                        Text(error.failureReason ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let fix = error.recoverySuggestion {
                            Text(fix)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Nothing is being buffered. Start the buffer and Kaiju keeps the last \(Int(settings.settings.replay.effectiveBufferSeconds)) seconds ready at all times.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if engine.isRunning {
                        bufferBar
                    }
                }

                Spacer(minLength: 0)

                VStack(spacing: 8) {
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
                }
                .frame(width: 240)
            }
        }
    }

    private var bufferBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.kaijuSeparator.opacity(0.5))
                    Capsule().fill(theme.gradient)
                        .frame(width: max(4, proxy.size.width * engine.bufferStatus.fillFraction))
                }
            }
            .frame(height: 6)
            .animation(theme.animation(.easeOut(duration: 0.35)),
                       value: engine.bufferStatus.bufferedSeconds)

            HStack {
                Text("\(engine.bufferStatus.bufferedSeconds.durationLabel) buffered")
                Spacer()
                Text("\(Int(settings.settings.replay.effectiveBufferSeconds))s capacity")
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 14) {
            quickTile(title: engine.isRunning ? "Stop Buffer" : "Start Buffer",
                      systemImage: engine.isRunning ? "stop.circle.fill" : "record.circle",
                      shortcut: app.hotkeys.displayString(for: .toggleBuffer)) {
                Task { await engine.toggle() }
            }
            quickTile(title: "Open Clips",
                      systemImage: "square.grid.2x2",
                      shortcut: "\(library.clips.count) saved") {
                app.section = .clips
            }
            quickTile(title: "Games",
                      systemImage: "gamecontroller",
                      shortcut: "\(settings.settings.automation.selectedBundleIdentifiers.count) selected") {
                app.section = .games
            }
            quickTile(title: "Recording",
                      systemImage: "slider.horizontal.3",
                      shortcut: "\(settings.settings.recording.resolution.displayName) · \(settings.settings.recording.frameRate.rawValue)fps") {
                app.section = .recording
            }
        }
    }

    private func quickTile(title: String, systemImage: String, shortcut: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.accent)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings summary

    private var settingsSummary: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Current setup", systemImage: "slider.horizontal.3")

                summaryRow("Source", engine.isRunning ? engine.sourceLabel
                                                      : settings.settings.recording.source.displayName)
                summaryRow("Video", "\(settings.settings.recording.resolution.displayName) · \(settings.settings.recording.frameRate.rawValue) FPS · \(settings.settings.recording.codec.displayName)")
                summaryRow("Bitrate", performance.snapshot.configuredBitrate > 0
                           ? performance.snapshot.configuredBitrateLabel
                           : settings.settings.recording.bitratePreset.displayName)
                summaryRow("Audio", audioSummary)
                summaryRow("Replay", "\(Int(settings.settings.replay.instantReplaySeconds))s instant · \(Int(settings.settings.replay.captureClipSeconds))s clip · \(Int(settings.settings.replay.effectiveBufferSeconds))s buffer")
                summaryRow("Saving to", settings.settings.storage.saveDirectory.lastPathComponent)

                Button("Change recording settings") { app.section = .recording }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
    }

    private var audioSummary: String {
        let audio = settings.settings.audio
        var parts: [String] = []
        if audio.captureSystemAudio { parts.append("Game & desktop") }
        if audio.captureMicrophone { parts.append(audio.microphoneMuted ? "Mic (muted)" : "Mic") }
        if parts.isEmpty { return "Off" }
        if audio.separateTracks { parts.append("separate tracks") }
        return parts.joined(separator: " + ")
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Performance

    private var performancePanel: some View {
        PerformancePanel()
    }

    // MARK: - Recent clips

    private var recentClips: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Recent clips", systemImage: "clock")
                Spacer()
                Button("See all") { app.section = .clips }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }

            if library.clips.isEmpty {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 22))
                            .foregroundStyle(theme.accent.opacity(0.6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("No clips yet").font(.system(size: 13, weight: .semibold))
                            Text("Start the buffer, play something, and hit \(app.hotkeys.displayString(for: .instantReplay)) when something good happens.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                          spacing: 14) {
                    ForEach(Array(library.clips.prefix(6))) { clip in
                        ClipCard(clip: clip, isSelected: false)
                            .onTapGesture(count: 2) { app.edit(clip) }
                            .onTapGesture {
                                app.selectedClipIDs = [clip.id]
                                app.section = .clips
                            }
                    }
                }
            }
        }
    }
}

import SwiftUI
import KaijuKit

struct RecordingSettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var catalog: CaptureSourceCatalog
    @EnvironmentObject private var engine: ReplayEngine
    @Environment(\.theme) private var theme

    @State private var pendingRestart = false

    private var recording: RecordingConfiguration { settings.settings.recording }
    private var replay: ReplayConfiguration { settings.settings.replay }

    private var sourcePixelSize: CGSize {
        catalog.snapshot.mainDisplay?.pixelSize ?? CGSize(width: 3840, height: 2160)
    }

    private var encodeSize: CGSize {
        recording.resolution.encodeSize(forSource: sourcePixelSize)
    }

    private var projection: (bytes: Int, backend: ReplayBuffer.Backend) {
        ReplayBuffer.projectedMemoryUse(replay: replay,
                                        recording: recording,
                                        audio: settings.settings.audio,
                                        encodeSize: encodeSize)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                if pendingRestart && engine.isRunning { restartBanner }
                sourceCard
                videoCard
                replayCard
                advancedCard
            }
            .padding(theme.contentPadding)
        }
        .task { _ = await catalog.refresh() }
    }

    private var restartBanner: some View {
        Card(tinted: true) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("These settings need the buffer to restart")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Restarting clears whatever is currently buffered.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restart Buffer") {
                    Task {
                        await engine.applySettingsChange(requiresRestart: true)
                        pendingRestart = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Source

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Capture source", systemImage: "display")
                    Spacer()
                    Button {
                        Task { _ = await catalog.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(catalog.isRefreshing)
                }

                if let error = catalog.lastError {
                    ErrorNote(error: error)
                }

                Picker("", selection: sourceBinding) {
                    Text("Main Display").tag(CaptureSourceSelection.mainDisplay)
                    Text("Whatever game is running").tag(CaptureSourceSelection.activeGame)
                    if !catalog.snapshot.displays.isEmpty {
                        Divider()
                        ForEach(catalog.snapshot.displays) { display in
                            Text("\(display.name) — \(display.resolutionLabel)")
                                .tag(CaptureSourceSelection.display(id: display.id))
                        }
                    }
                    if !catalog.snapshot.applications.isEmpty {
                        Divider()
                        ForEach(catalog.snapshot.applications) { application in
                            Text(application.name)
                                .tag(CaptureSourceSelection.application(
                                    bundleID: application.bundleIdentifier,
                                    name: application.name))
                        }
                    }
                    if !catalog.snapshot.windows.isEmpty {
                        Divider()
                        ForEach(catalog.snapshot.windows.prefix(40)) { window in
                            Text("\(window.ownerName) — \(window.displayTitle)")
                                .tag(CaptureSourceSelection.window(id: window.id,
                                                                   title: window.title,
                                                                   owner: window.ownerName))
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Text(sourceHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show the cursor", isOn: $settings.settings.recording.showsCursor)
                    .toggleStyle(.switch)
                Toggle("Keep Kaiju's own windows out of the recording",
                       isOn: $settings.settings.recording.excludeKaijuFromCapture)
                    .toggleStyle(.switch)
            }
        }
    }

    private var sourceBinding: Binding<CaptureSourceSelection> {
        Binding(
            get: { settings.settings.recording.source },
            set: { value in
                settings.settings.recording.source = value
                pendingRestart = true
            })
    }

    private var sourceHint: String {
        switch recording.source {
        case .mainDisplay, .display:
            return "Captures the whole display, including anything running full screen."
        case .activeGame:
            return "Follows whichever selected game is running. Falls back to your main display when none is."
        case .application:
            return "Captures only that app's windows. Overlays from other apps won't appear in your clips."
        case .window:
            return "Captures one window. If it closes, Kaiju tells you rather than silently recording nothing."
        }
    }

    // MARK: - Video

    private var videoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Video", systemImage: "film")

                SettingRow(title: "Resolution",
                           detail: "Encoding at \(Int(encodeSize.width))×\(Int(encodeSize.height)) from a \(Int(sourcePixelSize.width))×\(Int(sourcePixelSize.height)) source.",
                           systemImage: "rectangle.on.rectangle") {
                    Picker("", selection: restarting(\.recording.resolution)) {
                        ForEach(ResolutionPreset.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Frame rate",
                           detail: frameRateHint,
                           systemImage: "speedometer") {
                    Picker("", selection: restarting(\.recording.frameRate)) {
                        ForEach(FrameRateOption.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Codec",
                           detail: recording.codec.subtitle,
                           systemImage: "square.stack.3d.down.right") {
                    Picker("", selection: restarting(\.recording.codec)) {
                        ForEach(VideoCodecOption.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Quality",
                           detail: "About \(bitrateLabel) at the current resolution and frame rate.",
                           systemImage: "dial.high") {
                    Picker("", selection: $settings.settings.recording.bitratePreset) {
                        ForEach(BitratePreset.allCases.filter { $0 != .custom }) {
                            Text($0.displayName).tag($0)
                        }
                        Text("Custom").tag(BitratePreset.custom)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                if recording.bitratePreset == .custom {
                    HStack {
                        Slider(value: $settings.settings.recording.customBitrateMbps, in: 2...150)
                        Text("\(Int(recording.customBitrateMbps)) Mbps")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                    }
                    .padding(.leading, 34)
                }

                if engine.isRunning {
                    Divider().padding(.vertical, 4)
                    Text("Quality changes apply immediately. Resolution, frame rate and codec need a buffer restart.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var frameRateHint: String {
        switch recording.frameRate {
        case .fps30:  return "Easiest on the machine. Fine for slower games."
        case .fps60:  return "The sweet spot on Apple Silicon, including at 4K on M-series Pro and up."
        case .fps120: return "Only worth it if your display and game actually run there — and it doubles the bitrate."
        }
    }

    private var bitrateLabel: String {
        let bps = recording.bitrate(width: Int(encodeSize.width), height: Int(encodeSize.height))
        return String(format: "%.0f Mbps", Double(bps) / 1_000_000)
    }

    // MARK: - Replay

    private var replayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Replay buffer",
                              subtitle: "How much history Kaiju keeps, and how much of it each hotkey saves.",
                              systemImage: "clock.arrow.circlepath")

                SettingRow(title: "Buffer length",
                           detail: "Kaiju holds this much of the past at all times.",
                           systemImage: "clock") {
                    Picker("", selection: restarting(\.replay.bufferSeconds)) {
                        ForEach(ReplayConfiguration.selectableDurations, id: \.self) {
                            Text($0.durationLabel).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Instant Replay length",
                           detail: "Saved by \(app.hotkeys.displayString(for: .instantReplay)).",
                           systemImage: "bolt.fill") {
                    Picker("", selection: $settings.settings.replay.instantReplaySeconds) {
                        ForEach(ReplayConfiguration.selectableDurations.filter { $0 <= 300 }, id: \.self) {
                            Text($0.durationLabel).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Capture Clip length",
                           detail: "Saved by \(app.hotkeys.displayString(for: .captureClip)).",
                           systemImage: "scissors") {
                    Picker("", selection: $settings.settings.replay.captureClipSeconds) {
                        ForEach(ReplayConfiguration.selectableDurations, id: \.self) {
                            Text($0.durationLabel).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Divider().padding(.vertical, 4)

                projectionRow
            }
        }
    }

    private var projectionRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: projection.backend == .memory ? "memorychip" : "internaldrive")
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(projection.backend == .memory
                     ? "About \(Int64(projection.bytes).fileSizeString) of RAM"
                     : "About \(Int64(projection.bytes).fileSizeString) of scratch disk")
                    .font(.system(size: 12, weight: .semibold))
                Text(projection.backend == .memory
                     ? "Held in a fixed-size ring that never grows. No disk writes until you save a clip."
                     : "Too big for memory at these settings, so Kaiju rotates short segment files instead. Old ones are deleted as they age out.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Advanced", systemImage: "wrench.and.screwdriver")

                SettingRow(title: "Hardware encoding only",
                           detail: "Apple Silicon has dedicated H.264 and HEVC encoders. Turning this off allows a software fallback, which will cost you frames in-game.",
                           systemImage: "cpu") {
                    Toggle("", isOn: restarting(\.recording.requireHardwareEncoder))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingRow(title: "Keyframe interval",
                           detail: "How precisely a clip can start. Clips are cut without re-encoding, so they begin at the nearest keyframe at or before the point you asked for.",
                           systemImage: "key") {
                    Picker("", selection: restarting(\.recording.keyframeIntervalSeconds)) {
                        Text("0.5s").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("4s").tag(4.0)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                SettingRow(title: "Memory budget",
                           detail: "The ceiling on RAM the in-memory buffer may use before Kaiju switches to disk segments.",
                           systemImage: "memorychip") {
                    Picker("", selection: restarting(\.replay.memoryBudgetMB)) {
                        Text("256 MB").tag(256)
                        Text("512 MB").tag(512)
                        Text("768 MB").tag(768)
                        Text("1.5 GB").tag(1536)
                        Text("3 GB").tag(3072)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                SettingRow(title: "Start the buffer at launch",
                           detail: "Otherwise Kaiju waits for you, or for a selected game to start.",
                           systemImage: "power") {
                    Toggle("", isOn: $settings.settings.replay.startBufferOnLaunch)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    /// Wraps a settings key path so changing it flags that the buffer needs a
    /// restart, rather than silently doing nothing until the next session.
    private func restarting<Value>(_ keyPath: WritableKeyPath<KaijuSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings.settings[keyPath: keyPath] },
            set: { value in
                settings.settings[keyPath: keyPath] = value
                if engine.isRunning { pendingRestart = true }
            })
    }
}

struct ErrorNote: View {
    @Environment(\.theme) private var theme
    var error: KaijuError

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.system(size: 12, weight: .semibold))
                if let reason = error.failureReason {
                    Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let fix = error.recoverySuggestion {
                    Text(fix).font(.system(size: 11)).foregroundStyle(theme.accent)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.10)))
    }
}

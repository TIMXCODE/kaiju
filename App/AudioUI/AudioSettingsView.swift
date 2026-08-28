import SwiftUI
import KaijuKit

struct AudioSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: ReplayEngine
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var microphones: MicrophoneCatalog
    @Environment(\.theme) private var theme

    private var audio: AudioConfiguration { settings.settings.audio }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                if audio.captureMicrophone && permissions.microphone != .granted {
                    micPermissionCard
                }
                levelsCard
                sourcesCard
                trackCard
            }
            .padding(theme.contentPadding)
        }
        .onChange(of: settings.settings.audio) { _, _ in
            Task { await engine.applySettingsChange(requiresRestart: false) }
        }
        .task { microphones.refresh() }
    }

    private var micPermissionCard: some View {
        Card(tinted: true) {
            HStack(spacing: 11) {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Microphone access is off")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Mic capture is enabled here but macOS hasn't granted it, so your voice won't be in clips.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Grant Access") {
                    Task { await permissions.requestMicrophone() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var levelsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Levels", systemImage: "waveform")
                    Spacer()
                    if !engine.isRunning {
                        Text("Start the buffer to see live levels")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                AudioLevelMeter(rms: engine.audioLevels.systemRMS,
                                peak: engine.audioLevels.systemPeak,
                                isActive: engine.audioLevels.systemActive,
                                label: "Game & desktop")

                AudioLevelMeter(rms: engine.audioLevels.microphoneRMS,
                                peak: engine.audioLevels.microphonePeak,
                                isActive: engine.audioLevels.microphoneActive,
                                label: "Microphone")
            }
        }
    }

    private var sourcesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Sources", systemImage: "speaker.wave.2")

                SettingRow(title: "Game & desktop audio",
                           detail: "Everything you hear, minus Kaiju's own sounds. Comes through the same permission as screen recording.",
                           systemImage: "speaker.wave.2.fill") {
                    Toggle("", isOn: $settings.settings.audio.captureSystemAudio)
                        .toggleStyle(.switch).labelsHidden()
                }

                if audio.captureSystemAudio {
                    gainRow(title: "Game volume",
                            value: $settings.settings.audio.systemGain,
                            muted: $settings.settings.audio.systemMuted)
                }

                Divider().padding(.vertical, 6)

                SettingRow(title: "Microphone",
                           detail: "Off by default. Kaiju doesn't open an input device unless you turn this on.",
                           systemImage: "mic.fill") {
                    Toggle("", isOn: $settings.settings.audio.captureMicrophone)
                        .toggleStyle(.switch).labelsHidden()
                }

                if audio.captureMicrophone {
                    SettingRow(title: "Input device",
                               detail: microphones.isSelectionMissing(audio.microphoneDeviceID)
                                   ? "The device you picked isn't connected. Falling back to the system default."
                                   : nil,
                               systemImage: "waveform.badge.mic") {
                        Picker("", selection: Binding(
                            get: { settings.settings.audio.microphoneDeviceID ?? "" },
                            set: { settings.settings.audio.microphoneDeviceID = $0.isEmpty ? nil : $0 })) {
                            Text("System default").tag("")
                            ForEach(microphones.devices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    gainRow(title: "Mic volume",
                            value: $settings.settings.audio.microphoneGain,
                            muted: $settings.settings.audio.microphoneMuted)

                    SettingRow(title: "Hear yourself",
                               detail: "Plays your mic back through your output. Use headphones — speakers will feed back.",
                               systemImage: "headphones") {
                        Toggle("", isOn: $settings.settings.audio.monitorMicrophone)
                            .toggleStyle(.switch).labelsHidden()
                    }

                    if audio.monitorMicrophone {
                        HStack {
                            Text("Monitor volume").font(.system(size: 11)).foregroundStyle(.tertiary)
                            Slider(value: Binding(
                                get: { Double(settings.settings.audio.monitorVolume) },
                                set: { settings.settings.audio.monitorVolume = Float($0) }), in: 0...1)
                            Text("\(Int(audio.monitorVolume * 100))%")
                                .font(.system(size: 11)).monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        .padding(.leading, 34)
                    }
                }
            }
        }
    }

    private func gainRow(title: String, value: Binding<Float>, muted: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Button {
                muted.wrappedValue.toggle()
            } label: {
                Image(systemName: muted.wrappedValue ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(muted.wrappedValue ? .orange : theme.accent)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            Text(title).font(.system(size: 12))

            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Float($0) }), in: 0...2)
                .disabled(muted.wrappedValue)

            Text("\(Int(value.wrappedValue * 100))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(muted.wrappedValue ? .tertiary : .secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.leading, 14)
        .padding(.vertical, 4)
    }

    private var trackCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Tracks & quality", systemImage: "square.stack")

                SettingRow(title: "Separate audio tracks",
                           detail: "Writes game audio and mic as two tracks instead of one mix, so you can rebalance them later in an editor. Some players and upload services only play the first track.",
                           systemImage: "square.stack.3d.up") {
                    Toggle("", isOn: $settings.settings.audio.separateTracks)
                        .toggleStyle(.switch).labelsHidden()
                }

                SettingRow(title: "Audio bitrate",
                           detail: "AAC, applied when a clip is written. The buffer itself holds uncompressed audio, so this can change without restarting anything.",
                           systemImage: "dial.medium") {
                    Picker("", selection: $settings.settings.audio.audioBitrate) {
                        Text("128 kbps").tag(128_000)
                        Text("192 kbps").tag(192_000)
                        Text("256 kbps").tag(256_000)
                        Text("320 kbps").tag(320_000)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Sample rate",
                           detail: "48 kHz matches what macOS mixes at. Changing it means resampling for no benefit.",
                           systemImage: "metronome") {
                    Text("48 kHz").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

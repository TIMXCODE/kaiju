import SwiftUI
import AppKit
import KaijuKit

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @EnvironmentObject private var exports: ExportManager
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL?
    @State private var addToLibrary = true
    @State private var startedJobID: UUID?

    private var job: ExportJob? {
        guard let startedJobID else { return nil }
        return exports.jobs.first { $0.id == startedJobID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let job {
                progressView(job)
            } else {
                options
            }
            Divider()
            footer
        }
        .frame(width: 460)
        .background(Color.kaijuCanvas)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Export clip").font(.system(size: 14, weight: .semibold))
                Text(model.clip?.title ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Match the source clip", isOn: $model.exportSettings.matchSource)
                .toggleStyle(.switch)

            if !model.exportSettings.matchSource {
                SettingRow(title: "Resolution") {
                    Picker("", selection: $model.exportSettings.resolution) {
                        ForEach(ResolutionPreset.allCases.filter { $0 != .native }) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                SettingRow(title: "Frame rate") {
                    Picker("", selection: $model.exportSettings.frameRate) {
                        ForEach(FrameRateOption.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            SettingRow(title: "Codec",
                       detail: model.exportSettings.codec.subtitle) {
                Picker("", selection: $model.exportSettings.codec) {
                    ForEach(VideoCodecOption.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            SettingRow(title: "Quality") {
                Picker("", selection: $model.exportSettings.bitratePreset) {
                    ForEach(BitratePreset.allCases.filter { $0 != .custom }) {
                        Text($0.displayName).tag($0)
                    }
                    Text("Custom").tag(BitratePreset.custom)
                }
                .labelsHidden()
                .frame(width: 130)
            }

            if model.exportSettings.bitratePreset == .custom {
                HStack {
                    Slider(value: $model.exportSettings.customBitrateMbps, in: 2...120)
                    Text("\(Int(model.exportSettings.customBitrateMbps)) Mbps")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }

            Divider()

            SettingRow(title: "Save to",
                       detail: (destination ?? defaultDestination)?.deletingLastPathComponent().path) {
                Button("Choose…") { chooseDestination() }
                    .controlSize(.small)
            }

            Toggle("Add to my clip library", isOn: $addToLibrary)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            summary
        }
        .padding(16)
    }

    private var summary: some View {
        HStack(spacing: 14) {
            summaryItem("Length", model.outputDurationLabel)
            if model.plan.hasCuts { summaryItem("Cuts", "\(model.plan.cuts.count)") }
            if !model.plan.textOverlays.isEmpty {
                summaryItem("Text", "\(model.plan.textOverlays.count)")
            }
            if model.plan.cropRect != nil { summaryItem("Crop", "on") }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func summaryItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(value).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }

    private func progressView(_ job: ExportJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(job.state.label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(job.progressPercent)%")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.accent)
            }
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(theme.accent)

            if case .failed(let error) = job.state {
                VStack(alignment: .leading, spacing: 3) {
                    Text(error.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.red)
                    if let reason = error.failureReason {
                        Text(reason).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let fix = error.recoverySuggestion {
                        Text(fix).font(.system(size: 11)).foregroundStyle(theme.accent)
                    }
                }
            } else if job.state == .finished {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                    Text("Saved to \(job.outputURL.lastPathComponent)")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            } else {
                Text("The UI stays responsive — you can keep clipping while this runs.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            if let job, job.state.isActive {
                Button("Cancel Export", role: .destructive) { exports.cancel(job.id) }
            } else if job != nil {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.sourceURL == nil)
            }
        }
        .padding(16)
    }

    private var defaultDestination: URL? {
        guard let clip = model.clip else { return nil }
        let directory = addToLibrary ? library.directory : settings.settings.storage.saveDirectory
        return ExportManager.defaultOutputURL(for: clip.title, in: directory)
    }

    private func chooseDestination() {
        guard let suggestion = destination ?? defaultDestination else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestion.lastPathComponent
        panel.directoryURL = suggestion.deletingLastPathComponent()
        panel.allowedContentTypes = [.mpeg4Movie]
        if panel.runModal() == .OK { destination = panel.url }
    }

    private func start() {
        guard let sourceURL = model.sourceURL, let clip = model.clip else { return }
        let output = destination ?? defaultDestination
            ?? library.directory.appendingPathComponent("\(clip.title) (edited).mp4")
        startedJobID = exports.export(sourceURL: sourceURL,
                                      outputURL: output,
                                      title: "\(clip.title) (edited)",
                                      plan: model.plan,
                                      settings: model.exportSettings,
                                      sourceClipID: clip.id,
                                      addToLibrary: addToLibrary)
    }
}

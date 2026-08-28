import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KaijuKit

struct EditorView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var exports: ExportManager
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.theme) private var theme

    @StateObject private var model = EditorModel()
    @StateObject private var player = PlayerModel()

    @State private var cutAnchor: TimeInterval?

    var body: some View {
        Group {
            if let clip = app.editingClip {
                editor(for: clip)
            } else if let recent = library.clips.first {
                EmptyStateView(systemImage: "scissors",
                               title: "Pick a clip to edit",
                               message: "Open Clips and double-click one, or start with your most recent.",
                               actionTitle: "Edit \(recent.title)") { app.edit(recent) }
            } else {
                EmptyStateView(systemImage: "scissors",
                               title: "Nothing to edit yet",
                               message: "Save a clip first and it'll show up here.",
                               actionTitle: "Go to Home") { app.section = .home }
            }
        }
        .sheet(isPresented: $model.isShowingExportSheet) {
            ExportSheet(model: model)
                .environment(\.theme, theme)
        }
    }

    private func editor(for clip: Clip) -> some View {
        HSplitView {
            VStack(spacing: 0) {
                preview(for: clip)
                Divider()
                timelineSection(for: clip)
            }
            .frame(minWidth: 520)

            EditorInspector(model: model, player: player)
                .frame(minWidth: 268, idealWidth: 300, maxWidth: 380)
        }
        .task(id: clip.id) {
            model.load(clip: clip, directory: library.directory)
            player.load(url: clip.url(in: library.directory))
        }
        .onChange(of: model.plan.trimStart) { _, _ in syncPlaybackRange() }
        .onChange(of: model.plan.trimEnd) { _, _ in syncPlaybackRange() }
    }

    private func syncPlaybackRange() {
        player.playbackRange = model.plan.trimStart...max(model.plan.trimStart + 0.1, model.plan.trimEnd)
    }

    private func preview(for clip: Clip) -> some View {
        VStack(spacing: 0) {
            KaijuVideoPlayer(url: clip.url(in: library.directory), compact: true)
                .aspectRatio(CGFloat(clip.width) / CGFloat(max(1, clip.height)), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            header(for: clip)
        }
    }

    private func header(for clip: Clip) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(clip.resolutionLabel) · \(clip.frameRateLabel) · source \(clip.durationLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("Output \(model.outputDurationLabel)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.accent)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo")
            Button("Reset") { model.reset() }
            Button {
                model.isShowingExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func timelineSection(for clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ClipTimelineView(model: model, player: player, duration: clip.duration)

            HStack(spacing: 8) {
                Button {
                    model.trimStart(to: player.currentTime)
                } label: {
                    Label("Trim Start", systemImage: "arrow.right.to.line")
                }
                Button {
                    model.trimEnd(to: player.currentTime)
                } label: {
                    Label("Trim End", systemImage: "arrow.left.to.line")
                }

                Divider().frame(height: 16)

                Button {
                    if let anchor = cutAnchor {
                        model.addCut(from: min(anchor, player.currentTime),
                                     to: max(anchor, player.currentTime))
                        cutAnchor = nil
                    } else {
                        cutAnchor = player.currentTime
                    }
                } label: {
                    Label(cutAnchor == nil ? "Start Cut" : "End Cut",
                          systemImage: cutAnchor == nil ? "scissors" : "scissors.badge.ellipsis")
                }
                .tint(cutAnchor == nil ? nil : theme.accent)

                if let anchor = cutAnchor {
                    Text("cutting from \(anchor.preciseTimestampString)")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent)
                    Button("Cancel") { cutAnchor = nil }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                }

                Divider().frame(height: 16)

                Button {
                    model.addTextOverlay(at: player.currentTime)
                } label: {
                    Label("Text", systemImage: "textformat")
                }
                Button {
                    pickImageOverlay()
                } label: {
                    Label("Image", systemImage: "photo")
                }
                Button {
                    model.addZoom(at: player.currentTime)
                } label: {
                    Label("Zoom", systemImage: "plus.magnifyingglass")
                }

                Spacer()

                Text(player.currentTime.preciseTimestampString)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(14)
    }

    private func pickImageOverlay() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to overlay"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addImageOverlay(url: url, at: player.currentTime)
    }
}

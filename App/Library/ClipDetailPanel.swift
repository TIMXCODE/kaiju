import SwiftUI
import AppKit
import KaijuKit

struct ClipDetailPanel: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var share: ShareManager
    @Environment(\.theme) private var theme
    var clip: Clip

    @State private var isMissing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                KaijuVideoPlayer(url: clip.url(in: library.directory))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(clip.absoluteDateLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                if isMissing {
                    Label("This file is missing from disk.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                actionRow

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 9) {
                        detailRow("Duration", clip.durationLabel)
                        detailRow("Resolution", clip.resolutionLabel)
                        detailRow("Frame rate", clip.frameRateLabel)
                        detailRow("Codec", clip.codec)
                        detailRow("Size", clip.sizeLabel)
                        detailRow("Audio", clip.audioTrackCount == 0 ? "None"
                                  : "\(clip.audioTrackCount) track\(clip.audioTrackCount == 1 ? "" : "s")")
                        detailRow("Source", clip.kind.displayName)
                        if let game = clip.gameName { detailRow("Game", game) }
                        detailRow("File", clip.fileName)
                    }
                }

                if !share.uploads(for: clip.id).isEmpty {
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "Shared links", systemImage: "link")
                            ForEach(share.uploads(for: clip.id)) { record in
                                HStack {
                                    Text(record.shareURL.absoluteString)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("Copy") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(record.shareURL.absoluteString,
                                                                       forType: .string)
                                    }
                                    .buttonStyle(.link)
                                    .font(.system(size: 11))
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .task(id: clip.id) { isMissing = !library.exists(clip) }
    }

    private var actionRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    app.edit(clip)
                } label: {
                    Label("Edit", systemImage: "scissors").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    library.toggleFavorite(clip)
                } label: {
                    Label(clip.isFavorite ? "Favourited" : "Favourite",
                          systemImage: clip.isFavorite ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 8) {
                ShareButton(urls: [clip.url(in: library.directory)])
                Button {
                    library.reveal(clip)
                } label: {
                    Label("Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    library.delete([clip])
                    app.selectedClipIDs.remove(clip.id)
                } label: {
                    Label("Delete", systemImage: "trash").frame(maxWidth: .infinity)
                }
            }
        }
        .controlSize(.regular)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Wraps `NSSharingServicePicker` so Share hands the clip to whatever the user
/// already has — Messages, Mail, AirDrop, any installed share extension — instead
/// of Kaiju pretending to integrate with services it doesn't.
struct ShareButton: NSViewRepresentable {
    var urls: [URL]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share", target: context.coordinator,
                              action: #selector(Coordinator.share(_:)))
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.urls = urls
    }

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    final class Coordinator: NSObject {
        var urls: [URL]
        init(urls: [URL]) { self.urls = urls }

        @objc func share(_ sender: NSButton) {
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { NSSound.beep(); return }
            let picker = NSSharingServicePicker(items: existing)
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

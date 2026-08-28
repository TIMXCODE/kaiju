import SwiftUI
import AppKit
import KaijuKit

struct StorageView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var storage: StorageManager
    @Environment(\.theme) private var theme

    @State private var confirmCleanup = false

    private var report: StorageReport { storage.report }
    private var configuration: StorageConfiguration { settings.settings.storage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                overviewCard
                locationCard
                cleanupCard
                largestCard
            }
            .padding(theme.contentPadding)
        }
        .task { storage.refresh(library: library, configuration: configuration) }
        .onChange(of: library.clips.count) { _, _ in
            storage.refresh(library: library, configuration: configuration)
        }
        .onChange(of: settings.settings.storage) { _, _ in
            storage.refresh(library: library, configuration: configuration)
        }
        .confirmationDialog("Move \(report.wouldCleanupCount) clip\(report.wouldCleanupCount == 1 ? "" : "s") to the Trash?",
                            isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                let removed = storage.cleanupCandidates(library: library, configuration: configuration)
                library.delete(removed)
                storage.refresh(library: library, configuration: configuration)
                app.show(ToastMessage(kind: .success,
                                      title: "Cleaned up",
                                      detail: "\(removed.count) clip\(removed.count == 1 ? "" : "s") moved to the Trash."))
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("That's \(report.wouldCleanupBytes.fileSizeString). They go to the Trash, not straight to deletion.")
        }
    }

    private var overviewCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Library", systemImage: "internaldrive")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
                          spacing: 12) {
                    StatTile(label: "Clips", value: "\(report.clipCount)",
                             caption: "\(report.favoriteCount) favourited",
                             systemImage: "film")
                    StatTile(label: "Used", value: report.totalLabel,
                             caption: "in this folder", systemImage: "shippingbox")
                    StatTile(label: "Free", value: report.availableLabel,
                             caption: report.volumeName,
                             systemImage: "externaldrive",
                             accent: report.isLowOnSpace ? .orange : nil)
                    StatTile(label: "Oldest",
                             value: report.oldestClipDate.map { date in
                                 let formatter = DateFormatter()
                                 formatter.dateFormat = "d MMM"
                                 return formatter.string(from: date)
                             } ?? "—",
                             caption: "first clip", systemImage: "calendar")
                }

                if report.isLowOnSpace {
                    ErrorNote(error: .diskFull(requiredBytes: 1_000_000_000,
                                               availableBytes: report.availableBytes))
                }
            }
        }
    }

    private var locationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Where clips are saved", systemImage: "folder")
                HStack {
                    Text(configuration.saveDirectory.path)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.open(configuration.saveDirectory) }
                        .controlSize(.small)
                    Button("Change…") { chooseFolder() }
                        .controlSize(.small)
                }
                Text("Kaiju indexes whatever is in this folder. Drop clips in from elsewhere and they'll be adopted with their real details; delete one in Finder and it disappears from the library on next launch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cleanupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Automatic cleanup",
                              subtitle: "Off by default. Kaiju will never delete a clip you saved unless you switch this on yourself.",
                              systemImage: "trash")

                SettingRow(title: "Enable automatic cleanup",
                           detail: "Runs after each clip is saved.",
                           systemImage: "power") {
                    Toggle("", isOn: $settings.settings.storage.automaticCleanupEnabled)
                        .toggleStyle(.switch).labelsHidden()
                }

                SettingRow(title: "Delete clips older than",
                           systemImage: "calendar.badge.minus") {
                    Picker("", selection: Binding(
                        get: { configuration.deleteOlderThanDays ?? 0 },
                        set: { settings.settings.storage.deleteOlderThanDays = $0 == 0 ? nil : $0 })) {
                        Text("Never").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Keep the library under",
                           systemImage: "arrow.down.circle") {
                    Picker("", selection: Binding(
                        get: { configuration.maximumLibraryGigabytes ?? 0 },
                        set: { settings.settings.storage.maximumLibraryGigabytes = $0 == 0 ? nil : $0 })) {
                        Text("No limit").tag(0.0)
                        Text("10 GB").tag(10.0)
                        Text("25 GB").tag(25.0)
                        Text("50 GB").tag(50.0)
                        Text("100 GB").tag(100.0)
                        Text("250 GB").tag(250.0)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                SettingRow(title: "Never delete favourites",
                           detail: "Strongly recommended. Favourites are how you tell Kaiju a clip matters.",
                           systemImage: "heart.fill") {
                    Toggle("", isOn: $settings.settings.storage.neverDeleteFavorites)
                        .toggleStyle(.switch).labelsHidden()
                }

                SettingRow(title: "Warn when free space drops below",
                           systemImage: "exclamationmark.triangle") {
                    Picker("", selection: $settings.settings.storage.warnWhenFreeSpaceBelowGB) {
                        Text("2 GB").tag(2.0)
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                        Text("25 GB").tag(25.0)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }

                if report.wouldCleanupCount > 0 {
                    Divider().padding(.vertical, 6)
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("These rules currently match \(report.wouldCleanupCount) clip\(report.wouldCleanupCount == 1 ? "" : "s")")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(report.wouldCleanupBytes.fileSizeString) would be moved to the Trash.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Clean up now") { confirmCleanup = true }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var largestCard: some View {
        let largest = library.clips.sorted { $0.byteCount > $1.byteCount }.prefix(5)
        return Group {
            if !largest.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Largest clips", systemImage: "chart.bar")
                        ForEach(Array(largest)) { clip in
                            HStack(spacing: 10) {
                                ClipThumbnail(clip: clip)
                                    .frame(width: 58, height: 33)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(clip.title).font(.system(size: 12)).lineLimit(1)
                                    Text("\(clip.durationLabel) · \(clip.resolutionLabel)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if clip.isFavorite {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.accent)
                                }
                                Text(clip.sizeLabel)
                                    .font(.system(size: 11, weight: .medium))
                                    .monospacedDigit()
                                Button {
                                    app.selectedClipIDs = [clip.id]
                                    app.section = .clips
                                } label: {
                                    Image(systemName: "arrow.right.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = configuration.saveDirectory
        panel.message = "Choose where Kaiju saves clips"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.settings.storage.saveDirectoryPath = url.path
    }
}

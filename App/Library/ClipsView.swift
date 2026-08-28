import SwiftUI
import AppKit
import KaijuKit

struct ClipsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.theme) private var theme

    @State private var renameTarget: Clip?
    @State private var renameText = ""
    @State private var confirmDelete = false

    private var visibleClips: [Clip] {
        library.filtered(app.clipFilter, sortedBy: app.clipSort)
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: theme.density == .compact ? 220 : 262), spacing: 14)]
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                grid
            }
            .frame(minWidth: 420)

            if let clip = app.selectedClips.first, app.selectedClipIDs.count == 1 {
                ClipDetailPanel(clip: clip)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 460)
            }
        }
        .alert("Rename clip", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let renameTarget { library.rename(renameTarget, to: renameText) }
                renameTarget = nil
            }
        }
        .confirmationDialog("Delete \(app.selectedClipIDs.count) clip\(app.selectedClipIDs.count == 1 ? "" : "s")?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                library.delete(app.selectedClips)
                app.selectedClipIDs = []
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("They go to the Trash, so you can still get them back.")
        }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search clips", text: $app.clipFilter.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !app.clipFilter.searchText.isEmpty {
                    Button {
                        app.clipFilter.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.kaijuSeparator.opacity(0.28)))
            .frame(maxWidth: 260)

            Toggle(isOn: $app.clipFilter.favoritesOnly) {
                Label("Favourites", systemImage: "heart")
            }
            .toggleStyle(.button)
            .controlSize(.small)

            Menu {
                Button("All games") { app.clipFilter.gameBundleIdentifier = nil }
                Divider()
                ForEach(library.knownGames, id: \.bundleIdentifier) { entry in
                    Button("\(entry.name) (\(entry.count))") {
                        app.clipFilter.gameBundleIdentifier = entry.bundleIdentifier
                    }
                }
            } label: {
                Label(gameFilterLabel, systemImage: "gamecontroller")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)

            Menu {
                ForEach(ClipSortOrder.allCases) { order in
                    Button(order.displayName) { app.clipSort = order }
                }
            } label: {
                Label(app.clipSort.displayName, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)

            Spacer()

            if app.selectedClipIDs.count > 1 {
                Text("\(app.selectedClipIDs.count) selected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .controlSize(.small)
            }

            Button {
                NSWorkspace.shared.open(settings.settings.storage.saveDirectory)
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var gameFilterLabel: String {
        guard let identifier = app.clipFilter.gameBundleIdentifier else { return "All games" }
        return library.knownGames.first { $0.bundleIdentifier == identifier }?.name ?? "Game"
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        if library.clips.isEmpty {
            EmptyStateView(systemImage: "film.stack",
                           title: "No clips yet",
                           message: "Start the replay buffer, then press \(app.hotkeys.displayString(for: .instantReplay)) whenever something worth keeping happens. The last few seconds are already recorded.",
                           actionTitle: "Go to Home") { app.section = .home }
        } else if visibleClips.isEmpty {
            EmptyStateView(systemImage: "magnifyingglass",
                           title: "Nothing matches",
                           message: "Try clearing the search or the filters.",
                           actionTitle: "Clear filters") { app.clipFilter = ClipFilter() }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(visibleClips) { clip in
                        ClipCard(clip: clip, isSelected: app.selectedClipIDs.contains(clip.id))
                            .onTapGesture(count: 2) { app.edit(clip) }
                            .simultaneousGesture(TapGesture().modifiers(.command).onEnded {
                                if app.selectedClipIDs.contains(clip.id) {
                                    app.selectedClipIDs.remove(clip.id)
                                } else {
                                    app.selectedClipIDs.insert(clip.id)
                                }
                            })
                            .onTapGesture { app.selectedClipIDs = [clip.id] }
                            .contextMenu {
                                ClipContextMenu(clip: clip)
                                Button("Rename…") {
                                    renameText = clip.title
                                    renameTarget = clip
                                }
                            }
                    }
                }
                .padding(16)
            }
        }
    }
}

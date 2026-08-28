import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KaijuKit

/// Game detection, arranged the way people actually think about it: what's
/// selected, what's running, what's installed, and anything you add yourself.
///
/// Kaiju never decides for you. Detection only *suggests*; automatic recording
/// only ever fires for applications sitting in the Selected list.
struct GamesView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var games: GameDetector
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: ReplayEngine
    @Environment(\.theme) private var theme

    @State private var searchText = ""

    private var selected: [DetectedApplication] {
        settings.settings.automation.selectedBundleIdentifiers
            .compactMap { identifier in
                games.application(for: identifier)
                    ?? DetectedApplication(bundleIdentifier: identifier,
                                           name: identifier,
                                           bundlePath: nil,
                                           isRunning: false,
                                           looksLikeGame: true,
                                           processIdentifier: nil)
            }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func filtered(_ list: [DetectedApplication]) -> [DetectedApplication] {
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                automationCard
                section(title: "Selected",
                        subtitle: "Kaiju watches for these and starts the buffer when they launch.",
                        systemImage: "checkmark.circle",
                        apps: filtered(selected),
                        emptyMessage: "Nothing selected yet. Pick a game below and Kaiju will handle the rest.")
                section(title: "Running now",
                        subtitle: "Everything open with a window.",
                        systemImage: "bolt.circle",
                        apps: filtered(games.running.filter { !isSelected($0) }),
                        emptyMessage: nil)
                section(title: "Likely games",
                        subtitle: "Guessed from app categories and engine markers — a guess, not a verdict.",
                        systemImage: "gamecontroller",
                        apps: filtered(games.suggestions),
                        emptyMessage: "Nothing obvious found. Add any app manually — Kaiju doesn't care whether it's really a game.")
            }
            .padding(theme.contentPadding)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search applications")
        .task {
            games.refreshRunning()
            await games.refreshInstalled()
        }
    }

    private var automationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Automatic recording", systemImage: "wand.and.stars")
                    Spacer()
                    Button {
                        Task { await games.refreshInstalled() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                Toggle("Turn the replay buffer on when a selected game launches",
                       isOn: $settings.settings.automation.startBufferWhenGameLaunches)
                    .toggleStyle(.switch)
                Toggle("Turn it off again when the game quits",
                       isOn: $settings.settings.automation.stopBufferWhenGameQuits)
                    .toggleStyle(.switch)
                Toggle("Automatic recording enabled",
                       isOn: $settings.settings.automation.automaticRecordingEnabled)
                    .toggleStyle(.switch)

                Divider()

                Toggle("Show a small recording indicator while buffering",
                       isOn: $settings.settings.automation.showStatusIndicator)
                    .toggleStyle(.switch)
                if settings.settings.automation.showStatusIndicator {
                    Picker("Indicator corner", selection: $settings.settings.automation.indicatorCorner) {
                        ForEach(AutomationConfiguration.IndicatorCorner.allCases) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let active = engine.activeGame {
                    Divider()
                    HStack(spacing: 8) {
                        BufferStatusDot(state: engine.state, size: 7)
                        Text("Currently buffering \(active.name)")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                }

                HStack {
                    Button {
                        addCustomApplication()
                    } label: {
                        Label("Add an application…", systemImage: "plus")
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func section(title: String, subtitle: String, systemImage: String,
                         apps: [DetectedApplication], emptyMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, subtitle: subtitle, systemImage: systemImage)
            if apps.isEmpty {
                if let emptyMessage {
                    Card(padding: 14) {
                        Text(emptyMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(apps) { app in
                        applicationRow(app)
                    }
                }
            }
        }
    }

    private func applicationRow(_ application: DetectedApplication) -> some View {
        let selected = isSelected(application)
        return Card(padding: 12, tinted: selected) {
            HStack(spacing: 11) {
                if let icon = games.icon(for: application) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, height: 30)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(application.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if application.isRunning {
                            Text("Running").foregroundStyle(theme.accent)
                        }
                        if application.looksLikeGame && !application.isRunning {
                            Text("Likely game")
                        }
                        Text(application.bundleIdentifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)

                Toggle("", isOn: Binding(
                    get: { selected },
                    set: { isOn in toggle(application, on: isOn) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
            }
        }
    }

    private func isSelected(_ application: DetectedApplication) -> Bool {
        settings.settings.automation.selectedBundleIdentifiers.contains(application.bundleIdentifier)
    }

    private func toggle(_ application: DetectedApplication, on: Bool) {
        if on {
            settings.settings.automation.selectedBundleIdentifiers.insert(application.bundleIdentifier)
        } else {
            settings.settings.automation.selectedBundleIdentifiers.remove(application.bundleIdentifier)
        }
    }

    private func addCustomApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose applications Kaiju should watch for"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let application = games.makeApplication(fromBundleAt: url) else { continue }
            settings.settings.automation.selectedBundleIdentifiers.insert(application.bundleIdentifier)
        }
    }
}

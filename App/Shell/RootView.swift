import SwiftUI
import KaijuKit

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: ReplayEngine

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 196, ideal: 214, max: 260)
        } detail: {
            detail
                .frame(minWidth: 640, minHeight: 480)
        }
        .navigationTitle("")
        .background {
            // The theme's tint sits behind everything at very low opacity. It's
            // what makes Synthwave feel different from Aurora without repainting
            // every control.
            ZStack {
                Color.kaijuCanvas
                app.theme.canvasTint.opacity(app.theme.canvasTintOpacity)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { ToastOverlay() }
        .environment(\.theme, app.theme)
        .preferredColorScheme(settings.settings.appearance.colorScheme.swiftUIScheme)
        .sheet(isPresented: $app.isShowingPermissionSetup) {
            PermissionSetupView()
                .environment(\.theme, app.theme)
        }
        .toolbar { toolbarContent }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.section {
        case .home:       HomeView()
        case .clips:      ClipsView()
        case .editor:     EditorView()
        case .games:      GamesView()
        case .recording:  RecordingSettingsView()
        case .audio:      AudioSettingsView()
        case .hotkeys:    HotkeysView()
        case .appearance: AppearanceView()
        case .storage:    StorageView()
        case .settings:   GeneralSettingsView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(app.section.title)
                .font(.system(size: 14, weight: .semibold))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if engine.isSavingClip {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await engine.saveInstantReplay() }
            } label: {
                Label("Instant Replay", systemImage: "bolt.fill")
            }
            .help("Save the last \(Int(settings.settings.replay.instantReplaySeconds))s — \(app.hotkeys.displayString(for: .instantReplay))")
            .disabled(!engine.canSaveClip)

            Button {
                Task { await engine.toggle() }
            } label: {
                Label(engine.isRunning ? "Stop Buffer" : "Start Buffer",
                      systemImage: engine.isRunning ? "stop.circle" : "record.circle")
            }
            .help(app.hotkeys.displayString(for: .toggleBuffer))
            .disabled(engine.state.isBusy)
        }
    }
}

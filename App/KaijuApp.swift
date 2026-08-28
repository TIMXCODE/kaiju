import SwiftUI
import AppKit
import KaijuKit

@main
struct KaijuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(app.engine)
                .environmentObject(app.library)
                .environmentObject(app.permissions)
                .environmentObject(app.catalog)
                .environmentObject(app.games)
                .environmentObject(app.hotkeys)
                .environmentObject(app.storage)
                .environmentObject(app.performance)
                .environmentObject(app.exports)
                .environmentObject(app.share)
                .environmentObject(app.microphones)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear {
                    app.bootstrap()
                    appDelegate.state = app
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 740)
        .commands { KaijuCommands(app: app) }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(app)
                .environmentObject(app.settings)
                .environmentObject(app.engine)
                .environmentObject(app.library)
                .environment(\.theme, app.theme)
        } label: {
            MenuBarLabel()
                .environmentObject(app)
                .environmentObject(app.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar glyph. Fills in when the buffer is live so the state is readable at a
/// glance without opening anything.
struct MenuBarLabel: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var engine: ReplayEngine

    var body: some View {
        switch app.settings.settings.appearance.menuBarIconStyle {
        case .statusDotOnly:
            Image(systemName: engine.isRunning ? "record.circle.fill" : "circle")
        case .glyphWithStatus:
            HStack(spacing: 3) {
                Image(systemName: engine.isRunning ? "bolt.fill" : "bolt")
                if engine.isRunning {
                    Text(engine.bufferStatus.bufferedSeconds.durationLabel)
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
            }
        case .glyph:
            Image(systemName: engine.isRunning ? "bolt.fill" : "bolt")
        }
    }
}

struct KaijuCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandMenu("Capture") {
            Button("Save Instant Replay") {
                Task { await app.engine.saveInstantReplay() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!app.engine.canSaveClip)

            Button("Capture Clip") {
                Task { await app.engine.saveCaptureClip() }
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(!app.engine.canSaveClip)

            Divider()

            Button(app.engine.isRunning ? "Stop Replay Buffer" : "Start Replay Buffer") {
                Task { await app.engine.toggle() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button("Open Clips Folder") {
                NSWorkspace.shared.open(app.settings.settings.storage.saveDirectory)
            }
        }

        CommandGroup(after: .toolbar) {
            ForEach(AppSection.allCases) { section in
                Button(section.title) { app.section = section }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A clipper that dies with its window is useless — the whole point is that
        // it keeps buffering while you're in a game.
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.flushBeforeQuit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { state?.openMainWindow() }
        return true
    }
}

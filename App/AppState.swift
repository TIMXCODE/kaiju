import SwiftUI
import Combine
import AppKit
import KaijuKit

struct ToastMessage: Identifiable, Equatable {
    enum Kind: Equatable { case success, warning, failure }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String?
    var fix: String?
}

/// Composition root.
///
/// Everything the app owns is created here once and wired together here once.
/// Views observe the pieces they need; nothing constructs an engine or a manager
/// on its own, which is why hiding the window or switching sections can't disturb
/// a running buffer.
@MainActor
final class AppState: ObservableObject {
    let settings: SettingsStore
    let permissions: PermissionManager
    let catalog: CaptureSourceCatalog
    let library: ClipLibrary
    let engine: ReplayEngine
    let games = GameDetector()
    let hotkeys = HotkeyManager()
    let storage = StorageManager()
    let performance = PerformanceMonitor()
    let exports: ExportManager
    let share = ShareManager()
    let microphones = MicrophoneCatalog()

    @Published var section: AppSection = .home
    @Published var toast: ToastMessage?
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var editingClipID: UUID?
    @Published var isShowingPermissionSetup = false
    @Published var clipFilter = ClipFilter()
    @Published var clipSort: ClipSortOrder = .newest

    private var cancellables = Set<AnyCancellable>()
    private var toastDismissTask: Task<Void, Never>?
    private var indicatorController: StatusIndicatorController?
    private var hasBootstrapped = false

    init() {
        let settings = SettingsStore.shared
        let permissions = PermissionManager()
        let catalog = CaptureSourceCatalog()
        let library = ClipLibrary(directory: settings.settings.storage.saveDirectory)

        self.settings = settings
        self.permissions = permissions
        self.catalog = catalog
        self.library = library
        self.engine = ReplayEngine(settings: settings,
                                   catalog: catalog,
                                   library: library,
                                   permissions: permissions)
        self.exports = ExportManager(library: library)
    }

    var theme: KaijuTheme { KaijuTheme.resolve(settings.settings.appearance) }

    // MARK: - Bootstrap

    func bootstrap() {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        NotificationManager.shared.configure()
        NotificationManager.shared.configuration = settings.settings.notifications
        NotificationManager.shared.onOpenClip = { [weak self] id in
            self?.section = .clips
            self?.selectedClipIDs = [id]
        }
        NotificationManager.shared.onOpenSettings = { [weak self] in
            self?.section = .settings
        }

        wireEngine()
        wireHotkeys()
        wireGames()
        wireSettingsObservers()

        performance.engineSampler = { [weak self] in
            self?.engine.performanceSnapshot() ?? PerformanceSnapshot()
        }
        performance.monitoredVolume = settings.settings.storage.saveDirectory
        performance.start()

        indicatorController = StatusIndicatorController(engine: engine, state: self)

        Task {
            await library.load()
            _ = await catalog.refresh()
            storage.refresh(library: library, configuration: settings.settings.storage)
            permissions.refreshAll()

            if !settings.settings.hasCompletedFirstRun
                || permissions.screenRecording != .granted {
                isShowingPermissionSetup = true
            }
            if settings.settings.replay.startBufferOnLaunch,
               permissions.isReadyToCapture(for: settings.settings) {
                await engine.start()
            }
        }
    }

    private func wireEngine() {
        engine.onFlash = { [weak self] message in
            self?.show(ToastMessage(kind: .success, title: message))
        }
        engine.onError = { [weak self] error in
            guard let self, error.isUserFacing else { return }
            self.show(ToastMessage(kind: .failure,
                                   title: error.title,
                                   detail: error.failureReason,
                                   fix: error.recoverySuggestion))
        }
        engine.onClipSaved = { [weak self] _ in
            guard let self else { return }
            self.storage.refresh(library: self.library,
                                 configuration: self.settings.settings.storage)
            _ = self.storage.runCleanupIfEnabled(library: self.library,
                                                 configuration: self.settings.settings.storage)
        }
    }

    private func wireHotkeys() {
        hotkeys.onTrigger = { [weak self] action in
            guard let self else { return }
            Task { await self.perform(action) }
        }
        hotkeys.apply(settings.settings.hotkeys)
    }

    private func wireGames() {
        games.selectedBundleIdentifiers = settings.settings.automation.selectedBundleIdentifiers
        games.onSelectedGameLaunched = { [weak self] app in
            guard let self else { return }
            let automation = self.settings.settings.automation
            guard automation.automaticRecordingEnabled, automation.startBufferWhenGameLaunches else { return }
            Task {
                guard !self.engine.isRunning else { return }
                await self.engine.start(game: app)
                if self.engine.isRunning {
                    self.show(ToastMessage(kind: .success,
                                           title: "Buffer started",
                                           detail: "\(app.name) launched."))
                }
            }
        }
        games.onSelectedGameQuit = { [weak self] app in
            guard let self else { return }
            let automation = self.settings.settings.automation
            guard automation.automaticRecordingEnabled, automation.stopBufferWhenGameQuits else { return }
            Task {
                guard self.engine.isRunning else { return }
                await self.engine.stop(reason: "\(app.name) quit.")
            }
        }
    }

    private func wireSettingsObservers() {
        settings.$settings
            .map(\.hotkeys)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] configuration in
                self?.hotkeys.apply(configuration)
            }
            .store(in: &cancellables)

        settings.$settings
            .map(\.automation.selectedBundleIdentifiers)
            .removeDuplicates()
            .sink { [weak self] identifiers in
                self?.games.selectedBundleIdentifiers = identifiers
            }
            .store(in: &cancellables)

        settings.$settings
            .map(\.notifications)
            .removeDuplicates()
            .sink { configuration in
                NotificationManager.shared.configuration = configuration
            }
            .store(in: &cancellables)

        settings.$settings
            .map(\.storage.saveDirectoryPath)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                let directory = self.settings.settings.storage.saveDirectory
                self.performance.monitoredVolume = directory
                Task { await self.library.setDirectory(directory) }
            }
            .store(in: &cancellables)

        settings.$settings
            .map(\.appearance.showDockIcon)
            .removeDuplicates()
            .sink { showDockIcon in
                // Switching to accessory hides the Dock icon without quitting, so
                // the menu bar can be the only presence while you're in a game.
                NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func perform(_ action: HotkeyAction) async {
        switch action {
        case .instantReplay:
            await engine.saveInstantReplay()
        case .captureClip:
            await engine.saveCaptureClip()
        case .toggleBuffer:
            await engine.toggle()
            show(ToastMessage(kind: engine.isRunning ? .success : .warning,
                              title: engine.isRunning ? "Replay buffer on" : "Replay buffer off"))
        case .toggleWindow:
            toggleMainWindow()
        case .toggleMicrophoneMute:
            settings.settings.audio.microphoneMuted.toggle()
            await engine.applySettingsChange(requiresRestart: false)
            show(ToastMessage(kind: .success,
                              title: settings.settings.audio.microphoneMuted ? "Mic muted" : "Mic live"))
        case .markMoment:
            show(ToastMessage(kind: .success, title: "Moment marked"))
        }
    }

    func toggleMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible })
                ?? NSApp.windows.first(where: { $0.canBecomeMain }) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func openMainWindow(section: AppSection? = nil) {
        if let section { self.section = section }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Toasts

    func show(_ message: ToastMessage) {
        guard settings.settings.notifications.showInAppToast || message.kind == .failure else { return }
        toast = message
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            let seconds: UInt64 = message.kind == .failure ? 7 : 3
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        withAnimation { toast = nil }
    }

    // MARK: - Convenience

    var selectedClips: [Clip] {
        library.clips.filter { selectedClipIDs.contains($0.id) }
    }

    var editingClip: Clip? {
        guard let editingClipID else { return nil }
        return library.clips.first { $0.id == editingClipID }
    }

    func edit(_ clip: Clip) {
        editingClipID = clip.id
        section = .editor
    }

    func flushBeforeQuit() {
        settings.flush()
        Task { await engine.stop() }
    }
}

import Foundation
import Combine
import AppKit

public struct DetectedApplication: Identifiable, Hashable, Sendable {
    public var id: String { bundleIdentifier }
    public var bundleIdentifier: String
    public var name: String
    public var bundlePath: String?
    public var isRunning: Bool
    public var looksLikeGame: Bool
    public var processIdentifier: pid_t?

    public var bundleURL: URL? {
        bundlePath.map { URL(fileURLWithPath: $0) }
    }
}

/// Watches which applications are running and tells the engine when one the user
/// selected shows up or goes away.
///
/// It never decides on its own that something is a game worth recording. It only
/// suggests: the automatic-recording list is entirely the user's, and an
/// unselected app launching does nothing at all.
@MainActor
public final class GameDetector: ObservableObject {
    @Published public private(set) var running: [DetectedApplication] = []
    @Published public private(set) var installed: [DetectedApplication] = []
    @Published public private(set) var activeSelection: DetectedApplication?
    @Published public private(set) var frontmostBundleIdentifier: String?
    @Published public var customBundleIdentifiers: Set<String> = []

    public var selectedBundleIdentifiers: Set<String> = [] {
        didSet { evaluate() }
    }

    /// Fired when a *selected* application starts running.
    public var onSelectedGameLaunched: ((DetectedApplication) -> Void)?
    /// Fired when the selected application that was running quits.
    public var onSelectedGameQuit: ((DetectedApplication) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var iconCache: [String: NSImage] = [:]

    public init() {
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshRunning() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self?.frontmostBundleIdentifier = app?.bundleIdentifier
            }
        })
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    // MARK: - Running applications

    public func refreshRunning() {
        let previous = Set(running.map(\.bundleIdentifier))

        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> DetectedApplication? in
                guard let bundleIdentifier = app.bundleIdentifier,
                      bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
                return DetectedApplication(
                    bundleIdentifier: bundleIdentifier,
                    name: app.localizedName ?? bundleIdentifier,
                    bundlePath: app.bundleURL?.path,
                    isRunning: true,
                    looksLikeGame: GameCatalog.looksLikeGame(bundleIdentifier: bundleIdentifier,
                                                             bundleURL: app.bundleURL),
                    processIdentifier: app.processIdentifier)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let current = Set(running.map(\.bundleIdentifier))
        let launched = current.subtracting(previous)
        let quit = previous.subtracting(current)

        for identifier in launched where selectedBundleIdentifiers.contains(identifier) {
            if let app = running.first(where: { $0.bundleIdentifier == identifier }) {
                KaijuLog.games.notice("Selected app launched: \(app.name, privacy: .public)")
                onSelectedGameLaunched?(app)
            }
        }
        for identifier in quit where selectedBundleIdentifiers.contains(identifier) {
            let app = DetectedApplication(bundleIdentifier: identifier,
                                          name: previousName(for: identifier),
                                          bundlePath: nil,
                                          isRunning: false,
                                          looksLikeGame: true,
                                          processIdentifier: nil)
            KaijuLog.games.notice("Selected app quit: \(app.name, privacy: .public)")
            onSelectedGameQuit?(app)
        }

        evaluate()
    }

    private var lastKnownNames: [String: String] = [:]

    private func previousName(for identifier: String) -> String {
        lastKnownNames[identifier] ?? identifier
    }

    private func evaluate() {
        for app in running { lastKnownNames[app.bundleIdentifier] = app.name }
        activeSelection = running.first { selectedBundleIdentifiers.contains($0.bundleIdentifier) }
    }

    /// True when any selected application is running right now.
    public var hasActiveSelection: Bool { activeSelection != nil }

    // MARK: - Installed applications

    /// Scans the usual install locations. Cheap enough to run on demand, and only
    /// runs when the Games page asks for it.
    public func refreshInstalled() async {
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications/Games")
        ]

        let found = await Task.detached(priority: .utility) { () -> [DetectedApplication] in
            var results: [String: DetectedApplication] = [:]
            for directory in directories {
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]) else { continue }
                for url in contents where url.pathExtension == "app" {
                    guard let bundle = Bundle(url: url),
                          let identifier = bundle.bundleIdentifier else { continue }
                    let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    results[identifier] = DetectedApplication(
                        bundleIdentifier: identifier,
                        name: name,
                        bundlePath: url.path,
                        isRunning: false,
                        looksLikeGame: GameCatalog.looksLikeGame(bundleIdentifier: identifier,
                                                                 bundleURL: url),
                        processIdentifier: nil)
                }
            }
            return results.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }.value

        let runningIdentifiers = Set(running.map(\.bundleIdentifier))
        installed = found.map { app in
            var copy = app
            copy.isRunning = runningIdentifiers.contains(app.bundleIdentifier)
            return copy
        }
    }

    /// Suggestions for the Games page: likely games, running first.
    public var suggestions: [DetectedApplication] {
        let pool = installed.isEmpty ? running : installed
        return pool
            .filter { $0.looksLikeGame && !selectedBundleIdentifiers.contains($0.bundleIdentifier) }
            .sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public func application(for bundleIdentifier: String) -> DetectedApplication? {
        running.first { $0.bundleIdentifier == bundleIdentifier }
            ?? installed.first { $0.bundleIdentifier == bundleIdentifier }
    }

    public func icon(for app: DetectedApplication) -> NSImage? {
        if let cached = iconCache[app.bundleIdentifier] { return cached }
        guard let url = app.bundleURL else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        iconCache[app.bundleIdentifier] = icon
        return icon
    }

    /// Lets the user point at any .app, including ones the scan missed.
    public func makeApplication(fromBundleAt url: URL) -> DetectedApplication? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return DetectedApplication(bundleIdentifier: identifier,
                                   name: name,
                                   bundlePath: url.path,
                                   isRunning: running.contains { $0.bundleIdentifier == identifier },
                                   looksLikeGame: true,
                                   processIdentifier: nil)
    }
}

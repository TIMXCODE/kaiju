import Foundation
import Combine
import ScreenCaptureKit
import CoreGraphics
import AppKit

public struct DisplayInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let pointSize: CGSize
    public let pixelSize: CGSize
    public let isMain: Bool

    public var resolutionLabel: String {
        "\(Int(pixelSize.width))×\(Int(pixelSize.height))"
    }
}

public struct WindowInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let title: String
    public let ownerName: String
    public let ownerBundleID: String?
    public let frame: CGRect
    public let isOnScreen: Bool

    public var displayTitle: String {
        title.isEmpty ? ownerName : title
    }
}

public struct ApplicationInfo: Identifiable, Hashable, Sendable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let name: String
    public let processID: pid_t
}

/// Snapshot of everything ScreenCaptureKit will let us record right now.
public struct ShareableSnapshot: Sendable {
    public var displays: [DisplayInfo] = []
    public var windows: [WindowInfo] = []
    public var applications: [ApplicationInfo] = []
    public var capturedAt: Date = .distantPast

    public var mainDisplay: DisplayInfo? {
        displays.first(where: \.isMain) ?? displays.first
    }
}

/// Enumerates capture sources and resolves a `CaptureSourceSelection` into a
/// concrete `SCContentFilter`. Kept apart from the capture engine so the UI can
/// browse sources without touching the recording pipeline.
@MainActor
public final class CaptureSourceCatalog: ObservableObject {
    @Published public private(set) var snapshot = ShareableSnapshot()
    @Published public private(set) var lastError: KaijuError?
    @Published public private(set) var isRefreshing = false

    private var rawContent: SCShareableContent?

    public init() {}

    @discardableResult
    public func refresh() async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            rawContent = content
            snapshot = Self.makeSnapshot(from: content)
            lastError = nil
            return true
        } catch {
            // The overwhelmingly common cause is a missing screen-recording grant.
            lastError = CGPreflightScreenCaptureAccess()
                ? .captureStartFailed(reason: "Couldn't read the list of capture sources: \(error.localizedDescription)")
                : .screenRecordingPermissionDenied
            KaijuLog.capture.error("SCShareableContent failed: \(String(describing: error))")
            return false
        }
    }

    private static func makeSnapshot(from content: SCShareableContent) -> ShareableSnapshot {
        var snapshot = ShareableSnapshot()
        snapshot.capturedAt = Date()

        let mainID = CGMainDisplayID()
        snapshot.displays = content.displays.enumerated().map { index, display in
            let pixelSize: CGSize
            if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                pixelSize = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            } else {
                pixelSize = CGSize(width: display.width, height: display.height)
            }
            return DisplayInfo(
                id: display.displayID,
                name: Self.name(forDisplayID: display.displayID, index: index),
                pointSize: CGSize(width: display.width, height: display.height),
                pixelSize: pixelSize,
                isMain: display.displayID == mainID)
        }

        snapshot.windows = content.windows.compactMap { window in
            // Menu-bar items, the Dock and 1-pixel helper windows are noise in a picker.
            guard window.frame.width > 120, window.frame.height > 90 else { return nil }
            guard let owner = window.owningApplication else { return nil }
            guard owner.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            return WindowInfo(
                id: window.windowID,
                title: window.title ?? "",
                ownerName: owner.applicationName,
                ownerBundleID: owner.bundleIdentifier,
                frame: window.frame,
                isOnScreen: window.isOnScreen)
        }
        .sorted { lhs, rhs in
            if lhs.ownerName == rhs.ownerName { return lhs.displayTitle < rhs.displayTitle }
            return lhs.ownerName.localizedCaseInsensitiveCompare(rhs.ownerName) == .orderedAscending
        }

        var seen = Set<String>()
        snapshot.applications = content.applications.compactMap { app in
            guard !app.bundleIdentifier.isEmpty else { return nil }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            guard seen.insert(app.bundleIdentifier).inserted else { return nil }
            return ApplicationInfo(bundleIdentifier: app.bundleIdentifier,
                                   name: app.applicationName,
                                   processID: app.processID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return snapshot
    }

    private static func name(forDisplayID id: CGDirectDisplayID, index: Int) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) {
            return screen.localizedName
        }
        return id == CGMainDisplayID() ? "Main Display" : "Display \(index + 1)"
    }

    // MARK: - Resolving a selection into a filter

    public struct ResolvedSource: Sendable {
        public let filter: SCContentFilter
        public let sourcePixelSize: CGSize
        public let label: String
        /// Bundle ID of the app being captured, when the source is app- or window-scoped.
        public let bundleIdentifier: String?
    }

    /// Turns the user's stored selection into something SCStream can use.
    /// Falls back to the main display (and says so) rather than failing, because
    /// a game quitting mid-session shouldn't kill the buffer.
    public func resolve(_ selection: CaptureSourceSelection,
                        excludingSelf: Bool,
                        activeGameBundleID: String? = nil) async throws -> ResolvedSource {
        if rawContent == nil { _ = await refresh() }
        guard let content = rawContent else {
            throw lastError ?? KaijuError.noCaptureSourceAvailable
        }

        let selfApp = content.applications.first {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let excluded: [SCRunningApplication] = (excludingSelf && selfApp != nil) ? [selfApp!] : []

        func displayFilter(_ display: SCDisplay) -> ResolvedSource {
            let filter = SCContentFilter(display: display,
                                         excludingApplications: excluded,
                                         exceptingWindows: [])
            return ResolvedSource(filter: filter,
                                  sourcePixelSize: Self.pixelSize(of: filter, display: display),
                                  label: Self.name(forDisplayID: display.displayID, index: 0),
                                  bundleIdentifier: nil)
        }

        switch selection {
        case .mainDisplay:
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                throw KaijuError.noCaptureSourceAvailable
            }
            return displayFilter(display)

        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                guard let fallback = content.displays.first else { throw KaijuError.noCaptureSourceAvailable }
                KaijuLog.capture.notice("Display \(id) is gone; falling back to the main display.")
                return displayFilter(fallback)
            }
            return displayFilter(display)

        case .window(let id, let title, let owner):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw KaijuError.captureSourceDisappeared(name: title.isEmpty ? owner : title)
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return ResolvedSource(filter: filter,
                                  sourcePixelSize: Self.pixelSize(of: filter, fallback: window.frame.size),
                                  label: window.title ?? owner,
                                  bundleIdentifier: window.owningApplication?.bundleIdentifier)

        case .application(let bundleID, let name):
            return try applicationSource(bundleID: bundleID, name: name, content: content)

        case .activeGame:
            guard let bundleID = activeGameBundleID else {
                guard let display = content.displays.first else { throw KaijuError.noCaptureSourceAvailable }
                return displayFilter(display)
            }
            let name = content.applications.first { $0.bundleIdentifier == bundleID }?.applicationName ?? bundleID
            return try applicationSource(bundleID: bundleID, name: name, content: content)
        }
    }

    private func applicationSource(bundleID: String,
                                   name: String,
                                   content: SCShareableContent) throws -> ResolvedSource {
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw KaijuError.captureSourceDisappeared(name: name)
        }
        // Capture the app on whichever display holds its largest window, so a game
        // on a second monitor doesn't come out as an empty rectangle.
        let appWindows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen
        }
        let largest = appWindows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        var chosenDisplay: SCDisplay? = nil
        if let largest {
            let centre = CGPoint(x: largest.frame.midX, y: largest.frame.midY)
            chosenDisplay = content.displays.first { $0.frame.contains(centre) }
                ?? content.displays.max { lhs, rhs in
                    lhs.frame.intersection(largest.frame).area < rhs.frame.intersection(largest.frame).area
                }
        }
        guard let display = chosenDisplay ?? content.displays.first else {
            throw KaijuError.noCaptureSourceAvailable
        }

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        return ResolvedSource(filter: filter,
                              sourcePixelSize: Self.pixelSize(of: filter, display: display),
                              label: name,
                              bundleIdentifier: bundleID)
    }

    private static func pixelSize(of filter: SCContentFilter,
                                  display: SCDisplay? = nil,
                                  fallback: CGSize? = nil) -> CGSize {
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        if rect.width > 1, rect.height > 1, scale > 0 {
            return CGSize(width: (rect.width * scale).rounded(),
                          height: (rect.height * scale).rounded())
        }
        if let display, let mode = CGDisplayCopyDisplayMode(display.displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        if let fallback, fallback.width > 1 { return fallback }
        return CGSize(width: 1920, height: 1080)
    }
}


extension CGRect {
    /// Zero for a null/infinite rect, which `width * height` would otherwise
    /// report as NaN and poison a comparison.
    var area: CGFloat {
        guard !isNull, !isInfinite, !isEmpty else { return 0 }
        return width * height
    }
}

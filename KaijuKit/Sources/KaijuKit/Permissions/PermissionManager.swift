import Foundation
import Combine
import AVFoundation
import CoreGraphics
import AppKit
import UserNotifications

public enum PermissionStatus: String, Sendable, Equatable {
    case notDetermined
    case granted
    case denied

    public var isUsable: Bool { self == .granted }
}

public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case microphone
    case notifications

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screenRecording: return "Screen & System Audio Recording"
        case .microphone:      return "Microphone"
        case .notifications:   return "Notifications"
        }
    }

    public var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .microphone:      return "mic.fill"
        case .notifications:   return "bell.fill"
        }
    }

    /// Why Kaiju wants it, in plain language — this text is what the first-run
    /// screen shows, so it has to be honest and specific.
    public var rationale: String {
        switch self {
        case .screenRecording:
            return "This is the whole app. Kaiju reads frames from your display or game window and keeps the last few minutes in a rolling buffer. macOS also routes system and game audio through this same permission."
        case .microphone:
            return "Only needed if you want your voice in clips. Leave mic capture off and Kaiju never asks for this, and never opens an input device."
        case .notifications:
            return "Used for the small confirmation when a clip lands, and for warnings like a full disk or a capture that stopped. Kaiju sends nothing else."
        }
    }

    public var isRequired: Bool { self == .screenRecording }

    var settingsURL: URL? {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }
}

/// Tracks the three permissions Kaiju can need, keeps them fresh, and knows how
/// to ask for each one. Nothing in the capture path assumes a permission — it
/// checks here first so a missing grant produces a setup screen, not a silent
/// black recording.
@MainActor
public final class PermissionManager: ObservableObject {
    @Published public private(set) var screenRecording: PermissionStatus = .notDetermined
    @Published public private(set) var microphone: PermissionStatus = .notDetermined
    @Published public private(set) var notifications: PermissionStatus = .notDetermined

    private var pollTimer: Timer?
    /// True once we've asked macOS at least once this launch. Screen recording
    /// has no "not determined" state we can read after the fact, so we track it.
    private var hasRequestedScreenRecording = false

    public init() {
        refreshAll()
    }

    deinit {
        pollTimer?.invalidate()
    }

    public func status(for kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording: return screenRecording
        case .microphone:      return microphone
        case .notifications:   return notifications
        }
    }

    /// Everything the app needs *right now*, given what the user has enabled.
    public func blockingIssues(for settings: KaijuSettings) -> [KaijuError] {
        var issues: [KaijuError] = []
        if screenRecording != .granted {
            issues.append(.screenRecordingPermissionDenied)
        }
        if settings.audio.captureMicrophone && microphone != .granted {
            issues.append(.microphonePermissionDenied)
        }
        return issues
    }

    public func isReadyToCapture(for settings: KaijuSettings) -> Bool {
        blockingIssues(for: settings).isEmpty
    }

    // MARK: - Refresh

    public func refreshAll() {
        refreshScreenRecording()
        refreshMicrophone()
        refreshNotifications()
    }

    public func refreshScreenRecording() {
        // CGPreflightScreenCaptureAccess reports the real TCC answer without
        // triggering the prompt, which is exactly what a status view wants.
        let granted = CGPreflightScreenCaptureAccess()
        let next: PermissionStatus = granted ? .granted
            : (hasRequestedScreenRecording ? .denied : .notDetermined)
        if next != screenRecording { screenRecording = next }
    }

    public func refreshMicrophone() {
        let next: PermissionStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: next = .granted
        case .notDetermined: next = .notDetermined
        default: next = .denied
        }
        if next != microphone { microphone = next }
    }

    public func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let next: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: next = .granted
            case .notDetermined: next = .notDetermined
            default: next = .denied
            }
            Task { @MainActor in
                guard let self else { return }
                if next != self.notifications { self.notifications = next }
            }
        }
    }

    /// Polls while a setup screen is on-screen. macOS doesn't notify us when the
    /// user flips a switch in System Settings, so short-interval polling is the
    /// only way the setup screen can tick over to "granted" by itself.
    public func startPolling(interval: TimeInterval = 1.0) {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Requesting

    public func request(_ kind: PermissionKind) async {
        switch kind {
        case .screenRecording: await requestScreenRecording()
        case .microphone:      await requestMicrophone()
        case .notifications:   await requestNotifications()
        }
    }

    public func requestScreenRecording() async {
        hasRequestedScreenRecording = true
        // This is the call that puts Kaiju in the System Settings list. It only
        // shows the prompt once per install; after that it just returns false.
        let granted = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        screenRecording = granted ? .granted : .denied
        if !granted { openSettings(for: .screenRecording) }
    }

    public func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
        if !granted, AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined {
            openSettings(for: .microphone)
        }
    }

    public func requestNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            notifications = granted ? .granted : .denied
        } catch {
            KaijuLog.app.error("Notification authorization failed: \(String(describing: error))")
            notifications = .denied
        }
    }

    public func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

import Foundation
import UserNotifications
import AppKit

/// Native notifications, kept deliberately sparse.
///
/// A clipper that talks constantly is a clipper you turn off. Everything here is
/// either a confirmation you asked for or something you need to fix.
@MainActor
public final class NotificationManager: NSObject, ObservableObject {
    public static let shared = NotificationManager()

    public var configuration = NotificationConfiguration()
    /// Called when the user clicks a notification, with the clip it refers to.
    public var onOpenClip: ((UUID) -> Void)?
    public var onOpenSettings: (() -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var isConfigured = false

    private override init() { super.init() }

    public func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self
        let reveal = UNNotificationAction(identifier: "kaiju.reveal", title: "Show in Kaiju", options: [.foreground])
        let clipCategory = UNNotificationCategory(identifier: "kaiju.clip",
                                                  actions: [reveal],
                                                  intentIdentifiers: [],
                                                  options: [])
        let fix = UNNotificationAction(identifier: "kaiju.fix", title: "Open Settings", options: [.foreground])
        let problemCategory = UNNotificationCategory(identifier: "kaiju.problem",
                                                     actions: [fix],
                                                     intentIdentifiers: [],
                                                     options: [])
        center.setNotificationCategories([clipCategory, problemCategory])
    }

    // MARK: - Sending

    public func clipSaved(_ clip: Clip) {
        guard configuration.clipSaved else { return }
        var subtitle = clip.durationLabel
        if let game = clip.gameName { subtitle += " · \(game)" }
        post(title: "Clip saved",
             body: "\(clip.title)\n\(subtitle)",
             categoryIdentifier: "kaiju.clip",
             userInfo: ["clipID": clip.id.uuidString])
    }

    public func exportCompleted(name: String, at url: URL) {
        guard configuration.exportCompleted else { return }
        post(title: "Export finished", body: name, categoryIdentifier: "kaiju.clip",
             userInfo: ["path": url.path])
    }

    public func recordingStopped(reason: String) {
        guard configuration.recordingStopped else { return }
        post(title: "Replay buffer stopped", body: reason, categoryIdentifier: "kaiju.problem")
    }

    public func lowDiskSpace(available: Int64) {
        guard configuration.lowDiskSpace else { return }
        post(title: "Running low on disk space",
             body: "\(available.fileSizeString) free. Clips may fail to save.",
             categoryIdentifier: "kaiju.problem")
    }

    public func problem(_ error: KaijuError) {
        guard error.isUserFacing else { return }
        switch error {
        case .screenRecordingPermissionDenied, .microphonePermissionDenied:
            guard configuration.permissionIssues else { return }
        default:
            guard configuration.captureFailures else { return }
        }
        var body = error.failureReason ?? ""
        if let fix = error.recoverySuggestion { body += "\n\(fix)" }
        post(title: error.title, body: body, categoryIdentifier: "kaiju.problem")
    }

    private func post(title: String, body: String,
                      categoryIdentifier: String,
                      userInfo: [String: Any] = [:]) {
        configure()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = userInfo
        if configuration.playSound { content.sound = .default }

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request) { error in
            if let error {
                KaijuLog.app.debug("Notification not delivered: \(String(describing: error))")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let raw = info["clipID"] as? String, let id = UUID(uuidString: raw) {
                self.onOpenClip?(id)
            } else if category == "kaiju.problem" {
                self.onOpenSettings?()
            }
        }
    }
}

import Foundation
import Combine

/// Everything the user can change, in one Codable value.
///
/// Keeping it as a single struct means the whole configuration can be snapshotted,
/// handed to the engine, diffed, exported, or reset without any partial-state bugs.
public struct KaijuSettings: Codable, Equatable, Sendable {
    public var recording = RecordingConfiguration()
    public var audio = AudioConfiguration()
    public var replay = ReplayConfiguration()
    public var automation = AutomationConfiguration()
    public var storage = StorageConfiguration()
    public var appearance = AppearanceConfiguration()
    public var notifications = NotificationConfiguration()
    public var hotkeys = HotkeyConfiguration()
    public var hasCompletedFirstRun = false
    /// Bumped when the shape changes so migrations have something to look at.
    public var schemaVersion = 1

    public init() {}

    /// Anything the engine can't run with. Surfaced in the UI before you hit record
    /// rather than blowing up mid-session.
    public func validate() -> [KaijuError] {
        var problems: [KaijuError] = []
        if replay.effectiveBufferSeconds < replay.instantReplaySeconds {
            problems.append(.invalidConfiguration(
                reason: "Instant Replay is longer than the replay buffer."))
        }
        if replay.memoryBudgetMB < 64 {
            problems.append(.invalidConfiguration(
                reason: "Memory budget below 64 MB won't hold even one second of 1080p."))
        }
        if recording.keyframeIntervalSeconds <= 0 || recording.keyframeIntervalSeconds > 10 {
            problems.append(.invalidConfiguration(
                reason: "Keyframe interval must be between 0.1 and 10 seconds."))
        }
        if audio.captureMicrophone && audio.microphoneGain <= 0 && !audio.microphoneMuted {
            problems.append(.invalidConfiguration(
                reason: "Microphone gain is zero but the mic isn't muted."))
        }
        return problems
    }
}

/// Loads, holds and persists `KaijuSettings`.
///
/// Writes are debounced: dragging a bitrate slider shouldn't hit the disk 200 times.
public final class SettingsStore: ObservableObject {
    @Published public var settings: KaijuSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
        }
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.mac.Kaiju.settings", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    public static let shared = SettingsStore()

    public init(fileURL: URL? = nil) {
        let resolved = fileURL ?? Self.defaultFileURL
        self.fileURL = resolved
        self.settings = Self.load(from: resolved) ?? KaijuSettings()
    }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Kaiju", isDirectory: true)
    }

    public static var defaultFileURL: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    private static func load(from url: URL) -> KaijuSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(KaijuSettings.self, from: data)
        } catch {
            // A settings file we can't read is worse than none: back it up and start fresh
            // rather than wedging the app on every launch.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            KaijuLog.app.error("Settings unreadable (\(String(describing: error))). Backed up to \(backup.lastPathComponent).")
            return nil
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = settings
        let url = fileURL
        let work = DispatchWorkItem {
            Self.write(snapshot, to: url)
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Force an immediate write. Called on app termination.
    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = settings
        let url = fileURL
        queue.sync { Self.write(snapshot, to: url) }
    }

    private static func write(_ settings: KaijuSettings, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            // Atomic so a crash mid-write can't leave a truncated file behind.
            try data.write(to: url, options: .atomic)
        } catch {
            KaijuLog.app.error("Couldn't save settings: \(String(describing: error))")
        }
    }

    public func resetToDefaults() {
        settings = KaijuSettings()
    }
}

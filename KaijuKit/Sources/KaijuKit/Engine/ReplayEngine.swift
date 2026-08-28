import Foundation
import Combine
import CoreMedia
import CoreGraphics
import AppKit

public enum ReplayEngineState: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case failed(KaijuError)

    public var isRunning: Bool { self == .running }
    public var isBusy: Bool { self == .starting || self == .stopping }

    public var label: String {
        switch self {
        case .idle:     return "Buffer off"
        case .starting: return "Starting…"
        case .running:  return "Buffering"
        case .stopping: return "Stopping…"
        case .failed:   return "Stopped"
        }
    }
}

public struct ClipSaveResult: Sendable {
    public let clip: Clip
    public let writeSeconds: TimeInterval
}

/// The app-facing recording controller.
///
/// The UI observes this. It never reaches past it into the capture pipeline —
/// which is what keeps the buffer alive when a window closes, a view redraws, or
/// the whole interface is hidden behind a full-screen game.
@MainActor
public final class ReplayEngine: ObservableObject {
    @Published public private(set) var state: ReplayEngineState = .idle
    @Published public private(set) var captureStats = CaptureStatisticsSnapshot()
    @Published public private(set) var bufferStatus = ReplayStoreStatus()
    @Published public private(set) var audioLevels = AudioLevelSnapshot()
    @Published public private(set) var sourceLabel: String = "—"
    @Published public private(set) var activeGame: DetectedApplication?
    @Published public private(set) var isSavingClip = false
    @Published public private(set) var lastError: KaijuError?
    @Published public private(set) var lastSavedClip: Clip?
    @Published public private(set) var backend: ReplayBuffer.Backend = .memory

    public var onClipSaved: ((Clip) -> Void)?
    public var onError: ((KaijuError) -> Void)?
    /// Fires with a short confirmation string for the on-screen toast.
    public var onFlash: ((String) -> Void)?

    private let pipeline = ReplayPipeline()
    private let settings: SettingsStore
    private let catalog: CaptureSourceCatalog
    private let library: ClipLibrary
    private let permissions: PermissionManager

    private var statusTimer: Timer?
    private var startedAt: Date?
    private var pendingSaves = 0

    public init(settings: SettingsStore,
                catalog: CaptureSourceCatalog,
                library: ClipLibrary,
                permissions: PermissionManager) {
        self.settings = settings
        self.catalog = catalog
        self.library = library
        self.permissions = permissions

        pipeline.onError = { [weak self] error in
            Task { @MainActor in self?.handlePipelineError(error) }
        }
    }

    deinit { statusTimer?.invalidate() }

    // MARK: - Derived state

    public var isRunning: Bool { state.isRunning }

    public var uptime: TimeInterval {
        guard let startedAt, state.isRunning else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    public var canSaveClip: Bool {
        state.isRunning && bufferStatus.bufferedSeconds > 0.5 && !isSavingClip
    }

    public var projectedBufferBytes: Int {
        let size = pipeline.encodeSize == .zero
            ? settings.settings.recording.resolution.encodeSize(
                forSource: catalog.snapshot.mainDisplay?.pixelSize ?? CGSize(width: 3840, height: 2160))
            : pipeline.encodeSize
        return ReplayBuffer.projectedMemoryUse(replay: settings.settings.replay,
                                               recording: settings.settings.recording,
                                               audio: settings.settings.audio,
                                               encodeSize: size).bytes
    }

    // MARK: - Lifecycle

    public func start(game: DetectedApplication? = nil) async {
        guard !state.isRunning, !state.isBusy else { return }

        permissions.refreshAll()
        let issues = permissions.blockingIssues(for: settings.settings)
        if let first = issues.first {
            state = .failed(first)
            report(first)
            return
        }

        state = .starting
        lastError = nil
        activeGame = game

        do {
            let configuration = settings.settings
            let resolved = try await catalog.resolve(configuration.recording.source,
                                                     excludingSelf: configuration.recording.excludeKaijuFromCapture,
                                                     activeGameBundleID: game?.bundleIdentifier)
            try await pipeline.start(ReplayPipeline.StartRequest(
                filter: resolved.filter,
                sourcePixelSize: resolved.sourcePixelSize,
                sourceLabel: resolved.label,
                recording: configuration.recording,
                audio: configuration.audio,
                replay: configuration.replay,
                scratchDirectory: Self.scratchDirectory))

            sourceLabel = resolved.label
            backend = pipeline.buffer.backend
            startedAt = Date()
            state = .running
            startStatusTimer()
            KaijuLog.app.notice("Replay buffer running on \(resolved.label, privacy: .public)")
        } catch let error as KaijuError {
            state = .failed(error)
            report(error)
        } catch {
            let wrapped = KaijuError.captureStartFailed(reason: error.localizedDescription)
            state = .failed(wrapped)
            report(wrapped)
        }
    }

    public func stop(reason: String? = nil) async {
        guard state.isRunning || state == .starting else { return }
        state = .stopping
        stopStatusTimer()
        await pipeline.stop()
        startedAt = nil
        captureStats = CaptureStatisticsSnapshot()
        bufferStatus = ReplayStoreStatus()
        audioLevels = AudioLevelSnapshot()
        activeGame = nil
        state = .idle
        if let reason {
            NotificationManager.shared.recordingStopped(reason: reason)
        }
    }

    public func toggle() async {
        if state.isRunning { await stop() } else { await start() }
    }

    /// Re-applies settings that need a restart (resolution, codec, buffer length)
    /// and hot-applies the ones that don't (bitrate, gains, mute).
    public func applySettingsChange(requiresRestart: Bool) async {
        guard state.isRunning else { return }
        if requiresRestart {
            let game = activeGame
            await stop()
            await start(game: game)
        } else {
            await pipeline.updateLiveSettings(recording: settings.settings.recording,
                                              audio: settings.settings.audio)
        }
    }

    // MARK: - Saving

    public func saveInstantReplay() async {
        await saveClip(kind: .instantReplay,
                       duration: settings.settings.replay.instantReplaySeconds)
    }

    public func saveCaptureClip() async {
        await saveClip(kind: .captureClip,
                       duration: settings.settings.replay.captureClipSeconds)
    }

    /// Saves the last `duration` seconds. Returns immediately after the snapshot
    /// is taken; the file is written in the background so the buffer never pauses
    /// and you can fire the hotkey again straight away.
    @discardableResult
    public func saveClip(kind: ClipKind, duration: TimeInterval) async -> Clip? {
        guard state.isRunning else {
            report(.bufferEmpty)
            return nil
        }
        let configuration = settings.settings

        // Refuse before writing rather than leaving a truncated file behind.
        let required = Int64(Double(pipeline.encodeBitrate) / 8.0 * duration * 1.25)
        let available = SystemMetrics.availableCapacity(at: configuration.storage.saveDirectory)
        guard available > required + 100_000_000 else {
            report(.diskFull(requiredBytes: required, availableBytes: available))
            return nil
        }

        isSavingClip = true
        pendingSaves += 1
        defer {
            pendingSaves -= 1
            if pendingSaves <= 0 { isSavingClip = false }
        }

        do {
            let snapshot = try await pipeline.makeSnapshot(duration: duration)
            let game = activeGame
            let url = Self.makeClipURL(in: configuration.storage.saveDirectory,
                                       gameName: game?.name)
            let outcome = try await ClipWriter.write(snapshot: snapshot,
                                                     to: url,
                                                     audioBitrate: configuration.audio.audioBitrate)

            let clip = Clip(fileName: url.lastPathComponent,
                            title: url.deletingPathExtension().lastPathComponent,
                            createdAt: Date(),
                            duration: outcome.duration,
                            byteCount: outcome.byteCount,
                            width: outcome.width,
                            height: outcome.height,
                            frameRate: outcome.frameRate,
                            codec: configuration.recording.codec.displayName,
                            kind: kind,
                            gameName: game?.name,
                            gameBundleIdentifier: game?.bundleIdentifier,
                            audioTrackCount: outcome.audioTrackCount)

            library.add(clip)
            lastSavedClip = clip
            onClipSaved?(clip)
            NotificationManager.shared.clipSaved(clip)
            onFlash?("\(kind.displayName) saved · \(clip.durationLabel)")
            KaijuLog.clips.notice("Saved \(clip.fileName, privacy: .public) in \(String(format: "%.2f", outcome.writeSeconds))s")
            return clip
        } catch let error as KaijuError {
            report(error)
            return nil
        } catch {
            report(.clipWriteFailed(reason: error.localizedDescription))
            return nil
        }
    }

    // MARK: - Status polling

    private func startStatusTimer() {
        stopStatusTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        refreshStatus()
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func refreshStatus() {
        pipeline.capture.refreshStaleness()
        captureStats = pipeline.capture.stats
        bufferStatus = pipeline.buffer.status
        audioLevels = pipeline.audioLevels
        backend = pipeline.buffer.backend
    }

    public func performanceSnapshot() -> PerformanceSnapshot {
        pipeline.performanceSnapshot()
    }

    // MARK: - Errors

    private func handlePipelineError(_ error: KaijuError) {
        lastError = error
        state = .failed(error)
        stopStatusTimer()
        report(error)
        Task { await pipeline.stop() }
    }

    private func report(_ error: KaijuError) {
        lastError = error
        onError?(error)
        NotificationManager.shared.problem(error)
        KaijuLog.app.error("\(error.title, privacy: .public): \(error.failureReason ?? "", privacy: .public)")
    }

    // MARK: - Paths

    public static var scratchDirectory: URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.mac.Kaiju", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func makeClipURL(in directory: URL, gameName: String?) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let prefix = (gameName?.isEmpty == false ? gameName! : "Kaiju")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var candidate = directory.appendingPathComponent("\(prefix) \(stamp).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(prefix) \(stamp) (\(counter)).mp4")
            counter += 1
        }
        return candidate
    }
}

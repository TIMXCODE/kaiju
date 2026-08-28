import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AVFoundation

/// The engine with no app around it.
///
/// This exists so the recording path can be exercised — and proved — without a
/// window, a menu bar, or a single SwiftUI view. `kaijuctl` drives it, and so can
/// a test. If the buffer works here, it works in the app; the UI is a viewer.
public final class HeadlessRecorder: @unchecked Sendable {

    public struct Options {
        public var recording = RecordingConfiguration()
        public var audio = AudioConfiguration()
        public var replay = ReplayConfiguration()
        public var displayID: CGDirectDisplayID?
        public var windowID: CGWindowID?
        public var applicationBundleID: String?
        public var scratchDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.mac.Kaiju.headless", isDirectory: true)

        public init() {}
    }

    private let pipeline = ReplayPipeline()
    private let errorBox = Guarded<KaijuError?>(nil)

    public init() {
        pipeline.onError = { [weak self] error in
            self?.errorBox.withLock { $0 = error }
        }
    }

    public var lastError: KaijuError? { errorBox.current }
    public var isRunning: Bool { pipeline.isRunning }

    public func start(_ options: Options) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw KaijuError.screenRecordingPermissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let (filter, size, label) = try Self.makeFilter(options: options, content: content)

        try await pipeline.start(ReplayPipeline.StartRequest(
            filter: filter,
            sourcePixelSize: size,
            sourceLabel: label,
            recording: options.recording,
            audio: options.audio,
            replay: options.replay,
            scratchDirectory: options.scratchDirectory))
    }

    public func stop() async {
        await pipeline.stop()
    }

    /// Saves the last `duration` seconds to `url` and returns what was written.
    @discardableResult
    public func save(duration: TimeInterval, to url: URL, audioBitrate: Int = 192_000) async throws -> ClipWriteOutcome {
        let snapshot = try await pipeline.makeSnapshot(duration: duration)
        return try await ClipWriter.write(snapshot: snapshot, to: url, audioBitrate: audioBitrate)
    }

    public var captureStats: CaptureStatisticsSnapshot { pipeline.capture.stats }
    public var bufferStatus: ReplayStoreStatus { pipeline.buffer.status }
    public var backend: ReplayBuffer.Backend { pipeline.buffer.backend }
    public var audioLevels: AudioLevelSnapshot { pipeline.audioLevels }
    public func performance() -> PerformanceSnapshot { pipeline.performanceSnapshot() }

    private static func makeFilter(options: Options,
                                   content: SCShareableContent)
    throws -> (SCContentFilter, CGSize, String) {

        if let windowID = options.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw KaijuError.captureSourceDisappeared(name: "window \(windowID)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = filterSize(filter, fallback: window.frame.size)
            return (filter, size, window.title ?? "Window \(windowID)")
        }

        if let bundleID = options.applicationBundleID {
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }),
                  let display = content.displays.first else {
                throw KaijuError.captureSourceDisappeared(name: bundleID)
            }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let size = filterSize(filter, fallback: CGSize(width: display.width, height: display.height))
            return (filter, size, app.applicationName)
        }

        let targetID = options.displayID ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == targetID })
                ?? content.displays.first else {
            throw KaijuError.noCaptureSourceAvailable
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        var fallback = CGSize(width: display.width, height: display.height)
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            fallback = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return (filter, filterSize(filter, fallback: fallback), "Display \(display.displayID)")
    }

    private static func filterSize(_ filter: SCContentFilter, fallback: CGSize) -> CGSize {
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        if rect.width > 1, rect.height > 1, scale > 0 {
            return CGSize(width: (rect.width * scale).rounded(),
                          height: (rect.height * scale).rounded())
        }
        return fallback
    }
}

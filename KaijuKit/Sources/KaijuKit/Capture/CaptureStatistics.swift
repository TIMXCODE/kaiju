import Foundation
import QuartzCore
import CoreMedia

/// Live capture numbers. Every value here is counted from real stream callbacks —
/// nothing in the performance panel is estimated or made up.
public struct CaptureStatisticsSnapshot: Sendable, Equatable {
    public var isRunning = false
    public var framesDelivered: Int = 0
    /// Frames ScreenCaptureKit sent with a non-complete status (nothing changed
    /// on screen). We deliberately don't encode these — that's the single biggest
    /// reason Kaiju is cheap when a game is paused or a menu is open.
    public var framesIdle: Int = 0
    /// Frames we threw away because the encoder was still busy.
    public var framesDropped: Int = 0
    public var audioPacketsSystem: Int = 0
    public var audioPacketsMicrophone: Int = 0
    /// Frames per second measured over a rolling one-second window.
    public var measuredFPS: Double = 0
    public var captureWidth: Int = 0
    public var captureHeight: Int = 0
    public var lastFrameTime: CMTime = .invalid
    public var startedAt: Date?

    public var resolutionLabel: String {
        captureWidth > 0 ? "\(captureWidth)×\(captureHeight)" : "—"
    }

    public var dropRate: Double {
        let total = framesDelivered + framesDropped
        return total > 0 ? Double(framesDropped) / Double(total) : 0
    }

    public var uptime: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}

final class CaptureStatistics: @unchecked Sendable {
    private let lock = UnfairLock()
    private var snapshot = CaptureStatisticsSnapshot()
    private var windowStart: CFTimeInterval = CACurrentMediaTime()
    private var windowFrames: Int = 0

    func begin(width: Int, height: Int) {
        lock.withLock {
            snapshot = CaptureStatisticsSnapshot()
            snapshot.isRunning = true
            snapshot.captureWidth = width
            snapshot.captureHeight = height
            snapshot.startedAt = Date()
            windowStart = CACurrentMediaTime()
            windowFrames = 0
        }
    }

    func end() {
        lock.withLock {
            snapshot.isRunning = false
            snapshot.measuredFPS = 0
        }
    }

    func recordFrame(at time: CMTime) {
        lock.withLock {
            snapshot.framesDelivered += 1
            snapshot.lastFrameTime = time
            windowFrames += 1
            let now = CACurrentMediaTime()
            let elapsed = now - windowStart
            if elapsed >= 1.0 {
                snapshot.measuredFPS = Double(windowFrames) / elapsed
                windowFrames = 0
                windowStart = now
            }
        }
    }

    func recordIdleFrame() {
        lock.withLock { snapshot.framesIdle += 1 }
    }

    func recordDroppedFrame() {
        lock.withLock { snapshot.framesDropped += 1 }
    }

    func recordAudio(_ source: AudioSourceKind) {
        lock.withLock {
            switch source {
            case .system:     snapshot.audioPacketsSystem += 1
            case .microphone: snapshot.audioPacketsMicrophone += 1
            }
        }
    }

    func updateSize(width: Int, height: Int) {
        lock.withLock {
            snapshot.captureWidth = width
            snapshot.captureHeight = height
        }
    }

    /// Zeroes the FPS reading if no frame has arrived for a while, so a frozen
    /// capture reads as 0 rather than sitting at its last value.
    func decayIfStale() {
        lock.withLock {
            guard snapshot.isRunning else { return }
            if CACurrentMediaTime() - windowStart > 2.0 {
                snapshot.measuredFPS = 0
            }
        }
    }

    var current: CaptureStatisticsSnapshot {
        lock.withLock { snapshot }
    }
}

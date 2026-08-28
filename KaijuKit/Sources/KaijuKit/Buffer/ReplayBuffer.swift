import Foundation
import CoreMedia
import CoreGraphics
import AVFoundation

/// The rolling buffer, independent of any UI.
///
/// It owns whichever storage backend suits the configured duration and settings —
/// RAM for short buffers, disk segments for long ones — and it is the only thing
/// that decides which. Callers just push samples in and ask for the last N seconds.
public final class ReplayBuffer {

    public struct Configuration {
        public var replay: ReplayConfiguration
        public var recording: RecordingConfiguration
        public var audio: AudioConfiguration
        public var encodeSize: CGSize
        public var encodeBitrate: Int
        public var scratchDirectory: URL

        public init(replay: ReplayConfiguration,
                    recording: RecordingConfiguration,
                    audio: AudioConfiguration,
                    encodeSize: CGSize,
                    encodeBitrate: Int,
                    scratchDirectory: URL) {
            self.replay = replay
            self.recording = recording
            self.audio = audio
            self.encodeSize = encodeSize
            self.encodeBitrate = encodeBitrate
            self.scratchDirectory = scratchDirectory
        }
    }

    public enum Backend: String, Sendable {
        case memory
        case disk

        public var displayName: String {
            switch self {
            case .memory: return "In memory"
            case .disk:   return "Disk segments"
            }
        }
    }

    private var store: ReplayStore?
    private(set) public var backend: Backend = .memory
    private(set) public var configuration: Configuration?
    private let lock = UnfairLock()

    public init() {}

    // MARK: - Lifecycle

    public func start(_ configuration: Configuration) throws {
        stop()

        let retain = configuration.replay.effectiveBufferSeconds
        let memoryConfiguration = MemoryReplayStore.Configuration(
            retainSeconds: retain,
            estimatedVideoBitrate: configuration.encodeBitrate,
            sampleRate: configuration.audio.sampleRate,
            channelCount: configuration.audio.channelCount,
            separateTracks: configuration.audio.separateTracks,
            memoryBudgetBytes: configuration.replay.memoryBudgetBytes,
            encodeSize: configuration.encodeSize,
            frameRate: configuration.recording.frameRate.rawValue)

        if MemoryReplayStore.fitsInMemory(configuration: memoryConfiguration) {
            store = MemoryReplayStore(configuration: memoryConfiguration)
            backend = .memory
        } else {
            let directory = configuration.scratchDirectory
                .appendingPathComponent("ReplayBuffer", isDirectory: true)
            let diskConfiguration = DiskReplayStore.Configuration(
                retainSeconds: retain,
                segmentSeconds: DiskReplayStore.Configuration.segmentLength(forRetain: retain),
                encodeSize: configuration.encodeSize,
                frameRate: configuration.recording.frameRate.rawValue,
                sampleRate: configuration.audio.sampleRate,
                channelCount: configuration.audio.channelCount,
                separateTracks: configuration.audio.separateTracks,
                audioBitrate: configuration.audio.audioBitrate,
                directory: directory)
            store = try DiskReplayStore(configuration: diskConfiguration)
            backend = .disk
        }

        self.configuration = configuration
        KaijuLog.buffer.notice("Replay buffer started — \(Int(retain))s, backend: \(self.backend.rawValue, privacy: .public)")
    }

    public func stop() {
        let existing = store
        store = nil
        configuration = nil
        existing?.shutdown()
    }

    public func reset() {
        store?.reset()
    }

    public var isRunning: Bool { store != nil }

    // MARK: - Ingest

    public func appendVideo(bytes: UnsafeRawBufferPointer,
                            pts: CMTime,
                            decodeTime: CMTime,
                            duration: CMTime,
                            isSync: Bool,
                            formatDescription: CMFormatDescription) {
        store?.appendVideo(bytes: bytes, pts: pts, decodeTime: decodeTime,
                           duration: duration, isSync: isSync,
                           formatDescription: formatDescription)
    }

    public func appendAudio(samples: UnsafePointer<Float>,
                            frameCount: Int,
                            pts: CMTime,
                            track: AudioTrackKind,
                            format: AVAudioFormat) {
        store?.appendAudio(samples: samples, frameCount: frameCount,
                           pts: pts, track: track, format: format)
    }

    // MARK: - Extraction

    /// Lifts the last `duration` seconds out. Blocking, but bounded and cheap —
    /// a memcpy for the memory backend, a segment flush for the disk one — and it
    /// never stops ingest.
    public func snapshot(duration: TimeInterval) throws -> ReplaySnapshot {
        guard let store else { throw KaijuError.bufferEmpty }
        return try store.snapshot(duration: duration)
    }

    public var status: ReplayStoreStatus {
        var status = store?.status ?? ReplayStoreStatus()
        if let configuration {
            status.capacitySeconds = configuration.replay.effectiveBufferSeconds
        }
        return status
    }

    /// What a given configuration would cost before you switch to it. Powers the
    /// "this will use about N MB" line in Recording settings.
    public static func projectedMemoryUse(replay: ReplayConfiguration,
                                          recording: RecordingConfiguration,
                                          audio: AudioConfiguration,
                                          encodeSize: CGSize) -> (bytes: Int, backend: Backend) {
        let bitrate = recording.bitrate(width: Int(encodeSize.width), height: Int(encodeSize.height))
        let configuration = MemoryReplayStore.Configuration(
            retainSeconds: replay.effectiveBufferSeconds,
            estimatedVideoBitrate: bitrate,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount,
            separateTracks: audio.separateTracks,
            memoryBudgetBytes: replay.memoryBudgetBytes,
            encodeSize: encodeSize,
            frameRate: recording.frameRate.rawValue)
        if MemoryReplayStore.fitsInMemory(configuration: configuration) {
            return (MemoryReplayStore.sizing(for: configuration).total, .memory)
        }
        // Disk-backed: RAM stays flat, the cost moves to the scratch folder.
        let seconds = replay.effectiveBufferSeconds
        let diskBytes = Int(Double(bitrate) / 8.0 * seconds * 1.2)
        return (diskBytes, .disk)
    }
}

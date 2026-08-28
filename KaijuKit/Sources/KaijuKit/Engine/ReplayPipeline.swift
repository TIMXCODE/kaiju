import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AVFoundation

/// The recording machine, with no UI and no main-actor isolation.
///
/// Capture → encode → ring, plus system and microphone audio → mix → ring. That's
/// the whole thing. It runs on its own queues at `userInteractive` priority and
/// never touches AppKit, which is what makes it usable from tests and from the
/// `kaijuctl` harness with no window server involved.
final class ReplayPipeline: NSObject, @unchecked Sendable {

    struct StartRequest {
        var filter: SCContentFilter
        var sourcePixelSize: CGSize
        var sourceLabel: String
        var recording: RecordingConfiguration
        var audio: AudioConfiguration
        var replay: ReplayConfiguration
        var scratchDirectory: URL
    }

    let capture = ScreenCaptureEngine()
    let encoder = VideoEncoder()
    let buffer = ReplayBuffer()
    private var mixer: AudioMixer?
    private var monitor: MicrophoneMonitor?

    private(set) var encodeSize: CGSize = .zero
    private(set) var encodeBitrate: Int = 0
    private(set) var isRunning = false
    private var audioConfiguration = AudioConfiguration()

    /// Errors that came from a background queue and need surfacing.
    var onError: ((KaijuError) -> Void)?

    override init() {
        super.init()
        capture.delegate = self
        encoder.delegate = self
        encoder.onFrameProcessed = { [weak self] in
            self?.capture.frameCompleted()
        }
    }

    // MARK: - Lifecycle

    func start(_ request: StartRequest) async throws {
        if isRunning { await stop() }

        let size = request.recording.resolution.encodeSize(forSource: request.sourcePixelSize)
        guard size.width >= 2, size.height >= 2 else {
            throw KaijuError.unsupportedResolution(width: Int(size.width), height: Int(size.height))
        }
        encodeSize = size
        encodeBitrate = request.recording.bitrate(width: Int(size.width), height: Int(size.height))
        audioConfiguration = request.audio

        // Everything downstream is up before a single frame arrives, so the very
        // first second of the buffer is as good as the last.
        let encoderConfiguration = VideoEncoderConfiguration.make(recording: request.recording,
                                                                  encodeSize: size)
        do {
            try encoder.start(encoderConfiguration)
        } catch let error as KaijuError {
            // A machine without the requested hardware encoder should fall back
            // rather than refuse to record.
            guard case .encoderUnavailable = error, request.recording.requireHardwareEncoder else {
                throw error
            }
            var relaxed = encoderConfiguration
            relaxed.requireHardware = false
            KaijuLog.encoder.notice("No hardware \(request.recording.codec.displayName, privacy: .public) encoder; falling back to software.")
            try encoder.start(relaxed)
        }

        if let mixer = AudioMixer(configuration: request.audio) {
            mixer.delegate = self
            self.mixer = mixer
            if request.audio.captureMicrophone && request.audio.monitorMicrophone,
               let monitor = MicrophoneMonitor(format: mixer.outputFormat) {
                monitor.volume = request.audio.monitorVolume
                monitor.start()
                self.monitor = monitor
                mixer.onMicrophoneMonitorChunk = { [weak monitor] samples, frameCount in
                    monitor?.enqueue(samples, frameCount: frameCount)
                }
            }
        }

        try buffer.start(ReplayBuffer.Configuration(
            replay: request.replay,
            recording: request.recording,
            audio: request.audio,
            encodeSize: size,
            encodeBitrate: encodeBitrate,
            scratchDirectory: request.scratchDirectory))

        do {
            try await capture.start(ScreenCaptureEngine.StartRequest(
                filter: request.filter,
                sourcePixelSize: request.sourcePixelSize,
                recording: request.recording,
                audio: request.audio,
                sourceLabel: request.sourceLabel))
        } catch {
            buffer.stop()
            encoder.teardown()
            mixer = nil
            monitor?.stop()
            monitor = nil
            throw error
        }

        isRunning = true
    }

    func stop() async {
        guard isRunning || capture.isRunning else { return }
        isRunning = false
        await capture.stop()
        encoder.teardown()
        monitor?.stop()
        monitor = nil
        mixer = nil
        buffer.stop()
    }

    /// Applies settings that can change without dropping the buffer.
    func updateLiveSettings(recording: RecordingConfiguration, audio: AudioConfiguration) async {
        audioConfiguration = audio
        mixer?.updateConfiguration(audio)
        monitor?.volume = audio.monitorVolume
        let bitrate = recording.bitrate(width: Int(encodeSize.width), height: Int(encodeSize.height))
        if bitrate != encodeBitrate {
            encodeBitrate = bitrate
            encoder.updateBitrate(bitrate)
        }
        try? await capture.updateConfiguration(recording: recording, audio: audio)
    }

    // MARK: - Saving

    /// Pulls a clip out of the buffer. Blocking work happens off the caller's
    /// thread; the buffer itself is never paused.
    func makeSnapshot(duration: TimeInterval) async throws -> ReplaySnapshot {
        // Push any frames still inside VideoToolbox into the ring first, so the
        // clip ends on the moment you actually pressed the key.
        encoder.flush()
        let buffer = self.buffer
        return try await Task.detached(priority: .userInitiated) {
            try buffer.snapshot(duration: duration)
        }.value
    }

    var audioLevels: AudioLevelSnapshot { mixer?.currentLevels ?? AudioLevelSnapshot() }

    func performanceSnapshot() -> PerformanceSnapshot {
        capture.refreshStaleness()
        var snapshot = PerformanceSnapshot()
        let stats = capture.stats
        snapshot.captureFPS = stats.measuredFPS
        snapshot.framesDropped = stats.framesDropped + encoder.droppedFrameCount
        snapshot.framesIdle = stats.framesIdle
        snapshot.resolutionLabel = stats.resolutionLabel
        snapshot.encoderIsHardware = encoder.isUsingHardwareEncoder
        snapshot.encoderRunning = encoder.isRunning
        snapshot.encoderCodec = encoder.activeConfiguration?.codec.displayName ?? "—"
        snapshot.targetFPS = encoder.activeConfiguration?.frameRate ?? 0
        snapshot.measuredBitrate = encoder.measuredBitrate
        snapshot.configuredBitrate = encoder.activeConfiguration?.bitrate ?? 0

        let status = buffer.status
        snapshot.bufferedSeconds = status.bufferedSeconds
        snapshot.bufferCapacitySeconds = status.capacitySeconds
        snapshot.bufferBackend = buffer.backend.displayName
        snapshot.bufferMemoryBytes = status.memoryBytes
        snapshot.bufferDiskBytes = status.diskBytes
        return snapshot
    }
}

// MARK: - Capture

extension ReplayPipeline: CaptureEngineDelegate {
    func captureEngine(_ engine: ScreenCaptureEngine,
                       didOutputVideoFrame pixelBuffer: CVPixelBuffer,
                       presentationTime: CMTime) {
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }

    func captureEngine(_ engine: ScreenCaptureEngine,
                       didOutputAudio sampleBuffer: CMSampleBuffer,
                       from source: AudioSourceKind) {
        mixer?.ingest(sampleBuffer, from: source)
    }

    func captureEngine(_ engine: ScreenCaptureEngine, didFail error: KaijuError) {
        isRunning = false
        onError?(error)
    }
}

// MARK: - Encoder

extension ReplayPipeline: VideoEncoderDelegate {
    func videoEncoder(_ encoder: VideoEncoder,
                      didEncode bytes: UnsafeRawBufferPointer,
                      pts: CMTime,
                      decodeTime: CMTime,
                      duration: CMTime,
                      isSync: Bool,
                      formatDescription: CMFormatDescription) {
        buffer.appendVideo(bytes: bytes, pts: pts, decodeTime: decodeTime,
                           duration: duration, isSync: isSync,
                           formatDescription: formatDescription)
    }

    func videoEncoder(_ encoder: VideoEncoder, didFail error: KaijuError) {
        onError?(error)
    }
}

// MARK: - Audio

extension ReplayPipeline: AudioMixerDelegate {
    func audioMixer(_ mixer: AudioMixer,
                    didProduce samples: UnsafePointer<Float>,
                    frameCount: Int,
                    pts: CMTime,
                    track: AudioTrackKind) {
        buffer.appendAudio(samples: samples, frameCount: frameCount,
                           pts: pts, track: track, format: mixer.outputFormat)
    }
}

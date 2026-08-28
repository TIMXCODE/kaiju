import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AVFoundation
import QuartzCore

public enum AudioSourceKind: String, Sendable, Hashable {
    case system
    case microphone
}

public protocol CaptureEngineDelegate: AnyObject {
    /// Called on the capture engine's video queue. Do not block: whatever this
    /// does happens between two frames of the user's game.
    func captureEngine(_ engine: ScreenCaptureEngine,
                       didOutputVideoFrame pixelBuffer: CVPixelBuffer,
                       presentationTime: CMTime)

    /// Called on the capture engine's audio queue.
    func captureEngine(_ engine: ScreenCaptureEngine,
                       didOutputAudio sampleBuffer: CMSampleBuffer,
                       from source: AudioSourceKind)

    func captureEngine(_ engine: ScreenCaptureEngine, didFail error: KaijuError)
}

/// Owns the `SCStream`. Its only job is to hand out timestamped frames and audio;
/// it knows nothing about buffers, clips or the UI.
public final class ScreenCaptureEngine: NSObject, @unchecked Sendable {

    public struct StartRequest {
        public var filter: SCContentFilter
        public var sourcePixelSize: CGSize
        public var recording: RecordingConfiguration
        public var audio: AudioConfiguration
        public var sourceLabel: String

        public init(filter: SCContentFilter,
                    sourcePixelSize: CGSize,
                    recording: RecordingConfiguration,
                    audio: AudioConfiguration,
                    sourceLabel: String) {
            self.filter = filter
            self.sourcePixelSize = sourcePixelSize
            self.recording = recording
            self.audio = audio
            self.sourceLabel = sourceLabel
        }
    }

    public weak var delegate: CaptureEngineDelegate?

    private let videoQueue = DispatchQueue(label: "com.mac.Kaiju.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.mac.Kaiju.capture.audio", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "com.mac.Kaiju.capture.control")

    private var stream: SCStream?
    private let statistics = CaptureStatistics()
    private var currentRequest: StartRequest?
    private var encodeSize: CGSize = .zero

    /// Frames handed to the delegate but not yet acknowledged. When this climbs,
    /// the encoder is behind and we drop rather than let latency (and memory) grow.
    private let inFlight = Guarded(0)
    private let lastEncoderOutput = Guarded<CFTimeInterval>(0)
    private let maxInFlightFrames = 4

    public private(set) var isRunning = false

    public override init() { super.init() }

    public var stats: CaptureStatisticsSnapshot { statistics.current }
    public var currentEncodeSize: CGSize { encodeSize }
    public var sourceLabel: String { currentRequest?.sourceLabel ?? "—" }

    // MARK: - Lifecycle

    public func start(_ request: StartRequest) async throws {
        if isRunning { await stop() }

        let size = request.recording.resolution.encodeSize(forSource: request.sourcePixelSize)
        guard size.width >= 2, size.height >= 2,
              size.width <= 8192, size.height <= 8192 else {
            throw KaijuError.unsupportedResolution(width: Int(size.width), height: Int(size.height))
        }
        encodeSize = size

        let configuration = makeConfiguration(request: request, encodeSize: size)
        let stream = SCStream(filter: request.filter, configuration: configuration, delegate: self)

        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if request.audio.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            if request.audio.captureMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            }
            try await stream.startCapture()
        } catch {
            throw Self.translate(error)
        }

        self.stream = stream
        self.currentRequest = request
        self.isRunning = true
        statistics.begin(width: Int(size.width), height: Int(size.height))
        inFlight.withLock { $0 = 0 }
        KaijuLog.capture.notice("Capture started — \(Int(size.width))×\(Int(size.height)) @ \(request.recording.frameRate.rawValue) fps from \(request.sourceLabel, privacy: .public)")
    }

    public func stop() async {
        guard let stream else {
            isRunning = false
            return
        }
        self.stream = nil
        isRunning = false
        statistics.end()
        do {
            try await stream.stopCapture()
        } catch {
            // Stopping an already-stopped stream throws; that isn't worth surfacing.
            KaijuLog.capture.debug("stopCapture: \(String(describing: error))")
        }
        KaijuLog.capture.notice("Capture stopped.")
    }

    /// Applies new recording settings without tearing the stream down, so the
    /// replay buffer keeps its history when you nudge the bitrate mid-session.
    public func updateConfiguration(recording: RecordingConfiguration,
                                    audio: AudioConfiguration) async throws {
        guard let stream, var request = currentRequest else { return }
        request.recording = recording
        request.audio = audio

        let size = recording.resolution.encodeSize(forSource: request.sourcePixelSize)
        encodeSize = size
        let configuration = makeConfiguration(request: request, encodeSize: size)
        do {
            try await stream.updateConfiguration(configuration)
            currentRequest = request
            statistics.updateSize(width: Int(size.width), height: Int(size.height))
        } catch {
            throw Self.translate(error)
        }
    }

    public func updateContentFilter(_ filter: SCContentFilter,
                                    sourcePixelSize: CGSize,
                                    label: String) async throws {
        guard let stream, var request = currentRequest else { return }
        do {
            try await stream.updateContentFilter(filter)
            request.filter = filter
            request.sourcePixelSize = sourcePixelSize
            request.sourceLabel = label
            currentRequest = request
        } catch {
            throw Self.translate(error)
        }
    }

    /// The encoder calls this when it finishes with a frame, releasing back-pressure.
    public func frameCompleted() {
        inFlight.withLock { $0 = max(0, $0 - 1) }
        lastEncoderOutput.withLock { $0 = CACurrentMediaTime() }
    }

    public func refreshStaleness() {
        statistics.decayIfStale()
        // Safety valve: if the encoder went quiet without reporting back, don't
        // let a stuck counter wedge capture forever.
        let last = lastEncoderOutput.current
        if last > 0, CACurrentMediaTime() - last > 1.5 {
            inFlight.withLock { $0 = 0 }
        }
    }

    // MARK: - Configuration

    private func makeConfiguration(request: StartRequest, encodeSize: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(encodeSize.width)
        config.height = Int(encodeSize.height)
        config.minimumFrameInterval = request.recording.frameRate.minimumFrameInterval
        config.showsCursor = request.recording.showsCursor
        config.scalesToFit = true
        config.preservesAspectRatio = true

        // Bi-planar 4:2:0 video range is what the hardware encoder wants natively.
        // Asking SCK for it means no colour conversion pass between capture and
        // encode — measurable on integrated GPUs at 4K.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.backgroundColor = CGColor.black

        config.capturesAudio = request.audio.captureSystemAudio
        config.sampleRate = Int(request.audio.sampleRate)
        config.channelCount = request.audio.channelCount
        // Kaiju's own notification sounds should never end up inside a clip.
        config.excludesCurrentProcessAudio = true

        config.captureMicrophone = request.audio.captureMicrophone
        if let deviceID = request.audio.microphoneDeviceID, !deviceID.isEmpty {
            config.microphoneCaptureDeviceID = deviceID
        }

        return config
    }

    private static func translate(_ error: Error) -> KaijuError {
        let nsError = error as NSError
        // SCStreamErrorDomain -3801 is "user declined", which in practice means
        // the screen-recording grant is missing or was revoked.
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801: return .screenRecordingPermissionDenied
            case -3802, -3808: return .captureSourceDisappeared(name: "the selected source")
            default: break
            }
        }
        if !CGPreflightScreenCaptureAccess() {
            return .screenRecordingPermissionDenied
        }
        return .captureStartFailed(reason: nsError.localizedDescription)
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureEngine: SCStreamOutput {
    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer, source: .system)
        case .microphone:
            handleAudio(sampleBuffer, source: .microphone)
        @unknown default:
            break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        // ScreenCaptureKit sends a frame on every vsync whether or not anything
        // changed. Only `.complete` frames carry new pixels; encoding the rest
        // would burn power and bitrate for an identical picture.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusValue = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue) else {
            return
        }

        guard status == .complete else {
            statistics.recordIdleFrame()
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pending = inFlight.withLock { value -> Int in
            value += 1
            return value
        }
        guard pending <= maxInFlightFrames else {
            inFlight.withLock { $0 = max(0, $0 - 1) }
            statistics.recordDroppedFrame()
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        statistics.recordFrame(at: pts)
        delegate?.captureEngine(self, didOutputVideoFrame: pixelBuffer, presentationTime: pts)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer, source: AudioSourceKind) {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        statistics.recordAudio(source)
        delegate?.captureEngine(self, didOutputAudio: sampleBuffer, from: source)
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureEngine: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.stream = nil
            self.statistics.end()
            let nsError = error as NSError
            let translated: KaijuError
            if nsError.domain == SCStreamErrorDomain, nsError.code == -3802 || nsError.code == -3808 {
                translated = .captureSourceDisappeared(name: self.sourceLabel)
            } else {
                translated = .captureStoppedUnexpectedly(reason: nsError.localizedDescription)
            }
            KaijuLog.capture.error("Stream stopped: \(nsError.domain) \(nsError.code) — \(nsError.localizedDescription, privacy: .public)")
            self.delegate?.captureEngine(self, didFail: translated)
        }
    }
}

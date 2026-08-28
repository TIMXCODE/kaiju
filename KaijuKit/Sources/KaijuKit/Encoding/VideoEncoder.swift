import Foundation
import QuartzCore
import VideoToolbox
import CoreMedia
import CoreVideo

public struct VideoEncoderConfiguration: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var codec: VideoCodecOption
    public var bitrate: Int
    public var frameRate: Int
    public var keyframeIntervalSeconds: Double
    public var requireHardware: Bool

    public init(width: Int, height: Int, codec: VideoCodecOption, bitrate: Int,
                frameRate: Int, keyframeIntervalSeconds: Double, requireHardware: Bool) {
        self.width = width
        self.height = height
        self.codec = codec
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.requireHardware = requireHardware
    }

    public static func make(recording: RecordingConfiguration, encodeSize: CGSize) -> VideoEncoderConfiguration {
        let width = Int(encodeSize.width)
        let height = Int(encodeSize.height)
        return VideoEncoderConfiguration(
            width: width,
            height: height,
            codec: recording.codec,
            bitrate: recording.bitrate(width: width, height: height),
            frameRate: recording.frameRate.rawValue,
            keyframeIntervalSeconds: recording.keyframeIntervalSeconds,
            requireHardware: recording.requireHardwareEncoder)
    }
}

public protocol VideoEncoderDelegate: AnyObject {
    /// Handed the encoder's own memory. Copy what you need before returning —
    /// the pointer is only valid for the duration of the call. Deliberately not
    /// a `Data`, so the replay ring can memcpy straight into its arena and the
    /// hot path allocates nothing at all.
    func videoEncoder(_ encoder: VideoEncoder,
                      didEncode bytes: UnsafeRawBufferPointer,
                      pts: CMTime,
                      decodeTime: CMTime,
                      duration: CMTime,
                      isSync: Bool,
                      formatDescription: CMFormatDescription)

    func videoEncoder(_ encoder: VideoEncoder, didFail error: KaijuError)
}

/// Hardware H.264/HEVC encoding through VideoToolbox.
///
/// Runs in real-time, low-latency mode with frame reordering off. No B-frames
/// means presentation order equals decode order, which is what lets the replay
/// buffer slice a clip out of the middle of the stream without re-encoding
/// anything.
public final class VideoEncoder: @unchecked Sendable {
    public weak var delegate: VideoEncoderDelegate?

    private var session: VTCompressionSession?
    private var configuration: VideoEncoderConfiguration?
    private let lock = UnfairLock()

    /// Scratch space for the rare non-contiguous block buffer. Allocated once and
    /// grown only if a frame ever needs more, so steady state does no allocation.
    private var scratch = [UInt8]()

    private var forceNextKeyframe = true
    private var frameCounter: Int64 = 0

    /// Called for every frame VideoToolbox finishes with, including ones it chose
    /// to drop. The capture engine uses this to release back-pressure.
    public var onFrameProcessed: (() -> Void)?

    public private(set) var isUsingHardwareEncoder = false
    public private(set) var droppedFrameCount: Int = 0
    public private(set) var encodedFrameCount: Int = 0
    public private(set) var encodedByteCount: Int = 0
    /// Rolling measured output bitrate in bits per second.
    public private(set) var measuredBitrate: Double = 0
    private var bitrateWindowStart = CACurrentMediaTime()
    private var bitrateWindowBytes = 0

    public init() {}

    deinit { teardown() }

    public var isRunning: Bool { session != nil }
    public var activeConfiguration: VideoEncoderConfiguration? { configuration }

    // MARK: - Lifecycle

    public func start(_ configuration: VideoEncoderConfiguration) throws {
        teardown()

        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        if configuration.requireHardware {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        }

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: configuration.codec.codecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)

        guard status == noErr, let session = created else {
            if configuration.requireHardware {
                throw KaijuError.encoderUnavailable(codec: configuration.codec.displayName)
            }
            throw KaijuError.encoderFailed(status: status, stage: "session creation")
        }

        apply(configuration, to: session)
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
        self.configuration = configuration
        self.forceNextKeyframe = true
        self.frameCounter = 0
        self.encodedFrameCount = 0
        self.encodedByteCount = 0
        self.droppedFrameCount = 0
        self.bitrateWindowStart = CACurrentMediaTime()
        self.bitrateWindowBytes = 0
        self.isUsingHardwareEncoder = Self.readHardwareFlag(session)

        KaijuLog.encoder.notice("Encoder up — \(configuration.codec.displayName, privacy: .public) \(configuration.width)×\(configuration.height) @ \(configuration.frameRate) fps, \(configuration.bitrate / 1_000_000) Mbps, hardware: \(self.isUsingHardwareEncoder)")
    }

    private func apply(_ configuration: VideoEncoderConfiguration, to session: VTCompressionSession) {
        func set(_ key: CFString, _ value: CFTypeRef?) {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                // Not every property exists on every encoder; a rejected optimisation
                // is not a reason to fail the session.
                KaijuLog.encoder.debug("Encoder property \(key as String, privacy: .public) rejected (\(status)).")
            }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        // No B-frames: presentation order == decode order, which keeps clip
        // extraction from the ring a straight slice.
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: configuration.frameRate))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: configuration.bitrate))

        let keyframeInterval = max(1, Int(Double(configuration.frameRate) * configuration.keyframeIntervalSeconds))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeInterval))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: configuration.keyframeIntervalSeconds))

        // A hard ceiling at 1.5× average over a one-second window keeps a sudden
        // explosion of on-screen motion from spiking the file size.
        let peakBytesPerSecond = Int(Double(configuration.bitrate) * 1.5 / 8.0)
        set(kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: peakBytesPerSecond), NSNumber(value: 1.0)] as CFArray)

        switch configuration.codec {
        case .h264:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        case .hevc:
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }

        // The two properties that matter most for staying out of a game's way.
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
    }

    private static func readHardwareFlag(_ session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: kCFAllocatorDefault,
            valueOut: &value)
        guard status == noErr else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        return false
    }

    public func teardown() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        configuration = nil
    }

    /// Flushes pending frames without destroying the session. Used before saving
    /// a clip so the last frames the user actually saw are in the buffer.
    public func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    public func requestKeyframe() {
        lock.withLock { forceNextKeyframe = true }
    }

    /// Applies a new bitrate to the running session. Cheap — no session restart,
    /// so the replay buffer isn't interrupted.
    public func updateBitrate(_ bitrate: Int) {
        guard let session else { return }
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: NSNumber(value: bitrate))
        let peak = Int(Double(bitrate) * 1.5 / 8.0)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: [NSNumber(value: peak), NSNumber(value: 1.0)] as CFArray)
        configuration?.bitrate = bitrate
    }

    // MARK: - Encoding

    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session, let configuration else { return }

        var frameProperties: CFDictionary?
        let shouldForce = lock.withLock { () -> Bool in
            if forceNextKeyframe { forceNextKeyframe = false; return true }
            return false
        }
        if shouldForce {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            self?.handleEncoded(status: status, flags: flags, sampleBuffer: sampleBuffer)
        }

        if status != noErr {
            delegate?.videoEncoder(self, didFail: .encoderFailed(status: status, stage: "encode"))
        }
    }

    private func handleEncoded(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        // Fires whatever the outcome, so back-pressure is always released.
        onFrameProcessed?()

        guard status == noErr else {
            delegate?.videoEncoder(self, didFail: .encoderFailed(status: status, stage: "output"))
            return
        }
        // The encoder is allowed to drop a frame under load; that's it doing its
        // job, not an error. It gets counted, not reported.
        if flags.contains(.frameDropped) {
            lock.withLock { droppedFrameCount += 1 }
            return
        }
        guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        if !dts.isValid { dts = pts }
        var duration = CMSampleBufferGetDuration(sampleBuffer)
        if !duration.isValid || duration.value == 0,
           let frameRate = configuration?.frameRate {
            duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        }

        let isSync = Self.isSyncSample(sampleBuffer)

        var totalLength = 0
        var lengthAtOffset = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let accessStatus = CMBlockBufferGetDataPointer(blockBuffer,
                                                       atOffset: 0,
                                                       lengthAtOffsetOut: &lengthAtOffset,
                                                       totalLengthOut: &totalLength,
                                                       dataPointerOut: &dataPointer)
        guard accessStatus == kCMBlockBufferNoErr, totalLength > 0 else { return }

        recordOutput(bytes: totalLength)

        if lengthAtOffset >= totalLength, let dataPointer {
            let buffer = UnsafeRawBufferPointer(start: dataPointer, count: totalLength)
            delegate?.videoEncoder(self, didEncode: buffer, pts: pts, decodeTime: dts,
                                   duration: duration, isSync: isSync,
                                   formatDescription: formatDescription)
        } else {
            // Non-contiguous block buffer: flatten into reusable scratch space.
            if scratch.count < totalLength { scratch = [UInt8](repeating: 0, count: totalLength) }
            let copyStatus = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                                  dataLength: totalLength,
                                                  destination: base)
            }
            guard copyStatus == kCMBlockBufferNoErr else { return }
            scratch.withUnsafeBytes { raw in
                let slice = UnsafeRawBufferPointer(rebasing: raw[0..<totalLength])
                delegate?.videoEncoder(self, didEncode: slice, pts: pts, decodeTime: dts,
                                       duration: duration, isSync: isSync,
                                       formatDescription: formatDescription)
            }
        }
    }

    private func recordOutput(bytes: Int) {
        lock.withLock {
            encodedFrameCount += 1
            encodedByteCount += bytes
            bitrateWindowBytes += bytes
            let now = CACurrentMediaTime()
            let elapsed = now - bitrateWindowStart
            if elapsed >= 1.0 {
                measuredBitrate = Double(bitrateWindowBytes) * 8.0 / elapsed
                bitrateWindowBytes = 0
                bitrateWindowStart = now
            }
        }
    }

    private static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            // No attachments at all means "not marked as non-sync", i.e. a keyframe.
            return true
        }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? NSNumber { return !notSync.boolValue }
        return true
    }
}

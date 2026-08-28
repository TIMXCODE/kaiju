import Foundation
import AVFoundation
import CoreMedia

/// Normalises whatever ScreenCaptureKit hands us into one canonical PCM shape:
/// 32-bit float, interleaved, stereo, at the configured sample rate.
///
/// System audio and microphone audio can arrive with different channel counts and
/// layouts. Everything downstream — the mixer, the level meters, the ring — gets
/// to assume one format because of this class.
///
/// The API is closure-based on purpose: the float pointer usually belongs to the
/// sample buffer's block buffer, and scoping it to a callback is what guarantees
/// that memory is still alive while it's read.
final class AudioSampleConverter {
    let outputFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    /// Reused across calls so steady-state conversion allocates nothing.
    private var scratchOutput: AVAudioPCMBuffer?

    init?(sampleRate: Double, channels: Int) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(max(1, channels)),
                                         interleaved: true) else { return nil }
        self.outputFormat = format
    }

    var sampleRate: Double { outputFormat.sampleRate }
    var channelCount: Int { Int(outputFormat.channelCount) }

    /// Converts and yields interleaved float frames. Returns false when the buffer
    /// couldn't be interpreted.
    @discardableResult
    func withConvertedSamples(from sampleBuffer: CMSampleBuffer,
                              _ body: (UnsafePointer<Float>, Int, CMTime) -> Void) -> Bool {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return false
        }
        var asbd = asbdPointer.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return false }

        let inputFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard inputFrames > 0 else { return false }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var sizeNeeded = 0
        var probeBlockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: &sizeNeeded,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &probeBlockBuffer) == noErr,
              sizeNeeded >= MemoryLayout<AudioBufferList>.size else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: listPointer,
                bufferListSize: sizeNeeded,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer) == noErr else { return false }

        var handled = false
        // The block buffer owns the sample memory; hold it for the whole read.
        withExtendedLifetime(blockBuffer) {
            guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                               bufferListNoCopy: listPointer) else { return }
            input.frameLength = AVAudioFrameCount(inputFrames)
            handled = render(input, pts: pts, body)
        }
        return handled
    }

    private func render(_ input: AVAudioPCMBuffer,
                        pts: CMTime,
                        _ body: (UnsafePointer<Float>, Int, CMTime) -> Void) -> Bool {
        // Already exactly what we want? Read the input's own memory, no copy.
        if input.format.sampleRate == outputFormat.sampleRate,
           input.format.channelCount == outputFormat.channelCount,
           input.format.commonFormat == .pcmFormatFloat32,
           input.format.isInterleaved,
           let data = input.floatChannelData {
            body(UnsafePointer(data[0]), Int(input.frameLength), pts)
            return true
        }

        if cachedInputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            cachedInputFormat = input.format
            scratchOutput = nil
        }
        guard let converter else { return false }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up) + 64)
        if scratchOutput == nil || scratchOutput!.frameCapacity < capacity {
            scratchOutput = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let output = scratchOutput else { return false }
        output.frameLength = 0

        if input.format.sampleRate == outputFormat.sampleRate {
            do {
                try converter.convert(to: output, from: input)
            } catch {
                KaijuLog.audio.error("Audio conversion failed: \(String(describing: error))")
                return false
            }
        } else {
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error {
                KaijuLog.audio.error("Sample-rate conversion failed: \(String(describing: conversionError))")
                return false
            }
        }

        guard output.frameLength > 0, let data = output.floatChannelData else { return false }
        body(UnsafePointer(data[0]), Int(output.frameLength), pts)
        return true
    }
}

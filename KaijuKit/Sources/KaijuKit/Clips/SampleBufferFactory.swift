import Foundation
import CoreMedia
import AVFoundation

/// Rebuilds `CMSampleBuffer`s from the flat bytes the replay ring holds.
///
/// The ring deliberately stores raw bytes plus timing rather than retaining
/// `CMSampleBuffer` objects: holding thousands of live sample buffers would pin
/// the encoder's own pixel/block pools and eventually stall it. Rehydrating here,
/// only for the frames a clip actually needs, keeps the buffer cheap and the
/// writer happy.
enum SampleBufferFactory {

    static func makeBlockBuffer(from pointer: UnsafeRawPointer, length: Int) -> CMBlockBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = CMBlockBufferReplaceDataBytes(with: pointer,
                                               blockBuffer: blockBuffer,
                                               offsetIntoDestination: 0,
                                               dataLength: length)
        guard status == kCMBlockBufferNoErr else { return nil }
        return blockBuffer
    }

    /// Compressed video sample, ready to hand to a pass-through writer input.
    static func makeVideoSampleBuffer(pointer: UnsafeRawPointer,
                                      length: Int,
                                      pts: CMTime,
                                      decodeTime: CMTime,
                                      duration: CMTime,
                                      isSync: Bool,
                                      formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        guard let blockBuffer = makeBlockBuffer(from: pointer, length: length) else { return nil }

        var timing = CMSampleTimingInfo(duration: duration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: decodeTime)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        if !isSync { markNotSync(sampleBuffer) }
        return sampleBuffer
    }

    /// Interleaved float PCM sample, ready for an AAC-configured writer input.
    static func makeAudioSampleBuffer(pointer: UnsafeRawPointer,
                                      byteLength: Int,
                                      frameCount: Int,
                                      pts: CMTime,
                                      formatDescription: CMFormatDescription,
                                      bytesPerFrame: Int) -> CMSampleBuffer? {
        guard frameCount > 0, bytesPerFrame > 0 else { return nil }
        guard let blockBuffer = makeBlockBuffer(from: pointer, length: byteLength) else { return nil }

        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.pointee.mSampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    static func makeAudioFormatDescription(from format: AVAudioFormat) -> CMFormatDescription? {
        var asbd = format.streamDescription.pointee
        var formatDescription: CMFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd,
                                                    layoutSize: 0,
                                                    layout: nil,
                                                    magicCookieSize: 0,
                                                    magicCookie: nil,
                                                    extensions: nil,
                                                    formatDescriptionOut: &formatDescription)
        guard status == noErr else { return nil }
        return formatDescription
    }

    /// Shifts a sample buffer's timeline so the clip starts at zero.
    static func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }

        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: &count) == noErr else { return nil }

        for index in 0..<timings.count {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp =
                    CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp =
                    CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }

        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sampleBuffer,
                                                           sampleTimingEntryCount: timings.count,
                                                           sampleTimingArray: &timings,
                                                           sampleBufferOut: &output)
        guard status == noErr else { return nil }
        return output
    }

    private static func markNotSync(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue!).toOpaque())
    }
}

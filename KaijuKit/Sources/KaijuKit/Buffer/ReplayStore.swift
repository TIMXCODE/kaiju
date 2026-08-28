import Foundation
import CoreMedia
import AVFoundation

/// One encoded sample's metadata, pointing into a snapshot's contiguous byte blob.
public struct SampleRecord: Sendable, Equatable {
    public var offset: Int
    public var length: Int
    public var pts: CMTime
    public var decodeTime: CMTime
    public var duration: CMTime
    public var isSync: Bool

    public init(offset: Int, length: Int, pts: CMTime, decodeTime: CMTime,
                duration: CMTime, isSync: Bool) {
        self.offset = offset
        self.length = length
        self.pts = pts
        self.decodeTime = decodeTime
        self.duration = duration
        self.isSync = isSync
    }
}

public struct AudioTrackSnapshot {
    public var kind: AudioTrackKind
    public var data: Data
    public var records: [SampleRecord]
    public var format: AVAudioFormat

    public init(kind: AudioTrackKind, data: Data, records: [SampleRecord], format: AVAudioFormat) {
        self.kind = kind
        self.data = data
        self.records = records
        self.format = format
    }
}

/// Everything needed to write one clip, detached from the live buffer.
///
/// Taking a snapshot is a copy, not a handoff: the ring keeps running and keeps
/// overwriting, which is what lets you save five clips in a row without the
/// buffer ever stopping.
/// One finalised on-disk segment plus where it sits on the global capture timeline.
public struct SegmentEntry: Sendable {
    public let url: URL
    /// Global presentation time of this segment's first frame. Timestamps inside
    /// the file itself start at zero.
    public let start: CMTime
    public let end: CMTime

    public init(url: URL, start: CMTime, end: CMTime) {
        self.url = url
        self.start = start
        self.end = end
    }

    public var duration: CMTime { CMTimeSubtract(end, start) }
}

public final class ReplaySnapshot {
    public enum Source {
        /// Compressed video plus PCM audio lifted straight out of the in-memory ring.
        case memory(videoData: Data,
                    videoRecords: [SampleRecord],
                    videoFormat: CMFormatDescription,
                    audioTracks: [AudioTrackSnapshot])
        /// Completed on-disk segments that together cover the requested range.
        case segments(entries: [SegmentEntry])
    }

    public let source: Source
    /// First sample actually included. May be slightly before `requestedStart`
    /// because clips are cut at a keyframe rather than re-encoded.
    public let actualStart: CMTime
    public let requestedStart: CMTime
    public let endTime: CMTime
    public let encodeSize: CGSize
    public let frameRate: Int

    public init(source: Source, actualStart: CMTime, requestedStart: CMTime,
                endTime: CMTime, encodeSize: CGSize, frameRate: Int) {
        self.source = source
        self.actualStart = actualStart
        self.requestedStart = requestedStart
        self.endTime = endTime
        self.encodeSize = encodeSize
        self.frameRate = frameRate
    }

    public var duration: TimeInterval {
        max(0, CMTimeGetSeconds(CMTimeSubtract(endTime, actualStart)))
    }

    /// Called once the clip has been written. The disk backend uses this to
    /// unpin the segments it held open, letting the ring recycle them again.
    public var onRelease: (() -> Void)?

    deinit { onRelease?() }

    public var byteCount: Int {
        switch source {
        case .memory(let videoData, _, _, let audioTracks):
            return videoData.count + audioTracks.reduce(0) { $0 + $1.data.count }
        case .segments(let entries):
            return entries.reduce(0) { total, entry in
                let size = (try? entry.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total + size
            }
        }
    }
}

public struct ReplayStoreStatus: Sendable, Equatable {
    public var bufferedSeconds: TimeInterval = 0
    public var capacitySeconds: TimeInterval = 0
    public var memoryBytes: Int = 0
    public var diskBytes: Int = 0
    public var videoSampleCount: Int = 0
    public var isDiskBacked: Bool = false
    public var droppedForOverflow: Int = 0

    public var fillFraction: Double {
        guard capacitySeconds > 0 else { return 0 }
        return min(1, bufferedSeconds / capacitySeconds)
    }
}

/// What the replay buffer needs from a storage backend. Two implementations:
/// RAM for the short durations people actually use, disk segments for long ones.
protocol ReplayStore: AnyObject {
    func appendVideo(bytes: UnsafeRawBufferPointer,
                     pts: CMTime,
                     decodeTime: CMTime,
                     duration: CMTime,
                     isSync: Bool,
                     formatDescription: CMFormatDescription)

    func appendAudio(samples: UnsafePointer<Float>,
                     frameCount: Int,
                     pts: CMTime,
                     track: AudioTrackKind,
                     format: AVAudioFormat)

    /// Cut the last `duration` seconds out without disturbing ingest.
    func snapshot(duration: TimeInterval) throws -> ReplaySnapshot

    var status: ReplayStoreStatus { get }
    func reset()
    func shutdown()
}

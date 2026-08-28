import Foundation
import AVFoundation
import CoreMedia

/// Walks a run of on-disk replay segments as one continuous sample stream.
///
/// Used when the buffer is disk-backed. Everything is pass-through: samples come
/// out of the segment files already encoded and go straight into the clip, so
/// stitching half an hour of history into a 30-second clip costs a copy, not a
/// re-encode.
final class SegmentSampleProvider {
    private let entries: [SegmentEntry]
    private let mediaType: AVMediaType
    private let trackIndex: Int
    private let clipStart: CMTime
    private let clipEnd: CMTime

    private var readers: [(reader: AVAssetReader, output: AVAssetReaderTrackOutput, offset: CMTime)] = []
    private var cursor = 0
    private(set) var formatDescription: CMFormatDescription?

    init(entries: [SegmentEntry], mediaType: AVMediaType, trackIndex: Int,
         clipStart: CMTime, clipEnd: CMTime) {
        self.entries = entries
        self.mediaType = mediaType
        self.trackIndex = trackIndex
        self.clipStart = clipStart
        self.clipEnd = clipEnd
    }

    /// Opens every segment and works out which slice of each one the clip needs.
    /// Returns false when this media type isn't present at all (for instance a
    /// microphone track in a session recorded without a mic).
    func prepare() async throws -> Bool {
        for entry in entries {
            let asset = AVURLAsset(url: entry.url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: mediaType)
            } catch {
                continue
            }
            guard trackIndex < tracks.count else { continue }
            let track = tracks[trackIndex]

            if formatDescription == nil {
                let descriptions = try? await track.load(.formatDescriptions)
                formatDescription = descriptions?.first
            }

            let segmentDuration = try? await asset.load(.duration)
            let localDuration = segmentDuration ?? CMTimeSubtract(entry.end, entry.start)

            // Where this segment sits inside the clip's own timeline.
            let offset = CMTimeSubtract(entry.start, clipStart)
            var localStart = CMTimeSubtract(clipStart, entry.start)
            if localStart < .zero { localStart = .zero }
            var localEnd = CMTimeSubtract(clipEnd, entry.start)
            if localEnd > localDuration { localEnd = localDuration }
            guard localEnd > localStart else { continue }

            do {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: localStart,
                                               duration: CMTimeSubtract(localEnd, localStart))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { continue }
                reader.add(output)
                guard reader.startReading() else { continue }
                readers.append((reader, output, offset))
            } catch {
                KaijuLog.clips.error("Couldn't open segment \(entry.url.lastPathComponent, privacy: .public): \(String(describing: error))")
                continue
            }
        }
        return !readers.isEmpty
    }

    /// Next sample, already retimed onto the clip's timeline (starting at zero).
    func next() -> CMSampleBuffer? {
        while cursor < readers.count {
            let entry = readers[cursor]
            if let sample = entry.output.copyNextSampleBuffer() {
                // `retime(by:)` subtracts, and `offset` is how far this segment sits
                // *into* the clip, so negate it to shift forward.
                let shift = CMTimeMultiply(entry.offset, multiplier: -1)
                guard let retimed = SampleBufferFactory.retime(sample, by: shift) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(retimed)
                if pts >= CMTimeSubtract(clipEnd, clipStart) { cursor = readers.count; return nil }
                return retimed
            }
            entry.reader.cancelReading()
            cursor += 1
        }
        return nil
    }

    func cancel() {
        for entry in readers where entry.reader.status == .reading {
            entry.reader.cancelReading()
        }
    }
}

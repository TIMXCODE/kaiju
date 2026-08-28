import Foundation
import CoreMedia
import CoreGraphics
import AVFoundation

/// The default replay backend: compressed video and PCM audio held in fixed-size
/// circular arenas.
///
/// Why this shape:
/// * Video is stored **already encoded**, so saving a clip is a copy and a mux,
///   not an encode. Pressing the hotkey produces a file in well under a second
///   regardless of how long the clip is.
/// * Audio is stored as **raw PCM** and compressed only when a clip is written.
///   At 48 kHz stereo that's 384 KB/s against video's ~2.5 MB/s — a rounding
///   error — and it removes a whole real-time AAC encoder from the hot path.
/// * Both arenas are allocated once. A six-hour session touches the same bytes
///   over and over, so resident memory is flat by construction rather than by
///   hoping the allocator behaves.
final class MemoryReplayStore: ReplayStore {

    struct Configuration {
        var retainSeconds: TimeInterval
        var estimatedVideoBitrate: Int
        var sampleRate: Double
        var channelCount: Int
        var separateTracks: Bool
        var memoryBudgetBytes: Int
        var encodeSize: CGSize
        var frameRate: Int
        /// Extra history kept beyond the requested duration so there is always a
        /// keyframe at or before the start of any clip we're asked for.
        var keyframeSlackSeconds: TimeInterval = 2.5
    }

    private struct VideoEntry {
        var absoluteOffset: Int
        var length: Int
        var pts: CMTime
        var decodeTime: CMTime
        var duration: CMTime
        var isSync: Bool
    }

    private struct AudioEntry {
        var absoluteOffset: Int
        var byteLength: Int
        var frameCount: Int
        var pts: CMTime
    }

    private final class AudioTrackBuffer {
        let ring: ByteRing
        var entries = RecordDeque<AudioEntry>()
        var format: AVAudioFormat?
        init(capacity: Int) { ring = ByteRing(capacity: capacity) }
    }

    private let configuration: Configuration
    private let lock = UnfairLock()

    private let videoRing: ByteRing
    private var videoEntries = RecordDeque<VideoEntry>()
    private var videoFormat: CMFormatDescription?
    private var audioTracks: [AudioTrackKind: AudioTrackBuffer] = [:]
    private var overflowDrops = 0

    private var totalRetainSeconds: TimeInterval {
        configuration.retainSeconds + configuration.keyframeSlackSeconds
    }

    init(configuration: Configuration) {
        self.configuration = configuration

        let sizing = Self.sizing(for: configuration)
        self.videoRing = ByteRing(capacity: sizing.videoBytes)

        let kinds: [AudioTrackKind] = configuration.separateTracks ? [.system, .microphone] : [.mixed]
        for kind in kinds {
            audioTracks[kind] = AudioTrackBuffer(capacity: sizing.audioBytesPerTrack)
        }

        KaijuLog.buffer.notice("Memory replay store: \(sizing.videoBytes / 1_048_576) MB video + \(kinds.count) × \(sizing.audioBytesPerTrack / 1_048_576) MB audio for \(Int(configuration.retainSeconds))s")
    }

    // MARK: - Sizing

    struct Sizing {
        var videoBytes: Int
        var audioBytesPerTrack: Int
        var total: Int
    }

    /// Works out how big the arenas need to be, then trims to the user's memory
    /// budget. Exposed so the UI can show what a given setting will actually cost
    /// before you commit to it.
    static func sizing(for configuration: Configuration) -> Sizing {
        let seconds = configuration.retainSeconds + configuration.keyframeSlackSeconds
        let trackCount = configuration.separateTracks ? 2 : 1
        let bytesPerAudioFrame = configuration.channelCount * MemoryLayout<Float>.size
        var audioPerTrack = Int(configuration.sampleRate * seconds) * bytesPerAudioFrame
        audioPerTrack = max(audioPerTrack, 1 << 20)

        // 1.35× the nominal bitrate covers the peak allowance the encoder is
        // configured for, so a burst of motion can't evict good frames early.
        var video = Int(Double(configuration.estimatedVideoBitrate) / 8.0 * seconds * 1.35)
        video = max(video, 8 << 20)

        var total = video + audioPerTrack * trackCount
        if total > configuration.memoryBudgetBytes {
            let audioTotal = audioPerTrack * trackCount
            let available = max(configuration.memoryBudgetBytes - audioTotal, 8 << 20)
            video = available
            total = video + audioTotal
        }
        return Sizing(videoBytes: video, audioBytesPerTrack: audioPerTrack, total: total)
    }

    /// Whether an in-memory ring is a reasonable choice for these settings.
    static func fitsInMemory(configuration: Configuration) -> Bool {
        let seconds = configuration.retainSeconds + configuration.keyframeSlackSeconds
        let trackCount = configuration.separateTracks ? 2 : 1
        let audio = Int(configuration.sampleRate * seconds)
            * configuration.channelCount * MemoryLayout<Float>.size * trackCount
        let video = Int(Double(configuration.estimatedVideoBitrate) / 8.0 * seconds * 1.35)
        return video + audio <= configuration.memoryBudgetBytes
    }

    // MARK: - Ingest

    func appendVideo(bytes: UnsafeRawBufferPointer,
                     pts: CMTime,
                     decodeTime: CMTime,
                     duration: CMTime,
                     isSync: Bool,
                     formatDescription: CMFormatDescription) {
        guard bytes.count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        if videoFormat == nil { videoFormat = formatDescription }

        guard let offset = videoRing.append(bytes) else {
            // One frame bigger than the entire arena means the settings are wrong,
            // not that the frame is bad. Say so once rather than silently dropping.
            overflowDrops += 1
            KaijuLog.buffer.fault("Encoded frame (\(bytes.count) bytes) exceeds the video ring (\(self.videoRing.capacity) bytes).")
            return
        }

        videoEntries.append(VideoEntry(absoluteOffset: offset,
                                       length: bytes.count,
                                       pts: pts,
                                       decodeTime: decodeTime,
                                       duration: duration,
                                       isSync: isSync))
        evictVideo(newest: pts)
    }

    func appendAudio(samples: UnsafePointer<Float>,
                     frameCount: Int,
                     pts: CMTime,
                     track: AudioTrackKind,
                     format: AVAudioFormat) {
        guard frameCount > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        guard let buffer = audioTracks[track] else { return }
        if buffer.format == nil { buffer.format = format }

        let byteLength = frameCount * Int(format.channelCount) * MemoryLayout<Float>.size
        let raw = UnsafeRawBufferPointer(start: samples, count: byteLength)
        guard let offset = buffer.ring.append(raw) else { return }

        buffer.entries.append(AudioEntry(absoluteOffset: offset,
                                         byteLength: byteLength,
                                         frameCount: frameCount,
                                         pts: pts))
        evictAudio(buffer, newest: pts)
    }

    private func evictVideo(newest: CMTime) {
        let limit = totalRetainSeconds
        while let first = videoEntries.first {
            let age = CMTimeGetSeconds(CMTimeSubtract(newest, first.pts))
            if age > limit {
                videoEntries.removeFirst()
                continue
            }
            if !videoRing.contains(absoluteOffset: first.absoluteOffset, length: first.length) {
                videoEntries.removeFirst()
                overflowDrops += 1
                continue
            }
            break
        }
    }

    private func evictAudio(_ buffer: AudioTrackBuffer, newest: CMTime) {
        let limit = totalRetainSeconds
        while let first = buffer.entries.first {
            let age = CMTimeGetSeconds(CMTimeSubtract(newest, first.pts))
            if age > limit {
                buffer.entries.removeFirst()
                continue
            }
            if !buffer.ring.contains(absoluteOffset: first.absoluteOffset, length: first.byteLength) {
                buffer.entries.removeFirst()
                continue
            }
            break
        }
    }

    // MARK: - Snapshot

    func snapshot(duration: TimeInterval) throws -> ReplaySnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard videoEntries.count > 0, let format = videoFormat else {
            throw KaijuError.bufferEmpty
        }
        let newest = videoEntries[videoEntries.count - 1]
        let endTime = CMTimeAdd(newest.pts, newest.duration)
        let oldest = videoEntries[0]
        let available = CMTimeGetSeconds(CMTimeSubtract(endTime, oldest.pts))
        guard available > 0.2 else {
            throw KaijuError.bufferTooShort(available: max(0, available), requested: duration)
        }

        let clipped = min(duration, available)
        let requestedStart = CMTimeSubtract(endTime, KaijuTime.time(seconds: clipped))

        // Clips are cut without re-encoding, so the first frame has to be a
        // keyframe. Walk back to the nearest one — worst case that's one keyframe
        // interval of extra lead-in, which for a replay clip is a feature.
        var startIndex = videoEntries.lastIndex(wherePrefix: { $0.pts <= requestedStart }) ?? 0
        while startIndex > 0 && !videoEntries[startIndex].isSync {
            startIndex -= 1
        }
        if !videoEntries[startIndex].isSync {
            guard let firstSync = firstSyncIndex() else { throw KaijuError.bufferEmpty }
            startIndex = firstSync
        }

        let actualStart = videoEntries[startIndex].pts

        // One allocation for the whole clip's video, then records point into it.
        var totalBytes = 0
        for index in startIndex..<videoEntries.count {
            totalBytes += videoEntries[index].length
        }
        var videoData = Data(count: totalBytes)
        var records: [SampleRecord] = []
        records.reserveCapacity(videoEntries.count - startIndex)

        var writeOffset = 0
        videoData.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in startIndex..<videoEntries.count {
                let entry = videoEntries[index]
                let ok = videoRing.read(absoluteOffset: entry.absoluteOffset,
                                        length: entry.length,
                                        into: base.advanced(by: writeOffset))
                guard ok else { continue }
                records.append(SampleRecord(offset: writeOffset,
                                            length: entry.length,
                                            pts: entry.pts,
                                            decodeTime: entry.decodeTime,
                                            duration: entry.duration,
                                            isSync: entry.isSync))
                writeOffset += entry.length
            }
        }
        guard !records.isEmpty else { throw KaijuError.bufferEmpty }
        if writeOffset < totalBytes { videoData.removeSubrange(writeOffset..<totalBytes) }

        let audioSnapshots = collectAudio(from: actualStart, to: endTime)

        return ReplaySnapshot(
            source: .memory(videoData: videoData,
                            videoRecords: records,
                            videoFormat: format,
                            audioTracks: audioSnapshots),
            actualStart: actualStart,
            requestedStart: requestedStart,
            endTime: endTime,
            encodeSize: configuration.encodeSize,
            frameRate: configuration.frameRate)
    }

    private func firstSyncIndex() -> Int? {
        for index in 0..<videoEntries.count where videoEntries[index].isSync {
            return index
        }
        return nil
    }

    private func collectAudio(from start: CMTime, to end: CMTime) -> [AudioTrackSnapshot] {
        var result: [AudioTrackSnapshot] = []
        for (kind, buffer) in audioTracks {
            guard let format = buffer.format, buffer.entries.count > 0 else { continue }

            var startIndex = buffer.entries.firstIndex(whereSuffix: { $0.pts >= start }) ?? 0
            // Include the chunk straddling the boundary so the clip doesn't open
            // with a sliver of silence.
            if startIndex > 0 { startIndex -= 1 }

            var total = 0
            var indices: [Int] = []
            for index in startIndex..<buffer.entries.count {
                let entry = buffer.entries[index]
                if entry.pts > end { break }
                indices.append(index)
                total += entry.byteLength
            }
            guard total > 0 else { continue }

            var data = Data(count: total)
            var records: [SampleRecord] = []
            records.reserveCapacity(indices.count)
            var writeOffset = 0
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                for index in indices {
                    let entry = buffer.entries[index]
                    let ok = buffer.ring.read(absoluteOffset: entry.absoluteOffset,
                                              length: entry.byteLength,
                                              into: base.advanced(by: writeOffset))
                    guard ok else { continue }
                    let sampleDuration = CMTime(value: Int64(entry.frameCount),
                                                timescale: CMTimeScale(format.sampleRate))
                    records.append(SampleRecord(offset: writeOffset,
                                                length: entry.byteLength,
                                                pts: entry.pts,
                                                decodeTime: entry.pts,
                                                duration: sampleDuration,
                                                isSync: true))
                    writeOffset += entry.byteLength
                }
            }
            guard !records.isEmpty else { continue }
            if writeOffset < total { data.removeSubrange(writeOffset..<total) }
            result.append(AudioTrackSnapshot(kind: kind, data: data, records: records, format: format))
        }
        return result.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    // MARK: - Status

    var status: ReplayStoreStatus {
        lock.withLock {
            var status = ReplayStoreStatus()
            status.capacitySeconds = configuration.retainSeconds
            status.videoSampleCount = videoEntries.count
            status.isDiskBacked = false
            status.droppedForOverflow = overflowDrops
            if videoEntries.count > 1 {
                let first = videoEntries[0].pts
                let last = videoEntries[videoEntries.count - 1]
                status.bufferedSeconds = min(
                    configuration.retainSeconds,
                    max(0, CMTimeGetSeconds(CMTimeSubtract(CMTimeAdd(last.pts, last.duration), first))))
            }
            var memory = videoRing.capacity
            for buffer in audioTracks.values { memory += buffer.ring.capacity }
            status.memoryBytes = memory
            return status
        }
    }

    func reset() {
        lock.withLock {
            videoRing.reset()
            videoEntries.removeAll()
            videoFormat = nil
            overflowDrops = 0
            for buffer in audioTracks.values {
                buffer.ring.reset()
                buffer.entries.removeAll()
            }
        }
    }

    func shutdown() { reset() }
}

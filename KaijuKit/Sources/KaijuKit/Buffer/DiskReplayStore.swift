import Foundation
import CoreMedia
import CoreGraphics
import AVFoundation

/// The replay backend for long buffers.
///
/// Half an hour of 1080p60 is a couple of gigabytes — not something to hold in
/// RAM. So the stream is written as a rotating series of short, self-contained
/// segment files, each starting on a keyframe. Old segments are deleted as they
/// age out, so the folder stays a fixed size instead of growing.
///
/// Two details make this cheap rather than thrashy:
/// * Segment length scales with buffer length (one file every 10–60 s), so a long
///   session creates dozens of files, not thousands.
/// * Saving a clip *pins* the segments it needs. The ring keeps rotating and
///   deleting around them, and the pin lifts when the clip finishes writing —
///   so a save never blocks capture and capture never deletes a file mid-save.
final class DiskReplayStore: ReplayStore {

    struct Configuration {
        var retainSeconds: TimeInterval
        var segmentSeconds: TimeInterval
        var encodeSize: CGSize
        var frameRate: Int
        var sampleRate: Double
        var channelCount: Int
        var separateTracks: Bool
        var audioBitrate: Int
        var directory: URL

        /// Files-per-hour is what stops this being a temp-file firehose: a 30 minute
        /// buffer rotates once a minute, not once every two seconds.
        static func segmentLength(forRetain retainSeconds: TimeInterval) -> TimeInterval {
            min(60, max(10, (retainSeconds / 20).rounded()))
        }
    }

    private final class Segment {
        let url: URL
        let sequence: Int
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInputs: [AudioTrackKind: AVAssetWriterInput] = [:]
        var startPTS: CMTime = .invalid
        var lastPTS: CMTime = .invalid
        var isFinalized = false
        var pinCount = 0

        init(url: URL, sequence: Int) {
            self.url = url
            self.sequence = sequence
        }

        var endPTS: CMTime {
            lastPTS.isValid ? lastPTS : startPTS
        }
    }

    private let configuration: Configuration
    private let writerQueue = DispatchQueue(label: "com.mac.Kaiju.buffer.disk", qos: .userInitiated)
    private let lock = UnfairLock()

    private var segments: [Segment] = []
    private var current: Segment?
    private var sequenceCounter = 0
    private var videoFormat: CMFormatDescription?
    private var audioFormatDescriptions: [AudioTrackKind: CMFormatDescription] = [:]
    private var audioFormats: [AudioTrackKind: AVAudioFormat] = [:]
    private var bytesOnDisk: Int = 0
    private var overflowDrops = 0
    private var isShuttingDown = false

    init(configuration: Configuration) throws {
        self.configuration = configuration
        try FileManager.default.createDirectory(at: configuration.directory,
                                                withIntermediateDirectories: true)
        // Clear anything a previous crash left behind.
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: configuration.directory, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension == "mp4" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        KaijuLog.buffer.notice("Disk replay store at \(configuration.directory.path, privacy: .public) — \(Int(configuration.segmentSeconds))s segments, \(Int(configuration.retainSeconds))s retained")
    }

    // MARK: - Ingest

    func appendVideo(bytes: UnsafeRawBufferPointer,
                     pts: CMTime,
                     decodeTime: CMTime,
                     duration: CMTime,
                     isSync: Bool,
                     formatDescription: CMFormatDescription) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        lock.withLock { if videoFormat == nil { videoFormat = formatDescription } }

        // Copy out of the encoder's memory now; everything after this is async.
        guard let sampleBuffer = SampleBufferFactory.makeVideoSampleBuffer(
                pointer: base,
                length: bytes.count,
                pts: pts,
                decodeTime: decodeTime,
                duration: duration,
                isSync: isSync,
                formatDescription: formatDescription) else { return }

        writerQueue.async { [weak self] in
            self?.handleVideo(sampleBuffer, pts: pts, isSync: isSync,
                              formatDescription: formatDescription)
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer,
                             pts: CMTime,
                             isSync: Bool,
                             formatDescription: CMFormatDescription) {
        guard !isShuttingDown else { return }

        // Rotate only on a keyframe so every segment is independently decodable.
        if let segment = current, segment.startPTS.isValid {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, segment.startPTS))
            if elapsed >= configuration.segmentSeconds && isSync {
                rotate(startingAt: pts, formatDescription: formatDescription)
            }
        } else if isSync {
            rotate(startingAt: pts, formatDescription: formatDescription)
        }

        guard let segment = current,
              let input = segment.videoInput,
              segment.startPTS.isValid else { return }

        guard input.isReadyForMoreMediaData else {
            overflowDrops += 1
            return
        }
        guard let retimed = SampleBufferFactory.retime(sampleBuffer, by: segment.startPTS) else { return }
        if input.append(retimed) {
            segment.lastPTS = pts
        } else {
            KaijuLog.buffer.error("Segment video append failed: \(String(describing: segment.writer?.error))")
        }
    }

    func appendAudio(samples: UnsafePointer<Float>,
                     frameCount: Int,
                     pts: CMTime,
                     track: AudioTrackKind,
                     format: AVAudioFormat) {
        guard frameCount > 0 else { return }
        let bytesPerFrame = Int(format.channelCount) * MemoryLayout<Float>.size
        let byteLength = frameCount * bytesPerFrame

        let formatDescription: CMFormatDescription? = lock.withLock {
            if let existing = audioFormatDescriptions[track] { return existing }
            guard let created = SampleBufferFactory.makeAudioFormatDescription(from: format) else {
                return nil
            }
            audioFormatDescriptions[track] = created
            audioFormats[track] = format
            return created
        }
        guard let formatDescription else { return }

        guard let sampleBuffer = SampleBufferFactory.makeAudioSampleBuffer(
                pointer: UnsafeRawPointer(samples),
                byteLength: byteLength,
                frameCount: frameCount,
                pts: pts,
                formatDescription: formatDescription,
                bytesPerFrame: bytesPerFrame) else { return }

        writerQueue.async { [weak self] in
            self?.handleAudio(sampleBuffer, track: track, format: format)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer,
                             track: AudioTrackKind,
                             format: AVAudioFormat) {
        guard !isShuttingDown,
              let segment = current,
              segment.startPTS.isValid else { return }

        let input: AVAssetWriterInput
        if let existing = segment.audioInputs[track] {
            input = existing
        } else {
            // The writer is already running; a track can't be added now. It'll be
            // present from the next segment onwards.
            return
        }
        guard input.isReadyForMoreMediaData else { return }
        guard let retimed = SampleBufferFactory.retime(sampleBuffer, by: segment.startPTS) else { return }
        _ = input.append(retimed)
    }

    // MARK: - Rotation

    private func rotate(startingAt pts: CMTime, formatDescription: CMFormatDescription) {
        finalizeCurrent()
        guard let segment = makeSegment(startingAt: pts, formatDescription: formatDescription) else { return }
        current = segment
        lock.withLock { segments.append(segment) }
        pruneOldSegments(now: pts)
    }

    private func makeSegment(startingAt pts: CMTime,
                             formatDescription: CMFormatDescription) -> Segment? {
        sequenceCounter += 1
        let name = String(format: "kaiju-segment-%06d.mp4", sequenceCounter)
        let url = configuration.directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        let segment = Segment(url: url, sequence: sequenceCounter)
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = false

            let videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: nil,
                                                sourceFormatHint: formatDescription)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else { return nil }
            writer.add(videoInput)

            let kinds: [AudioTrackKind] = configuration.separateTracks ? [.system, .microphone] : [.mixed]
            let formats = lock.withLock { audioFormats }
            for kind in kinds {
                let sampleRate = formats[kind]?.sampleRate ?? configuration.sampleRate
                let channels = Int(formats[kind]?.channelCount ?? AVAudioChannelCount(configuration.channelCount))
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: configuration.audioBitrate
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    segment.audioInputs[kind] = input
                }
            }

            guard writer.startWriting() else {
                KaijuLog.buffer.error("Segment writer refused to start: \(String(describing: writer.error))")
                return nil
            }
            writer.startSession(atSourceTime: .zero)

            segment.writer = writer
            segment.videoInput = videoInput
            segment.startPTS = pts
            segment.lastPTS = pts
            return segment
        } catch {
            KaijuLog.buffer.error("Couldn't create segment: \(String(describing: error))")
            return nil
        }
    }

    private func finalizeCurrent() {
        guard let segment = current else { return }
        current = nil
        segment.videoInput?.markAsFinished()
        for input in segment.audioInputs.values { input.markAsFinished() }
        guard let writer = segment.writer, writer.status == .writing else {
            segment.isFinalized = true
            return
        }
        writer.finishWriting { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                segment.isFinalized = true
                if let size = try? segment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    self.bytesOnDisk += size
                }
            }
        }
    }

    private func pruneOldSegments(now: CMTime) {
        let cutoff = CMTimeSubtract(now, KaijuTime.time(seconds: configuration.retainSeconds + configuration.segmentSeconds))
        var removable: [Segment] = []
        lock.withLock {
            var kept: [Segment] = []
            for segment in segments {
                let isCurrent = segment === current
                let expired = segment.endPTS.isValid && segment.endPTS < cutoff
                if expired && !isCurrent && segment.pinCount == 0 && segment.isFinalized {
                    removable.append(segment)
                } else {
                    kept.append(segment)
                }
            }
            segments = kept
        }
        for segment in removable {
            if let size = try? segment.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                lock.withLock { bytesOnDisk = max(0, bytesOnDisk - size) }
            }
            try? FileManager.default.removeItem(at: segment.url)
        }
    }

    // MARK: - Snapshot

    func snapshot(duration: TimeInterval) throws -> ReplaySnapshot {
        // Close the in-progress segment so the most recent seconds are readable,
        // then immediately open a new one. Ingest keeps flowing into the new file;
        // the buffer is never actually stopped.
        let pendingBox = Guarded<Segment?>(nil)
        let finalizeDone = DispatchSemaphore(value: 0)
        writerQueue.async { [weak self] in
            guard let self else { finalizeDone.signal(); return }
            pendingBox.withLock { $0 = self.current }
            self.finalizeCurrent()
            finalizeDone.signal()
        }
        _ = finalizeDone.wait(timeout: .now() + 3)

        // Wait for the flush *off* the writer queue, so ingest keeps draining
        // while the last segment closes.
        if let pending = pendingBox.current {
            var waited = 0.0
            while !lock.withLock({ pending.isFinalized }) && waited < 5.0 {
                Thread.sleep(forTimeInterval: 0.02)
                waited += 0.02
            }
        }

        let candidates: [Segment] = lock.withLock {
            segments.filter { $0.isFinalized && $0.startPTS.isValid && $0.endPTS.isValid }
                .sorted { $0.sequence < $1.sequence }
        }
        guard let newest = candidates.last else { throw KaijuError.bufferEmpty }

        let endTime = newest.endPTS
        let oldest = candidates[0].startPTS
        let available = CMTimeGetSeconds(CMTimeSubtract(endTime, oldest))
        guard available > 0.2 else {
            throw KaijuError.bufferTooShort(available: max(0, available), requested: duration)
        }
        let clipped = min(duration, available)
        let requestedStart = CMTimeSubtract(endTime, KaijuTime.time(seconds: clipped))

        let needed = candidates.filter { $0.endPTS > requestedStart }
        guard let first = needed.first else { throw KaijuError.bufferEmpty }

        // Pin so rotation can't delete these while the clip is being written.
        lock.withLock { for segment in needed { segment.pinCount += 1 } }
        let entries = needed.map { SegmentEntry(url: $0.url, start: $0.startPTS, end: $0.endPTS) }

        let snapshot = ReplaySnapshot(source: .segments(entries: entries),
                                      actualStart: first.startPTS,
                                      requestedStart: requestedStart,
                                      endTime: endTime,
                                      encodeSize: configuration.encodeSize,
                                      frameRate: configuration.frameRate)
        snapshot.onRelease = { [weak self] in
            guard let self else { return }
            self.lock.withLock { for segment in needed { segment.pinCount = max(0, segment.pinCount - 1) } }
        }
        return snapshot
    }

    // MARK: - Status

    var status: ReplayStoreStatus {
        lock.withLock {
            var status = ReplayStoreStatus()
            status.capacitySeconds = configuration.retainSeconds
            status.isDiskBacked = true
            status.diskBytes = bytesOnDisk
            status.droppedForOverflow = overflowDrops
            let valid = segments.filter { $0.startPTS.isValid }
            if let first = valid.first, let last = valid.last, last.endPTS.isValid {
                status.bufferedSeconds = min(configuration.retainSeconds,
                                             max(0, CMTimeGetSeconds(CMTimeSubtract(last.endPTS, first.startPTS))))
            }
            status.videoSampleCount = valid.count
            return status
        }
    }

    func reset() {
        let done = DispatchSemaphore(value: 0)
        writerQueue.async { [weak self] in
            guard let self else { done.signal(); return }
            self.finalizeCurrent()
            let all = self.lock.withLock { () -> [Segment] in
                let copy = self.segments
                self.segments = []
                self.bytesOnDisk = 0
                return copy
            }
            for segment in all { try? FileManager.default.removeItem(at: segment.url) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }

    func shutdown() {
        isShuttingDown = true
        reset()
        try? FileManager.default.removeItem(at: configuration.directory)
    }
}

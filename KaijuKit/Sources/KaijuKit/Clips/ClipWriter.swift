import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

public struct ClipWriteOutcome: Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let byteCount: Int64
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let audioTrackCount: Int
    public let writeSeconds: TimeInterval
}

/// Turns a `ReplaySnapshot` into a playable file.
///
/// Video is never re-encoded here. The frames were compressed once, in real time,
/// as they were captured; saving a clip muxes those exact bytes into a container.
/// That's why the hotkey feels instant regardless of clip length, and why saving
/// costs almost no CPU while a game is running.
///
/// Audio *is* encoded here (PCM → AAC), which is deliberate: a few hundred
/// kilobytes of audio per second is nothing to compress at save time, and keeping
/// it uncompressed in the buffer removed an entire real-time encoder from the
/// capture path.
public enum ClipWriter {

    public static func write(snapshot: ReplaySnapshot,
                             to url: URL,
                             audioBitrate: Int) async throws -> ClipWriteOutcome {
        let started = Date()
        try prepareDestination(url)

        switch snapshot.source {
        case .memory(let videoData, let videoRecords, let videoFormat, let audioTracks):
            try await writeMemory(videoData: videoData,
                                  videoRecords: videoRecords,
                                  videoFormat: videoFormat,
                                  audioTracks: audioTracks,
                                  snapshot: snapshot,
                                  to: url,
                                  audioBitrate: audioBitrate)
        case .segments(let entries):
            try await writeSegments(entries: entries, snapshot: snapshot, to: url)
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? snapshot.duration
        let audioTrackCount = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0

        return ClipWriteOutcome(url: url,
                                duration: duration,
                                byteCount: Int64(size),
                                width: Int(snapshot.encodeSize.width),
                                height: Int(snapshot.encodeSize.height),
                                frameRate: snapshot.frameRate,
                                audioTrackCount: audioTrackCount,
                                writeSeconds: Date().timeIntervalSince(started))
    }

    private static func prepareDestination(_ url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw KaijuError.saveLocationUnwritable(path: directory.path)
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw KaijuError.saveLocationUnwritable(path: directory.path)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - In-memory snapshots

    private static func writeMemory(videoData: Data,
                                    videoRecords: [SampleRecord],
                                    videoFormat: CMFormatDescription,
                                    audioTracks: [AudioTrackSnapshot],
                                    snapshot: ReplaySnapshot,
                                    to url: URL,
                                    audioBitrate: Int) async throws {
        guard !videoRecords.isEmpty else { throw KaijuError.bufferEmpty }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw KaijuError.clipWriteFailed(reason: error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video,
                                            outputSettings: nil,
                                            sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw KaijuError.clipWriteFailed(reason: "The writer rejected the captured video format.")
        }
        writer.add(videoInput)

        var audioInputs: [(input: AVAssetWriterInput, track: AudioTrackSnapshot, format: CMFormatDescription, bytesPerFrame: Int)] = []
        for track in audioTracks {
            guard let formatDescription = SampleBufferFactory.makeAudioFormatDescription(from: track.format) else {
                continue
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: track.format.sampleRate,
                AVNumberOfChannelsKey: Int(track.format.channelCount),
                AVEncoderBitRateKey: audioBitrate
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if audioTracks.count > 1 {
                input.metadata = [titleMetadata(track.kind.trackName)]
            }
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            let bytesPerFrame = Int(track.format.channelCount) * MemoryLayout<Float>.size
            audioInputs.append((input, track, formatDescription, bytesPerFrame))
        }

        guard writer.startWriting() else {
            throw KaijuError.clipWriteFailed(reason: writer.error?.localizedDescription
                                             ?? "The writer refused to start.")
        }
        writer.startSession(atSourceTime: .zero)

        // Working copies of the clip's bytes, owned for the duration of the write.
        // Sample buffers are built lazily from these so we never hold thousands of
        // live CMSampleBuffers at once.
        let videoBytes = RawBuffer(copying: videoData)
        let audioBytes = audioInputs.map { RawBuffer(copying: $0.track.data) }
        defer {
            videoBytes.release()
            audioBytes.forEach { $0.release() }
        }

        let origin = snapshot.actualStart
        let clipEnd = CMTimeSubtract(snapshot.endTime, origin)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var index = 0
                await pump(videoInput, label: "com.mac.Kaiju.clip.video") {
                    guard index < videoRecords.count else { return nil }
                    let record = videoRecords[index]
                    index += 1
                    return SampleBufferFactory.makeVideoSampleBuffer(
                        pointer: videoBytes.pointer.advanced(by: record.offset),
                        length: record.length,
                        pts: CMTimeSubtract(record.pts, origin),
                        decodeTime: CMTimeSubtract(record.decodeTime, origin),
                        duration: record.duration,
                        isSync: record.isSync,
                        formatDescription: videoFormat)
                }
            }

            for (position, entry) in audioInputs.enumerated() {
                let buffer = audioBytes[position]
                group.addTask {
                    var index = 0
                    await pump(entry.input, label: "com.mac.Kaiju.clip.audio\(position)") {
                        while index < entry.track.records.count {
                            let record = entry.track.records[index]
                            index += 1
                            let pts = CMTimeSubtract(record.pts, origin)
                            // Drop the sliver that predates the first video frame
                            // rather than shifting audio, which would break sync.
                            if pts < .zero { continue }
                            if pts >= clipEnd { return nil }
                            let frameCount = record.length / entry.bytesPerFrame
                            return SampleBufferFactory.makeAudioSampleBuffer(
                                pointer: buffer.pointer.advanced(by: record.offset),
                                byteLength: record.length,
                                frameCount: frameCount,
                                pts: pts,
                                formatDescription: entry.format,
                                bytesPerFrame: entry.bytesPerFrame)
                        }
                        return nil
                    }
                }
            }
        }

        await finish(writer)
        if writer.status != .completed {
            throw KaijuError.clipWriteFailed(reason: writer.error?.localizedDescription
                                             ?? "The writer stopped before finishing.")
        }
    }

    // MARK: - Disk-segment snapshots

    private static func writeSegments(entries: [SegmentEntry],
                                      snapshot: ReplaySnapshot,
                                      to url: URL) async throws {
        guard !entries.isEmpty else { throw KaijuError.bufferEmpty }

        let clipStart = snapshot.actualStart
        let clipEnd = snapshot.endTime

        let videoProvider = SegmentSampleProvider(entries: entries, mediaType: .video,
                                                  trackIndex: 0,
                                                  clipStart: clipStart, clipEnd: clipEnd)
        guard try await videoProvider.prepare(), let videoFormat = videoProvider.formatDescription else {
            throw KaijuError.clipWriteFailed(reason: "The buffered segments had no readable video.")
        }

        var audioProviders: [(provider: SegmentSampleProvider, format: CMFormatDescription, name: String)] = []
        for index in 0..<2 {
            let provider = SegmentSampleProvider(entries: entries, mediaType: .audio,
                                                 trackIndex: index,
                                                 clipStart: clipStart, clipEnd: clipEnd)
            if (try? await provider.prepare()) == true, let format = provider.formatDescription {
                let name = index == 0 ? AudioTrackKind.system.trackName : AudioTrackKind.microphone.trackName
                audioProviders.append((provider, format, name))
            }
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw KaijuError.clipWriteFailed(reason: error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw KaijuError.clipWriteFailed(reason: "The writer rejected the segment video format.")
        }
        writer.add(videoInput)

        var audioInputs: [AVAssetWriterInput] = []
        for entry in audioProviders {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                           sourceFormatHint: entry.format)
            input.expectsMediaDataInRealTime = false
            if audioProviders.count > 1 { input.metadata = [titleMetadata(entry.name)] }
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            audioInputs.append(input)
        }

        guard writer.startWriting() else {
            throw KaijuError.clipWriteFailed(reason: writer.error?.localizedDescription
                                             ?? "The writer refused to start.")
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(videoInput, label: "com.mac.Kaiju.clip.segvideo") {
                    videoProvider.next()
                }
            }
            for (position, input) in audioInputs.enumerated() {
                let provider = audioProviders[position].provider
                group.addTask {
                    await pump(input, label: "com.mac.Kaiju.clip.segaudio\(position)") {
                        provider.next()
                    }
                }
            }
        }

        videoProvider.cancel()
        audioProviders.forEach { $0.provider.cancel() }

        await finish(writer)
        if writer.status != .completed {
            throw KaijuError.clipWriteFailed(reason: writer.error?.localizedDescription
                                             ?? "The writer stopped before finishing.")
        }
    }

    // MARK: - Plumbing

    /// Drives one writer input until its provider runs dry. `provider` is always
    /// called on the input's own serial queue, so it can hold mutable cursor state.
    static func pump(_ input: AVAssetWriterInput,
                     label: String,
                     provider: @escaping () -> CMSampleBuffer?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: label)
            let finished = Guarded(false)
            func complete() {
                let alreadyDone = finished.withLock { flag -> Bool in
                    if flag { return true }
                    flag = true
                    return false
                }
                guard !alreadyDone else { return }
                input.markAsFinished()
                continuation.resume()
            }
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sampleBuffer = provider() else { complete(); return }
                    if !input.append(sampleBuffer) { complete(); return }
                }
            }
        }
    }

    static func finish(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
    }

    static func titleMetadata(_ title: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "und"
        return item
    }
}

/// A plain heap copy of a `Data`, so sample buffers can be built lazily from a
/// stable pointer without keeping the original `Data` pinned across suspension.
final class RawBuffer {
    let pointer: UnsafeMutableRawPointer
    let count: Int
    private var released = false

    init(copying data: Data) {
        count = max(1, data.count)
        pointer = .allocate(byteCount: count, alignment: 16)
        if !data.isEmpty {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                pointer.copyMemory(from: base, byteCount: data.count)
            }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        pointer.deallocate()
    }

    deinit { release() }
}

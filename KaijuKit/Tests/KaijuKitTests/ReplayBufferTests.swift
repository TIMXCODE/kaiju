import XCTest
import CoreMedia
import AVFoundation
@testable import KaijuKit

/// Exercises the rolling buffer with synthetic encoded frames.
///
/// No screen, no encoder, no permissions — just the data structure that has to
/// hold a fixed amount of history, evict the rest, and hand back a clip that
/// starts on a keyframe. If this is wrong, everything downstream is wrong.
final class MemoryReplayStoreTests: XCTestCase {

    private func makeVideoFormat() throws -> CMFormatDescription {
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    codecType: kCMVideoCodecType_H264,
                                                    width: 1920, height: 1080,
                                                    extensions: nil,
                                                    formatDescriptionOut: &format)
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(format)
    }

    private func makeStore(retain: TimeInterval = 10,
                           bitrate: Int = 8_000_000,
                           budget: Int = 256 << 20) -> MemoryReplayStore {
        MemoryReplayStore(configuration: MemoryReplayStore.Configuration(
            retainSeconds: retain,
            estimatedVideoBitrate: bitrate,
            sampleRate: 48_000,
            channelCount: 2,
            separateTracks: false,
            memoryBudgetBytes: budget,
            encodeSize: CGSize(width: 1920, height: 1080),
            frameRate: 60))
    }

    /// Pushes `seconds` of 60 fps video with a keyframe every second, plus
    /// matching audio, exactly the way the live pipeline does.
    private func feed(_ store: MemoryReplayStore,
                      seconds: Double,
                      format: CMFormatDescription,
                      frameBytes: Int = 20_000,
                      startingAt startFrame: Int = 0) {
        let fps = 60
        let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 48_000, channels: 2, interleaved: true)!
        let payload = [UInt8](repeating: 0xAB, count: frameBytes)
        let audioChunk = [Float](repeating: 0.25, count: 1024 * 2)
        var audioFrame = 0

        let total = Int(seconds * Double(fps))
        for index in 0..<total {
            let absolute = startFrame + index
            let pts = CMTime(value: Int64(absolute), timescale: CMTimeScale(fps))
            payload.withUnsafeBytes { bytes in
                store.appendVideo(bytes: bytes,
                                  pts: pts,
                                  decodeTime: pts,
                                  duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                  isSync: absolute % fps == 0,
                                  formatDescription: format)
            }
            // ~2.8 audio chunks per video frame at 48 kHz / 1024.
            while Double(audioFrame * 1024) / 48_000.0 < Double(absolute + 1) / Double(fps) {
                let audioPTS = CMTime(value: Int64(audioFrame * 1024), timescale: 48_000)
                audioChunk.withUnsafeBufferPointer { buffer in
                    store.appendAudio(samples: buffer.baseAddress!,
                                      frameCount: 1024,
                                      pts: audioPTS,
                                      track: .mixed,
                                      format: audioFormat)
                }
                audioFrame += 1
            }
        }
    }

    func testBufferedDurationSettlesAtTheConfiguredLength() throws {
        let format = try makeVideoFormat()
        let store = makeStore(retain: 10)
        feed(store, seconds: 40, format: format)

        let status = store.status
        XCTAssertEqual(status.bufferedSeconds, 10, accuracy: 1.0,
                       "A 10-second buffer fed 40 seconds should hold about 10")
        XCTAssertFalse(status.isDiskBacked)
    }

    func testMemoryDoesNotGrowWithRuntime() throws {
        let format = try makeVideoFormat()
        let store = makeStore(retain: 5)
        feed(store, seconds: 5, format: format)
        let early = store.status.memoryBytes
        feed(store, seconds: 120, format: format, startingAt: 300)
        let late = store.status.memoryBytes
        XCTAssertEqual(early, late, "Arena size is fixed at init; 2 further minutes must not change it")
    }

    func testSnapshotStartsOnAKeyframe() throws {
        let format = try makeVideoFormat()
        let store = makeStore(retain: 20)
        feed(store, seconds: 20, format: format)

        let snapshot = try store.snapshot(duration: 5)
        guard case .memory(_, let records, _, _) = snapshot.source else {
            return XCTFail("Expected an in-memory snapshot")
        }
        XCTAssertTrue(records.first?.isSync == true, "Clips must open on a sync sample")
        XCTAssertGreaterThan(records.count, 250)      // ~5s at 60fps
        XCTAssertEqual(snapshot.duration, 5, accuracy: 1.1,
                       "Snapping back to a keyframe can add up to one keyframe interval")
    }

    func testSnapshotCarriesAudioForTheSameWindow() throws {
        let format = try makeVideoFormat()
        let store = makeStore(retain: 20)
        feed(store, seconds: 20, format: format)

        let snapshot = try store.snapshot(duration: 5)
        guard case .memory(_, _, _, let tracks) = snapshot.source else {
            return XCTFail("Expected an in-memory snapshot")
        }
        let mixed = try XCTUnwrap(tracks.first { $0.kind == .mixed })
        let audioSeconds = Double(mixed.records.count * 1024) / 48_000
        XCTAssertEqual(audioSeconds, snapshot.duration, accuracy: 0.5,
                       "Audio and video must cover the same window or the clip is out of sync")
    }

    /// The behaviour the whole app rests on: saving must not disturb the buffer.
    func testBufferKeepsRunningAcrossRepeatedSnapshots() throws {
        let format = try makeVideoFormat()
        let store = makeStore(retain: 15)
        feed(store, seconds: 15, format: format)

        var frame = 900
        for _ in 0..<5 {
            let snapshot = try store.snapshot(duration: 5)
            XCTAssertGreaterThan(snapshot.duration, 4)
            feed(store, seconds: 2, format: format, startingAt: frame)
            frame += 120
        }
        XCTAssertEqual(store.status.bufferedSeconds, 15, accuracy: 1.5)
    }

    func testEmptyBufferReportsSomethingUseful() {
        let store = makeStore(retain: 10)
        XCTAssertThrowsError(try store.snapshot(duration: 5)) { error in
            XCTAssertEqual(error as? KaijuError, .bufferEmpty)
        }
    }

    func testShortBufferReportsHowMuchItHas() throws {
        let format = try makeVideoFormat()
        let store = makeStore(retain: 30)
        feed(store, seconds: 3, format: format)
        // Asking for more than exists clips to what's available rather than failing.
        let snapshot = try store.snapshot(duration: 30)
        XCTAssertEqual(snapshot.duration, 3, accuracy: 1.1)
    }

    func testLongBuffersChooseTheDiskBackend() {
        // 30 minutes of 4K60 can't live in 768 MB, and the buffer should know that
        // rather than trying and thrashing.
        var replay = ReplayConfiguration()
        replay.bufferSeconds = 30 * 60
        replay.memoryBudgetMB = 768
        var recording = RecordingConfiguration()
        recording.resolution = .p2160
        recording.frameRate = .fps60

        let projection = ReplayBuffer.projectedMemoryUse(
            replay: replay, recording: recording, audio: AudioConfiguration(),
            encodeSize: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(projection.backend, .disk)

        // …while a normal 60-second 1080p buffer stays in RAM.
        replay.bufferSeconds = 60
        recording.resolution = .p1080
        let small = ReplayBuffer.projectedMemoryUse(
            replay: replay, recording: recording, audio: AudioConfiguration(),
            encodeSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(small.backend, .memory)
        XCTAssertLessThan(small.bytes, 768 << 20)
    }

    func testSegmentLengthStaysReasonable() {
        // A 30-minute buffer should rotate about once a minute, not every 2 seconds.
        XCTAssertEqual(DiskReplayStore.Configuration.segmentLength(forRetain: 1800), 60)
        XCTAssertEqual(DiskReplayStore.Configuration.segmentLength(forRetain: 60), 10)
        let segments = 1800 / DiskReplayStore.Configuration.segmentLength(forRetain: 1800)
        XCTAssertLessThan(segments, 40, "Should be dozens of files per session, not thousands")
    }
}

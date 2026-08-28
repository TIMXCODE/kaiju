import XCTest
@testable import KaijuKit

final class RecordDequeTests: XCTestCase {
    func testAppendAndIndex() {
        var deque = RecordDeque<Int>()
        for value in 0..<10 { deque.append(value) }
        XCTAssertEqual(deque.count, 10)
        XCTAssertEqual(deque[0], 0)
        XCTAssertEqual(deque[9], 9)
        XCTAssertEqual(deque.first, 0)
        XCTAssertEqual(deque.last, 9)
    }

    func testRemoveFirstKeepsIndexingCorrect() {
        var deque = RecordDeque<Int>()
        for value in 0..<10 { deque.append(value) }
        XCTAssertEqual(deque.removeFirst(), 0)
        XCTAssertEqual(deque.removeFirst(), 1)
        XCTAssertEqual(deque.count, 8)
        XCTAssertEqual(deque[0], 2)
        XCTAssertEqual(deque.last, 9)
    }

    /// The replay ring appends ~60 records a second for hours. This is the
    /// property that keeps that from turning into an O(n²) memmove.
    func testCompactionKeepsStorageBounded() {
        var deque = RecordDeque<Int>()
        for round in 0..<50_000 {
            deque.append(round)
            if deque.count > 100 { deque.removeFirst() }
        }
        XCTAssertEqual(deque.count, 101)
        XCTAssertLessThan(deque.storage.count, 5_000,
                          "Dead prefix should be reclaimed rather than growing forever")
    }

    func testBinarySearchHelpers() {
        var deque = RecordDeque<Int>()
        for value in stride(from: 0, to: 100, by: 10) { deque.append(value) }
        XCTAssertEqual(deque.lastIndex(wherePrefix: { $0 <= 45 }), 4)   // value 40
        XCTAssertEqual(deque.firstIndex(whereSuffix: { $0 >= 45 }), 5)  // value 50
        XCTAssertNil(deque.lastIndex(wherePrefix: { $0 < 0 }))
    }
}

final class ByteRingTests: XCTestCase {
    private func write(_ ring: ByteRing, bytes: [UInt8]) -> Int? {
        bytes.withUnsafeBytes { ring.append($0) }
    }

    func testSequentialWriteAndRead() {
        let ring = ByteRing(capacity: 1024)
        let payload = [UInt8](repeating: 7, count: 100)
        let offset = write(ring, bytes: payload)
        XCTAssertEqual(offset, 0)
        let read = ring.read(absoluteOffset: 0, length: 100)
        XCTAssertEqual(read.map(Array.init), payload)
    }

    func testWrapAroundPreservesNewestData() {
        let ring = ByteRing(capacity: 256)
        var offsets: [Int] = []
        for value in 0..<10 {
            let payload = [UInt8](repeating: UInt8(value), count: 50)
            offsets.append(write(ring, bytes: payload)!)
        }
        // 500 bytes written into a 256-byte ring: only the last ~5 chunks survive.
        XCTAssertFalse(ring.contains(absoluteOffset: offsets[0], length: 50))
        let newest = offsets[9]
        XCTAssertTrue(ring.contains(absoluteOffset: newest, length: 50))
        let read = ring.read(absoluteOffset: newest, length: 50)
        XCTAssertEqual(read.map(Array.init), [UInt8](repeating: 9, count: 50))
    }

    func testReadAcrossTheWrapPoint() {
        let ring = ByteRing(capacity: 100)
        _ = write(ring, bytes: [UInt8](repeating: 1, count: 80))
        let payload = (0..<40).map { UInt8($0) }
        let offset = write(ring, bytes: payload)!   // wraps at byte 100
        XCTAssertEqual(ring.read(absoluteOffset: offset, length: 40).map(Array.init), payload)
    }

    func testOversizedWriteIsRejectedRatherThanCorrupting() {
        let ring = ByteRing(capacity: 64)
        XCTAssertNil(write(ring, bytes: [UInt8](repeating: 0, count: 65)))
    }

    func testCapacityNeverGrows() {
        let ring = ByteRing(capacity: 4096)
        for _ in 0..<10_000 { _ = write(ring, bytes: [UInt8](repeating: 3, count: 200)) }
        XCTAssertEqual(ring.capacity, 4096)
        XCTAssertEqual(ring.used, 4096)
    }
}

final class ConfigurationTests: XCTestCase {
    func testResolutionKeepsAspectAndStaysEven() {
        let source = CGSize(width: 3024, height: 1964)   // a 14" MacBook Pro panel
        let size = ResolutionPreset.p1080.encodeSize(forSource: source)
        XCTAssertEqual(Int(size.height), 1080)
        XCTAssertEqual(Int(size.width) % 2, 0)
        let sourceAspect = source.width / source.height
        let outputAspect = size.width / size.height
        XCTAssertEqual(sourceAspect, outputAspect, accuracy: 0.01)
    }

    func testResolutionNeverUpscales() {
        let source = CGSize(width: 1280, height: 720)
        let size = ResolutionPreset.p2160.encodeSize(forSource: source)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))
    }

    /// The buffer has to be at least as long as the longest clip you can pull out
    /// of it, or the hotkey would ask for history that was never kept.
    func testBufferLengthCoversTheLongestClip() {
        var configuration = ReplayConfiguration()
        configuration.bufferSeconds = 20
        configuration.captureClipSeconds = 120
        XCTAssertEqual(configuration.effectiveBufferSeconds, 120)
    }

    func testBufferLengthIsClamped() {
        var configuration = ReplayConfiguration()
        configuration.bufferSeconds = 5
        configuration.instantReplaySeconds = 5
        configuration.captureClipSeconds = 5
        XCTAssertEqual(configuration.effectiveBufferSeconds, ReplayConfiguration.minimumBufferSeconds)

        configuration.bufferSeconds = 60 * 60
        XCTAssertEqual(configuration.effectiveBufferSeconds, ReplayConfiguration.maximumBufferSeconds)
    }

    func testBitrateScalesWithPixelRate() {
        let low = BitratePreset.balanced.bitrate(width: 1280, height: 720, fps: 30, codec: .h264)
        let high = BitratePreset.balanced.bitrate(width: 3840, height: 2160, fps: 60, codec: .h264)
        XCTAssertGreaterThan(high, low * 8)
        let hevc = BitratePreset.balanced.bitrate(width: 3840, height: 2160, fps: 60, codec: .hevc)
        XCTAssertLessThan(hevc, high)
    }

    func testSettingsRoundTripThroughJSON() throws {
        var settings = KaijuSettings()
        settings.recording.codec = .hevc
        settings.replay.bufferSeconds = 300
        settings.hotkeys[.instantReplay] = Hotkey(keyCode: 34, modifiers: [.command, .shift])
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(KaijuSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }
}

final class HotkeyTests: XCTestCase {
    func testDisplayString() {
        let hotkey = Hotkey(keyCode: 8, modifiers: [.command, .option])
        XCTAssertEqual(hotkey.displayString, "⌥⌘C")
    }

    func testModifiersAreRequired() {
        XCTAssertFalse(Hotkey(keyCode: 8, modifiers: [.shift]).isValid)
        XCTAssertTrue(Hotkey(keyCode: 8, modifiers: [.control]).isValid)
    }

    func testDefaultsAreDistinct() {
        let configuration = HotkeyConfiguration()
        XCTAssertTrue(configuration.conflictingActions().isEmpty)
        XCTAssertEqual(configuration[.instantReplay]?.displayString, "⌥⌘I")
        XCTAssertEqual(configuration[.captureClip]?.displayString, "⌥⌘C")
        XCTAssertEqual(configuration[.toggleBuffer]?.displayString, "⌥⌘R")
        XCTAssertEqual(configuration[.toggleWindow]?.displayString, "⌥⌘H")
    }

    func testConflictsAreDetected() {
        var configuration = HotkeyConfiguration()
        configuration[.captureClip] = configuration[.instantReplay]
        let conflicts = configuration.conflictingActions()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.values.first?.count, 2)
    }

    func testSystemShortcutsAreRefused() {
        XCTAssertNotNil(SystemShortcuts.conflict(for: Hotkey(keyCode: 49, modifiers: [.command])))
        XCTAssertNil(SystemShortcuts.conflict(for: Hotkey(keyCode: 8, modifiers: [.command, .option])))
    }
}

import XCTest
@testable import KaijuKit

final class EditPlanTests: XCTestCase {

    func testTrimOnly() {
        var plan = EditPlan(sourceDuration: 30)
        plan.trimStart = 5
        plan.trimEnd = 20
        XCTAssertEqual(plan.outputDuration, 15, accuracy: 0.001)
        XCTAssertEqual(plan.outputTime(forSource: 5), 0)
        XCTAssertEqual(plan.outputTime(forSource: 12.5)!, 7.5, accuracy: 0.001)
        XCTAssertNil(plan.outputTime(forSource: 25))
        XCTAssertNil(plan.outputTime(forSource: 1))
    }

    func testSingleCutRemovesTheMiddle() {
        var plan = EditPlan(sourceDuration: 30)
        plan.trimEnd = 30
        plan.cuts = [ClosedRangeBox(lower: 10, upper: 15)]
        XCTAssertEqual(plan.outputDuration, 25, accuracy: 0.001)
        XCTAssertEqual(plan.outputTime(forSource: 9)!, 9, accuracy: 0.001)
        XCTAssertNil(plan.outputTime(forSource: 12))
        XCTAssertEqual(plan.outputTime(forSource: 20)!, 15, accuracy: 0.001)
    }

    func testMultipleCutsCompose() {
        var plan = EditPlan(sourceDuration: 60)
        plan.trimEnd = 60
        plan.cuts = [
            ClosedRangeBox(lower: 10, upper: 20),
            ClosedRangeBox(lower: 40, upper: 45)
        ]
        XCTAssertEqual(plan.outputDuration, 45, accuracy: 0.001)
        XCTAssertEqual(plan.outputTime(forSource: 30)!, 20, accuracy: 0.001)
        XCTAssertEqual(plan.outputTime(forSource: 50)!, 35, accuracy: 0.001)
    }

    func testCutsAreClippedToTheTrimRange() {
        var plan = EditPlan(sourceDuration: 30)
        plan.trimStart = 5
        plan.trimEnd = 25
        plan.cuts = [ClosedRangeBox(lower: 0, upper: 10)]
        XCTAssertEqual(plan.outputDuration, 15, accuracy: 0.001)
        XCTAssertEqual(plan.keptRanges().count, 1)
        XCTAssertEqual(plan.keptRanges()[0].lower, 10, accuracy: 0.001)
    }

    func testVolumeSegmentsMultiply() {
        var plan = EditPlan(sourceDuration: 10)
        plan.trimEnd = 10
        plan.masterVolume = 0.5
        var segment = VolumeSegment()
        segment.startTime = 2
        segment.endTime = 4
        segment.gain = 0
        plan.volumeSegments = [segment]
        XCTAssertEqual(plan.volume(atSource: 1), 0.5)
        XCTAssertEqual(plan.volume(atSource: 3), 0)
        XCTAssertEqual(plan.volume(atSource: 5), 0.5)
    }

    func testPlanRoundTripsThroughJSON() throws {
        var plan = EditPlan(sourceDuration: 30)
        plan.cuts = [ClosedRangeBox(lower: 3, upper: 6)]
        var overlay = TextOverlay()
        overlay.text = "clutch"
        plan.textOverlays = [overlay]
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(EditPlan.self, from: data)
        XCTAssertEqual(decoded, plan)
    }
}

@MainActor
final class StorageRuleTests: XCTestCase {

    private func makeLibrary() -> ClipLibrary {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaijuTests-\(UUID().uuidString)")
        return ClipLibrary(directory: root.appendingPathComponent("Clips"),
                           supportDirectory: root.appendingPathComponent("Support"))
    }

    private func makeClip(daysAgo: Double, megabytes: Int, favorite: Bool = false) -> Clip {
        Clip(fileName: "\(UUID().uuidString).mp4",
             title: "Clip",
             createdAt: Date().addingTimeInterval(-daysAgo * 86_400),
             duration: 15,
             byteCount: Int64(megabytes) * 1_048_576,
             width: 1920, height: 1080, frameRate: 60,
             codec: "H.264", kind: .instantReplay,
             isFavorite: favorite)
    }

    func testNothingIsDeletedWhenNoRuleIsSet() {
        let library = makeLibrary()
        for days in 0..<10 { library.add(makeClip(daysAgo: Double(days) * 30, megabytes: 500)) }
        let manager = StorageManager()
        let candidates = manager.cleanupCandidates(library: library,
                                                   configuration: StorageConfiguration())
        XCTAssertTrue(candidates.isEmpty, "No rule means no deletions, ever")
    }

    func testAgeRuleSelectsOldClipsOnly() {
        let library = makeLibrary()
        library.add(makeClip(daysAgo: 1, megabytes: 100))
        library.add(makeClip(daysAgo: 40, megabytes: 100))
        library.add(makeClip(daysAgo: 90, megabytes: 100))

        var configuration = StorageConfiguration()
        configuration.deleteOlderThanDays = 30
        let candidates = StorageManager().cleanupCandidates(library: library,
                                                            configuration: configuration)
        XCTAssertEqual(candidates.count, 2)
    }

    func testFavouritesAreProtected() {
        let library = makeLibrary()
        library.add(makeClip(daysAgo: 90, megabytes: 100, favorite: true))
        library.add(makeClip(daysAgo: 90, megabytes: 100))

        var configuration = StorageConfiguration()
        configuration.deleteOlderThanDays = 30
        configuration.neverDeleteFavorites = true
        let candidates = StorageManager().cleanupCandidates(library: library,
                                                            configuration: configuration)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(candidates[0].isFavorite)
    }

    func testSizeRuleTrimsOldestFirstUntilItFits() {
        let library = makeLibrary()
        for days in 0..<10 { library.add(makeClip(daysAgo: Double(days), megabytes: 1024)) }  // 10 GB

        var configuration = StorageConfiguration()
        configuration.maximumLibraryGigabytes = 6
        let candidates = StorageManager().cleanupCandidates(library: library,
                                                            configuration: configuration)
        XCTAssertEqual(candidates.count, 4)
        let newest = candidates.map(\.createdAt).max()!
        let kept = library.clips.filter { clip in !candidates.contains { $0.id == clip.id } }
        XCTAssertTrue(kept.allSatisfy { $0.createdAt > newest }, "Oldest clips should go first")
    }
}

import Foundation
import Combine

public struct StorageReport: Sendable, Equatable {
    public var clipCount: Int = 0
    public var favoriteCount: Int = 0
    public var totalBytes: Int64 = 0
    public var availableBytes: Int64 = 0
    public var volumeName: String = ""
    public var largestClipIDs: [UUID] = []
    public var oldestClipDate: Date?
    public var isLowOnSpace = false
    public var wouldCleanupCount: Int = 0
    public var wouldCleanupBytes: Int64 = 0

    public init() {}

    public var totalLabel: String { totalBytes.fileSizeString }
    public var availableLabel: String { availableBytes.fileSizeString }
}

/// Storage accounting and the automatic-cleanup rules.
///
/// Cleanup never runs unless the user turns it on, and even then it reports what
/// it would remove before it removes anything. Deleting someone's clips by
/// surprise is the one unrecoverable thing this app could do.
@MainActor
public final class StorageManager: ObservableObject {
    @Published public private(set) var report = StorageReport()

    public init() {}

    public func refresh(library: ClipLibrary, configuration: StorageConfiguration) {
        var next = StorageReport()
        next.clipCount = library.clips.count
        next.favoriteCount = library.favoriteCount
        next.totalBytes = library.totalBytes
        next.availableBytes = SystemMetrics.availableCapacity(at: configuration.saveDirectory)
        next.volumeName = volumeName(for: configuration.saveDirectory)
        next.largestClipIDs = library.clips
            .sorted { $0.byteCount > $1.byteCount }
            .prefix(5)
            .map(\.id)
        next.oldestClipDate = library.clips.map(\.createdAt).min()
        next.isLowOnSpace = Double(next.availableBytes) < configuration.warnWhenFreeSpaceBelowGB * 1_073_741_824

        let candidates = cleanupCandidates(library: library, configuration: configuration)
        next.wouldCleanupCount = candidates.count
        next.wouldCleanupBytes = candidates.reduce(0) { $0 + $1.byteCount }

        report = next
    }

    /// What the current rules *would* delete. Computed even when cleanup is off,
    /// so the Storage page can show the consequence before you enable it.
    public func cleanupCandidates(library: ClipLibrary,
                                  configuration: StorageConfiguration) -> [Clip] {
        var candidates: [Clip] = []
        var considered = library.clips

        if configuration.neverDeleteFavorites {
            considered.removeAll(where: \.isFavorite)
        }

        if let days = configuration.deleteOlderThanDays, days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let expired = considered.filter { $0.createdAt < cutoff }
            candidates.append(contentsOf: expired)
        }

        if let limitGB = configuration.maximumLibraryGigabytes, limitGB > 0 {
            let limit = Int64(limitGB * 1_073_741_824)
            // Trim oldest-first until the library fits, counting anything already
            // marked for deletion so the two rules don't double up.
            let alreadyMarked = Set(candidates.map(\.id))
            var runningTotal = library.totalBytes - candidates.reduce(0) { $0 + $1.byteCount }
            let oldestFirst = considered
                .filter { !alreadyMarked.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
            for clip in oldestFirst where runningTotal > limit {
                candidates.append(clip)
                runningTotal -= clip.byteCount
            }
        }

        var seen = Set<UUID>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    /// Applies the rules. Returns how many clips went to the Trash.
    @discardableResult
    public func runCleanupIfEnabled(library: ClipLibrary,
                                    configuration: StorageConfiguration) -> [Clip] {
        guard configuration.automaticCleanupEnabled else { return [] }
        let candidates = cleanupCandidates(library: library, configuration: configuration)
        guard !candidates.isEmpty else { return [] }
        library.delete(candidates)
        KaijuLog.clips.notice("Automatic cleanup moved \(candidates.count) clip(s) to the Trash.")
        refresh(library: library, configuration: configuration)
        return candidates
    }

    /// Rough guess at whether a clip of this length will fit, used to warn before
    /// a save rather than after a truncated file.
    public func hasRoom(forSeconds seconds: TimeInterval, bitrate: Int,
                        configuration: StorageConfiguration) -> Bool {
        let required = Int64(Double(bitrate) / 8.0 * seconds * 1.2)
        let available = SystemMetrics.availableCapacity(at: configuration.saveDirectory)
        return available > required + 200_000_000
    }

    public func requiredBytes(forSeconds seconds: TimeInterval, bitrate: Int) -> Int64 {
        Int64(Double(bitrate) / 8.0 * seconds * 1.2)
    }

    private func volumeName(for url: URL) -> String {
        var directory = url
        while !FileManager.default.fileExists(atPath: directory.path),
              directory.pathComponents.count > 1 {
            directory = directory.deletingLastPathComponent()
        }
        let values = try? directory.resourceValues(forKeys: [.volumeNameKey])
        return values?.volumeName ?? "Disk"
    }
}

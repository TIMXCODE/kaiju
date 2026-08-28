import Foundation
import Combine
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// The clip index: what exists, where it lives, and everything the library UI
/// shows about it.
///
/// The index is a cache, not the truth — the files on disk are. On every load the
/// library reconciles the two: entries whose file vanished are dropped, and video
/// files sitting in the folder that Kaiju doesn't know about are adopted with
/// their real metadata read off the asset. That means dragging clips in, or
/// deleting them in Finder, does the sensible thing instead of corrupting state.
@MainActor
public final class ClipLibrary: ObservableObject {
    @Published public private(set) var clips: [Clip] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var lastError: KaijuError?

    public private(set) var directory: URL

    private let indexURL: URL
    private let thumbnailDirectory: URL
    private var thumbnailCache: [UUID: NSImage] = [:]
    private var inFlightThumbnails: Set<UUID> = []

    public init(directory: URL = StorageConfiguration.defaultSaveDirectory,
                supportDirectory: URL = SettingsStore.supportDirectory) {
        self.directory = directory
        self.indexURL = supportDirectory.appendingPathComponent("library.json")
        self.thumbnailDirectory = supportDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Loading

    public func load() async {
        isLoading = true
        defer { isLoading = false }

        var stored = (try? Data(contentsOf: indexURL))
            .flatMap { try? JSONDecoder().decode([Clip].self, from: $0) } ?? []

        let fileManager = FileManager.default
        // 1. Drop entries whose file is gone.
        stored.removeAll { !fileManager.fileExists(atPath: $0.url(in: directory).path) }

        // 2. Adopt files that appeared without us.
        let known = Set(stored.map(\.fileName))
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        for url in contents {
            guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { continue }
            guard !known.contains(url.lastPathComponent) else { continue }
            if let adopted = await Self.makeClip(from: url, kind: .manual) {
                stored.append(adopted)
            }
        }

        clips = stored.sorted { $0.createdAt > $1.createdAt }
        persist()
    }

    public func setDirectory(_ url: URL) async {
        guard url != directory else { return }
        directory = url
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await load()
    }

    // MARK: - Mutation

    public func add(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        clips.insert(clip, at: 0)
        clips.sort { $0.createdAt > $1.createdAt }
        persist()
        Task { await thumbnail(for: clip) }
    }

    public func update(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index] = clip
        persist()
    }

    public func toggleFavorite(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].isFavorite.toggle()
        persist()
    }

    public func rename(_ clip: Clip, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].title = trimmed
        persist()
    }

    /// Removes clips and their files. Only ever called from an explicit user
    /// action or a cleanup rule the user turned on themselves.
    @discardableResult
    public func delete(_ toDelete: [Clip], removeFiles: Bool = true) -> Int {
        var removed = 0
        for clip in toDelete {
            if removeFiles {
                let url = clip.url(in: directory)
                do {
                    // Trash rather than unlink, so a mis-click is recoverable.
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            thumbnailCache[clip.id] = nil
            try? FileManager.default.removeItem(at: thumbnailURL(for: clip.id))
            clips.removeAll { $0.id == clip.id }
            removed += 1
        }
        persist()
        return removed
    }

    public func reveal(_ clip: Clip) {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url(in: directory)])
    }

    public func exists(_ clip: Clip) -> Bool {
        FileManager.default.fileExists(atPath: clip.url(in: directory).path)
    }

    // MARK: - Queries

    public func filtered(_ filter: ClipFilter, sortedBy order: ClipSortOrder) -> [Clip] {
        let matches = clips.filter(filter.matches)
        switch order {
        case .newest:  return matches.sorted { $0.createdAt > $1.createdAt }
        case .oldest:  return matches.sorted { $0.createdAt < $1.createdAt }
        case .longest: return matches.sorted { $0.duration > $1.duration }
        case .largest: return matches.sorted { $0.byteCount > $1.byteCount }
        case .name:    return matches.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    public var knownGames: [(name: String, bundleIdentifier: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for clip in clips {
            guard let bundle = clip.gameBundleIdentifier else { continue }
            let name = clip.gameName ?? bundle
            counts[bundle] = (name, (counts[bundle]?.count ?? 0) + 1)
        }
        return counts.map { ($0.value.name, $0.key, $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    public var totalBytes: Int64 { clips.reduce(0) { $0 + $1.byteCount } }
    public var favoriteCount: Int { clips.filter(\.isFavorite).count }

    // MARK: - Thumbnails

    public func cachedThumbnail(for clip: Clip) -> NSImage? {
        if let image = thumbnailCache[clip.id] { return image }
        let url = thumbnailURL(for: clip.id)
        if let image = NSImage(contentsOf: url) {
            thumbnailCache[clip.id] = image
            return image
        }
        return nil
    }

    @discardableResult
    public func thumbnail(for clip: Clip) async -> NSImage? {
        if let cached = cachedThumbnail(for: clip) { return cached }
        guard !inFlightThumbnails.contains(clip.id) else { return nil }
        inFlightThumbnails.insert(clip.id)
        defer { inFlightThumbnails.remove(clip.id) }

        let source = clip.url(in: directory)
        let destination = thumbnailURL(for: clip.id)
        // A third of the way in usually beats frame zero, which on a game clip is
        // often a loading screen or a fade.
        let time = CMTime(seconds: max(0.1, clip.duration / 3), preferredTimescale: 600)

        let image = await Task.detached(priority: .utility) { () async -> NSImage? in
            let asset = AVURLAsset(url: source)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: time)
                Self.writeJPEG(result.image, to: destination)
                return NSImage(cgImage: result.image,
                               size: NSSize(width: result.image.width, height: result.image.height))
            } catch {
                KaijuLog.clips.debug("Thumbnail failed for \(source.lastPathComponent, privacy: .public): \(String(describing: error))")
                return nil
            }
        }.value

        if let image { thumbnailCache[clip.id] = image }
        return image
    }

    private func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectory.appendingPathComponent("\(id.uuidString).jpg")
    }

    private nonisolated static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = clips
        let url = indexURL
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                KaijuLog.clips.error("Couldn't save the clip index: \(String(describing: error))")
            }
        }
    }

    // MARK: - Adoption

    /// Reads real metadata off a file so an adopted clip shows the same detail as
    /// one Kaiju recorded itself.
    public nonisolated static func makeClip(from url: URL, kind: ClipKind,
                                            gameName: String? = nil,
                                            gameBundleIdentifier: String? = nil,
                                            title: String? = nil) async -> Clip? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let displaySize = size.applying(transform)
        let nominalRate = (try? await track.load(.nominalFrameRate)) ?? 0
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        let codec = formats.first.map { description -> String in
            let type = CMFormatDescriptionGetMediaSubType(description)
            return Self.fourCCString(type)
        } ?? "—"
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let created = (attributes?[.creationDate] as? Date) ?? Date()

        return Clip(fileName: url.lastPathComponent,
                    title: title ?? url.deletingPathExtension().lastPathComponent,
                    createdAt: created,
                    duration: duration,
                    byteCount: byteCount,
                    width: Int(abs(displaySize.width).rounded()),
                    height: Int(abs(displaySize.height).rounded()),
                    frameRate: Int(nominalRate.rounded()),
                    codec: codec,
                    kind: kind,
                    gameName: gameName,
                    gameBundleIdentifier: gameBundleIdentifier,
                    audioTrackCount: audioTracks)
    }

    nonisolated static func fourCCString(_ value: FourCharCode) -> String {
        switch value {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        default:
            let bytes = [
                UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
            ]
            return String(bytes: bytes, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? "—"
        }
    }
}

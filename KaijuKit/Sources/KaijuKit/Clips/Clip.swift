import Foundation

public enum ClipKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case instantReplay
    case captureClip
    case manual
    case edited

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .instantReplay: return "Instant Replay"
        case .captureClip:   return "Capture Clip"
        case .manual:        return "Manual"
        case .edited:        return "Edited"
        }
    }

    public var symbolName: String {
        switch self {
        case .instantReplay: return "bolt.fill"
        case .captureClip:   return "scissors"
        case .manual:        return "hand.tap"
        case .edited:        return "wand.and.stars"
        }
    }
}

public struct Clip: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Relative to the library folder, so moving the folder doesn't break the index.
    public var fileName: String
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var byteCount: Int64
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var codec: String
    public var kind: ClipKind
    public var gameName: String?
    public var gameBundleIdentifier: String?
    public var isFavorite: Bool
    public var audioTrackCount: Int
    public var notes: String?

    public init(id: UUID = UUID(),
                fileName: String,
                title: String,
                createdAt: Date = Date(),
                duration: TimeInterval,
                byteCount: Int64,
                width: Int,
                height: Int,
                frameRate: Int,
                codec: String,
                kind: ClipKind,
                gameName: String? = nil,
                gameBundleIdentifier: String? = nil,
                isFavorite: Bool = false,
                audioTrackCount: Int = 1,
                notes: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.codec = codec
        self.kind = kind
        self.gameName = gameName
        self.gameBundleIdentifier = gameBundleIdentifier
        self.isFavorite = isFavorite
        self.audioTrackCount = audioTrackCount
        self.notes = notes
    }

    public func url(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    public var resolutionLabel: String { "\(width)×\(height)" }
    public var frameRateLabel: String { "\(frameRate) FPS" }
    public var durationLabel: String { duration.clipTimestampString }
    public var sizeLabel: String { byteCount.fileSizeString }

    public var subtitleLabel: String {
        var parts = [durationLabel, resolutionLabel, frameRateLabel, sizeLabel]
        if audioTrackCount > 1 { parts.append("\(audioTrackCount) audio tracks") }
        return parts.joined(separator: " · ")
    }

    public var relativeDateLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    public var absoluteDateLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

public enum ClipSortOrder: String, CaseIterable, Sendable, Identifiable {
    case newest
    case oldest
    case longest
    case largest
    case name

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .newest:  return "Newest first"
        case .oldest:  return "Oldest first"
        case .longest: return "Longest"
        case .largest: return "Largest"
        case .name:    return "Name"
        }
    }
}

public struct ClipFilter: Equatable, Sendable {
    public var searchText: String = ""
    public var favoritesOnly: Bool = false
    public var gameBundleIdentifier: String? = nil
    public var kind: ClipKind? = nil

    public init() {}

    public var isActive: Bool {
        !searchText.isEmpty || favoritesOnly || gameBundleIdentifier != nil || kind != nil
    }

    public func matches(_ clip: Clip) -> Bool {
        if favoritesOnly && !clip.isFavorite { return false }
        if let gameBundleIdentifier, clip.gameBundleIdentifier != gameBundleIdentifier { return false }
        if let kind, clip.kind != kind { return false }
        if !searchText.isEmpty {
            let haystack = [clip.title, clip.gameName ?? "", clip.notes ?? "", clip.fileName]
                .joined(separator: " ")
            if haystack.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
        }
        return true
    }
}

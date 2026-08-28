import Foundation
import CoreMedia
import CoreGraphics
import VideoToolbox

// MARK: - Codec

public enum VideoCodecOption: String, Codable, CaseIterable, Sendable, Identifiable {
    case h264
    case hevc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        }
    }

    public var subtitle: String {
        switch self {
        case .h264: return "Universal compatibility. Upload anywhere without re-encoding."
        case .hevc: return "About 40% smaller at the same quality. Best for 1440p and 4K."
        }
    }

    public var codecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc: return kCMVideoCodecType_HEVC
        }
    }

    public var fileTypeExtension: String { "mp4" }
}

// MARK: - Resolution

public enum ResolutionPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case native
    case p720
    case p1080
    case p1440
    case p2160

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .native: return "Native"
        case .p720:   return "720p"
        case .p1080:  return "1080p"
        case .p1440:  return "1440p"
        case .p2160:  return "4K"
        }
    }

    /// Target height in pixels, or nil for "whatever the source is".
    public var targetHeight: Int? {
        switch self {
        case .native: return nil
        case .p720:   return 720
        case .p1080:  return 1080
        case .p1440:  return 1440
        case .p2160:  return 2160
        }
    }

    /// Encode dimensions for a given source size, preserving aspect ratio and
    /// snapping to even numbers (hardware encoders require that).
    public func encodeSize(forSource source: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1920, height: 1080) }
        guard let targetHeight, source.height > CGFloat(targetHeight) else {
            return CGSize(width: evenValue(source.width), height: evenValue(source.height))
        }
        let scale = CGFloat(targetHeight) / source.height
        return CGSize(width: evenValue(source.width * scale),
                      height: evenValue(CGFloat(targetHeight)))
    }

    private func evenValue(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, Int(value.rounded()))
        return CGFloat(rounded - (rounded % 2))
    }
}

// MARK: - Frame rate

public enum FrameRateOption: Int, Codable, CaseIterable, Sendable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120

    public var id: Int { rawValue }
    public var displayName: String { "\(rawValue) FPS" }

    public var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(rawValue))
    }
}

// MARK: - Bitrate

public enum BitratePreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case efficient
    case balanced
    case high
    case maximum
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .efficient: return "Efficient"
        case .balanced:  return "Balanced"
        case .high:      return "High"
        case .maximum:   return "Maximum"
        case .custom:    return "Custom"
        }
    }

    /// Bits per second for a given pixel count and frame rate. Derived from the
    /// pixel rate rather than hard-coded per resolution so 1440p120 and 4K30 both
    /// land somewhere sane.
    public func bitrate(width: Int, height: Int, fps: Int, codec: VideoCodecOption) -> Int {
        guard self != .custom else { return 20_000_000 }
        let pixelRate = Double(width * height * fps)
        // bits-per-pixel-per-frame targets, tuned for screen content (which is
        // easier than camera footage) at each quality tier.
        let bpp: Double
        switch self {
        case .efficient: bpp = 0.045
        case .balanced:  bpp = 0.075
        case .high:      bpp = 0.11
        case .maximum:   bpp = 0.16
        case .custom:    bpp = 0.075
        }
        let codecFactor: Double = (codec == .hevc) ? 0.65 : 1.0
        let raw = pixelRate * bpp * codecFactor
        return max(2_000_000, min(200_000_000, Int(raw)))
    }
}

// MARK: - Capture source

public enum CaptureSourceSelection: Codable, Hashable, Sendable {
    case mainDisplay
    case display(id: UInt32)
    case window(id: UInt32, title: String, owner: String)
    case application(bundleID: String, name: String)
    /// Follow whichever detected game is in the foreground.
    case activeGame

    public var displayName: String {
        switch self {
        case .mainDisplay: return "Main Display"
        case .display(let id): return "Display \(id)"
        case .window(_, let title, let owner): return title.isEmpty ? owner : "\(owner) — \(title)"
        case .application(_, let name): return name
        case .activeGame: return "Active Game"
        }
    }

    public var isWindowScoped: Bool {
        if case .window = self { return true }
        if case .application = self { return true }
        if case .activeGame = self { return true }
        return false
    }
}

// MARK: - Recording configuration

public struct RecordingConfiguration: Codable, Equatable, Sendable {
    public var codec: VideoCodecOption = .h264
    public var resolution: ResolutionPreset = .p1080
    public var frameRate: FrameRateOption = .fps60
    public var bitratePreset: BitratePreset = .balanced
    /// Only consulted when `bitratePreset == .custom`.
    public var customBitrateMbps: Double = 20
    public var source: CaptureSourceSelection = .mainDisplay
    public var showsCursor: Bool = true
    public var excludeKaijuFromCapture: Bool = true
    /// Seconds between forced keyframes. Also the granularity a clip's start can
    /// be trimmed to, because clips are cut without re-encoding.
    public var keyframeIntervalSeconds: Double = 1.0
    public var requireHardwareEncoder: Bool = true

    public init() {}

    public func bitrate(width: Int, height: Int) -> Int {
        if bitratePreset == .custom {
            return max(1_000_000, Int(customBitrateMbps * 1_000_000))
        }
        return bitratePreset.bitrate(width: width, height: height,
                                     fps: frameRate.rawValue, codec: codec)
    }

    public var bitrateMbpsDescription: String {
        let size = resolution.encodeSize(forSource: CGSize(width: 3840, height: 2160))
        let bps = bitrate(width: Int(size.width), height: Int(size.height))
        return String(format: "%.0f Mbps", Double(bps) / 1_000_000)
    }
}

// MARK: - Audio

public struct AudioConfiguration: Codable, Equatable, Sendable {
    public var captureSystemAudio: Bool = true
    public var captureMicrophone: Bool = false
    public var microphoneDeviceID: String? = nil
    /// Linear gain, 0…2 (0 dB == 1.0).
    public var systemGain: Float = 1.0
    public var microphoneGain: Float = 1.0
    public var systemMuted: Bool = false
    public var microphoneMuted: Bool = false
    /// Write system audio and mic to separate tracks instead of mixing them.
    public var separateTracks: Bool = false
    /// Play the mic back through the current output device while recording.
    public var monitorMicrophone: Bool = false
    public var monitorVolume: Float = 0.5
    public var sampleRate: Double = 48_000
    public var channelCount: Int = 2
    public var audioBitrate: Int = 192_000

    public init() {}

    public var isAnySourceEnabled: Bool {
        (captureSystemAudio && !systemMuted) || (captureMicrophone && !microphoneMuted)
    }

    public var hasAnySourceConfigured: Bool {
        captureSystemAudio || captureMicrophone
    }
}

// MARK: - Replay buffer

public struct ReplayConfiguration: Codable, Equatable, Sendable {
    /// How much history the buffer holds. 15 s … 30 min.
    public var bufferSeconds: TimeInterval = 120
    /// Length saved by the Instant Replay hotkey.
    public var instantReplaySeconds: TimeInterval = 15
    /// Length saved by the Capture Clip hotkey.
    public var captureClipSeconds: TimeInterval = 30
    /// Ceiling on RAM the in-memory ring may use before spilling to disk segments.
    public var memoryBudgetMB: Int = 768
    /// Length of each on-disk segment when the buffer is disk-backed.
    public var diskSegmentSeconds: TimeInterval = 10
    /// Start the buffer as soon as the app launches.
    public var startBufferOnLaunch: Bool = false

    public static let minimumBufferSeconds: TimeInterval = 15
    public static let maximumBufferSeconds: TimeInterval = 30 * 60

    public static let selectableDurations: [TimeInterval] = [
        15, 30, 45, 60, 90, 120, 180, 300, 600, 900, 1200, 1800
    ]

    public init() {}

    /// The buffer has to be at least as long as the longest thing you can pull
    /// out of it, otherwise the hotkey would ask for history that was never kept.
    public var effectiveBufferSeconds: TimeInterval {
        let needed = max(bufferSeconds, max(instantReplaySeconds, captureClipSeconds))
        return min(max(needed, Self.minimumBufferSeconds), Self.maximumBufferSeconds)
    }

    public var memoryBudgetBytes: Int { memoryBudgetMB * 1_048_576 }
}

// MARK: - Automation / game detection

public struct AutomationConfiguration: Codable, Equatable, Sendable {
    public var automaticRecordingEnabled: Bool = true
    public var startBufferWhenGameLaunches: Bool = true
    public var stopBufferWhenGameQuits: Bool = true
    public var followActiveGameWindow: Bool = false
    public var selectedBundleIdentifiers: Set<String> = []
    public var showStatusIndicator: Bool = true
    public var indicatorCorner: IndicatorCorner = .topRight

    public enum IndicatorCorner: String, Codable, CaseIterable, Sendable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .topLeft: return "Top Left"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomRight: return "Bottom Right"
            }
        }
    }

    public init() {}
}

// MARK: - Storage

public struct StorageConfiguration: Codable, Equatable, Sendable {
    /// nil means "~/Movies/Kaiju".
    public var saveDirectoryPath: String? = nil
    public var automaticCleanupEnabled: Bool = false
    public var deleteOlderThanDays: Int? = nil
    public var maximumLibraryGigabytes: Double? = nil
    public var neverDeleteFavorites: Bool = true
    public var warnWhenFreeSpaceBelowGB: Double = 5

    public init() {}

    public var saveDirectory: URL {
        if let saveDirectoryPath, !saveDirectoryPath.isEmpty {
            return URL(fileURLWithPath: saveDirectoryPath, isDirectory: true)
        }
        return Self.defaultSaveDirectory
    }

    public static var defaultSaveDirectory: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Kaiju", isDirectory: true)
    }
}

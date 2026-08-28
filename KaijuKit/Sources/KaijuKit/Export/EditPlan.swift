import Foundation
import CoreGraphics

public struct TextOverlay: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var text: String = "Text"
    /// Normalised centre, 0…1 with the origin at top-left.
    public var position: CGPoint = CGPoint(x: 0.5, y: 0.85)
    /// Font size as a fraction of the output height, so overlays survive a
    /// resolution change without being re-laid-out.
    public var relativeFontSize: Double = 0.06
    public var colorHex: String = "FFFFFF"
    public var backgroundHex: String = "000000"
    public var backgroundOpacity: Double = 0.45
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = .greatestFiniteMagnitude
    public var isBold: Bool = true

    public init() {}

    public func isVisible(at time: TimeInterval) -> Bool {
        time >= startTime && time <= endTime
    }
}

public struct ImageOverlay: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var imagePath: String = ""
    public var position: CGPoint = CGPoint(x: 0.85, y: 0.15)
    /// Width as a fraction of output width.
    public var relativeWidth: Double = 0.18
    public var opacity: Double = 1.0
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = .greatestFiniteMagnitude

    public init() {}

    public var url: URL? { imagePath.isEmpty ? nil : URL(fileURLWithPath: imagePath) }

    public func isVisible(at time: TimeInterval) -> Bool {
        time >= startTime && time <= endTime
    }
}

public struct ZoomSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = 1
    /// 1.0 = no zoom. 2.0 = twice as close.
    public var scale: Double = 1.5
    /// Normalised focal point, 0…1.
    public var center: CGPoint = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public func contains(_ time: TimeInterval) -> Bool {
        time >= startTime && time <= endTime
    }
}

public struct VolumeSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var startTime: TimeInterval = 0
    public var endTime: TimeInterval = 1
    /// 0 = silent.
    public var gain: Float = 0

    public init() {}

    public func contains(_ time: TimeInterval) -> Bool {
        time >= startTime && time <= endTime
    }
}

/// A non-destructive description of an edit.
///
/// Nothing here touches the source file. The editor mutates a plan; export reads
/// one. That's what makes "undo" free and re-exporting at a different resolution
/// a one-line change.
public struct EditPlan: Codable, Equatable, Sendable {
    public var trimStart: TimeInterval = 0
    public var trimEnd: TimeInterval = 0
    /// Sections removed from the middle, in source time.
    public var cuts: [ClosedRangeBox] = []
    public var textOverlays: [TextOverlay] = []
    public var imageOverlays: [ImageOverlay] = []
    public var zoomSegments: [ZoomSegment] = []
    public var volumeSegments: [VolumeSegment] = []
    public var masterVolume: Float = 1.0
    /// Normalised crop, 0…1, origin top-left. `nil` means the full frame.
    public var cropRect: CGRect? = nil

    public init() {}

    public init(sourceDuration: TimeInterval) {
        trimStart = 0
        trimEnd = sourceDuration
    }

    public var hasEffects: Bool {
        !textOverlays.isEmpty || !imageOverlays.isEmpty || !zoomSegments.isEmpty
            || cropRect != nil
    }

    public var hasAudioEdits: Bool {
        masterVolume != 1.0 || !volumeSegments.isEmpty
    }

    public var hasCuts: Bool { !cuts.isEmpty }

    /// Ranges of source time that survive, in order.
    public func keptRanges() -> [ClosedRangeBox] {
        var kept: [ClosedRangeBox] = [ClosedRangeBox(lower: trimStart, upper: max(trimStart, trimEnd))]
        for cut in cuts.sorted(by: { $0.lower < $1.lower }) {
            var next: [ClosedRangeBox] = []
            for range in kept {
                if cut.upper <= range.lower || cut.lower >= range.upper {
                    next.append(range)
                    continue
                }
                if cut.lower > range.lower {
                    next.append(ClosedRangeBox(lower: range.lower, upper: cut.lower))
                }
                if cut.upper < range.upper {
                    next.append(ClosedRangeBox(lower: cut.upper, upper: range.upper))
                }
            }
            kept = next
        }
        return kept.filter { $0.upper - $0.lower > 0.01 }
    }

    public var outputDuration: TimeInterval {
        keptRanges().reduce(0) { $0 + ($1.upper - $1.lower) }
    }

    /// Maps a source time onto the output timeline, or nil if it was cut out.
    public func outputTime(forSource source: TimeInterval) -> TimeInterval? {
        var offset: TimeInterval = 0
        for range in keptRanges() {
            if source < range.lower { return nil }
            if source <= range.upper { return offset + (source - range.lower) }
            offset += range.upper - range.lower
        }
        return nil
    }

    public func volume(atSource source: TimeInterval) -> Float {
        var gain = masterVolume
        for segment in volumeSegments where segment.contains(source) {
            gain *= segment.gain
        }
        return max(0, min(4, gain))
    }
}

/// `ClosedRange` isn't `Codable` in a way that round-trips nicely inside a plan,
/// so edits carry this instead.
public struct ClosedRangeBox: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var lower: TimeInterval
    public var upper: TimeInterval

    public init(lower: TimeInterval, upper: TimeInterval) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    public var length: TimeInterval { upper - lower }
    public func contains(_ value: TimeInterval) -> Bool { value >= lower && value <= upper }
}

public struct ExportSettings: Codable, Equatable, Sendable {
    public var resolution: ResolutionPreset = .p1080
    public var frameRate: FrameRateOption = .fps60
    public var codec: VideoCodecOption = .h264
    public var bitratePreset: BitratePreset = .high
    public var customBitrateMbps: Double = 20
    public var audioBitrate: Int = 192_000
    /// Keep the source resolution and frame rate.
    public var matchSource: Bool = true

    public init() {}

    public func bitrate(width: Int, height: Int, fps: Int) -> Int {
        if bitratePreset == .custom { return max(1_000_000, Int(customBitrateMbps * 1_000_000)) }
        return bitratePreset.bitrate(width: width, height: height, fps: fps, codec: codec)
    }
}

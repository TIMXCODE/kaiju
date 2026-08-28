import Foundation
import CoreMedia

public enum KaijuTime {
    /// The clock every subsystem timestamps against. ScreenCaptureKit stamps
    /// video, system audio and microphone samples against the host clock, so
    /// using the same one here means A/V alignment is arithmetic, not guesswork.
    public static let hostClock: CMClock = CMClockGetHostTimeClock()

    public static var now: CMTime { CMClockGetTime(hostClock) }

    /// Preferred timescale for anything we author. 90 kHz divides evenly into
    /// 24/25/30/50/60/120 fps, which keeps frame durations exact.
    public static let videoTimescale: CMTimeScale = 90_000

    public static func time(seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: videoTimescale)
    }
}

public extension CMTime {
    var secondsOrZero: Double {
        isNumeric ? seconds : 0
    }
}

public extension TimeInterval {
    /// `1:04.2` style, used in the player scrubber and clip cards.
    var clipTimestampString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// `1:04.23` — used where frame-level precision matters (editor, player readout).
    var preciseTimestampString: String {
        guard isFinite, self >= 0 else { return "0:00.00" }
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let hundredths = Int((self - Double(total)) * 100)
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, hundredths)
        }
        return String(format: "%d:%02d.%02d", minutes, seconds, hundredths)
    }

    /// `15s`, `2m 30s`, `30m` — used for duration pickers and buffer labels.
    var durationLabel: String {
        let total = Int(self.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let seconds = total % 60
        if seconds == 0 { return "\(minutes)m" }
        return "\(minutes)m \(seconds)s"
    }
}

public extension Int64 {
    var fileSizeString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

import Foundation

/// Every failure the engine can produce, with a human explanation and, where one
/// exists, something the user can actually do about it. Nothing in Kaiju is
/// allowed to fail silently — this type is what makes that possible.
public enum KaijuError: LocalizedError, Equatable {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case notificationPermissionDenied
    case noCaptureSourceAvailable
    case captureSourceDisappeared(name: String)
    case captureStartFailed(reason: String)
    case captureStoppedUnexpectedly(reason: String)
    case encoderUnavailable(codec: String)
    case encoderFailed(status: Int32, stage: String)
    case unsupportedResolution(width: Int, height: Int)
    case audioDeviceUnavailable(name: String)
    case bufferEmpty
    case bufferTooShort(available: TimeInterval, requested: TimeInterval)
    case diskFull(requiredBytes: Int64, availableBytes: Int64)
    case saveLocationUnwritable(path: String)
    case clipWriteFailed(reason: String)
    case exportFailed(reason: String)
    case exportCancelled
    case hotkeyConflict(shortcut: String)
    case hotkeyRegistrationFailed(shortcut: String, status: Int32)
    case clipMissingOnDisk(name: String)
    case invalidConfiguration(reason: String)

    /// Short headline, suitable for a notification title or an alert title.
    public var title: String {
        switch self {
        case .screenRecordingPermissionDenied:  return "Screen Recording permission needed"
        case .microphonePermissionDenied:       return "Microphone permission needed"
        case .notificationPermissionDenied:     return "Notifications are off"
        case .noCaptureSourceAvailable:         return "No capture source"
        case .captureSourceDisappeared:         return "Capture source went away"
        case .captureStartFailed:               return "Couldn't start capture"
        case .captureStoppedUnexpectedly:       return "Capture stopped"
        case .encoderUnavailable:               return "Video encoder unavailable"
        case .encoderFailed:                    return "Encoder error"
        case .unsupportedResolution:            return "Unsupported resolution"
        case .audioDeviceUnavailable:           return "Audio device unavailable"
        case .bufferEmpty:                      return "Nothing in the replay buffer yet"
        case .bufferTooShort:                   return "Replay buffer is still filling"
        case .diskFull:                         return "Not enough disk space"
        case .saveLocationUnwritable:           return "Can't write to the save folder"
        case .clipWriteFailed:                  return "Clip couldn't be saved"
        case .exportFailed:                     return "Export failed"
        case .exportCancelled:                  return "Export cancelled"
        case .hotkeyConflict:                   return "Shortcut already in use"
        case .hotkeyRegistrationFailed:         return "Shortcut couldn't be registered"
        case .clipMissingOnDisk:                return "Clip file is missing"
        case .invalidConfiguration:             return "Invalid recording settings"
        }
    }

    public var errorDescription: String? { title }

    /// The "what happened" line.
    public var failureReason: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Kaiju can't see your screen, so there's nothing to record."
        case .microphonePermissionDenied:
            return "Microphone capture is enabled but macOS hasn't granted access."
        case .notificationPermissionDenied:
            return "Clip-saved confirmations won't appear in Notification Center."
        case .noCaptureSourceAvailable:
            return "No display, window, or application matched the current recording source."
        case .captureSourceDisappeared(let name):
            return "\(name) closed or moved off screen while the buffer was running."
        case .captureStartFailed(let reason):
            return reason
        case .captureStoppedUnexpectedly(let reason):
            return reason
        case .encoderUnavailable(let codec):
            return "This Mac reported no hardware encoder for \(codec)."
        case .encoderFailed(let status, let stage):
            return "VideoToolbox returned \(status) during \(stage)."
        case .unsupportedResolution(let w, let h):
            return "\(w)×\(h) isn't a valid encode size on this machine."
        case .audioDeviceUnavailable(let name):
            return "\(name) is no longer connected."
        case .bufferEmpty:
            return "The replay buffer hasn't captured any frames yet."
        case .bufferTooShort(let available, let requested):
            return String(format: "Only %.1fs is buffered; you asked for %.0fs.", available, requested)
        case .diskFull(let required, let available):
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Needs about \(need) but only \(have) is free."
        case .saveLocationUnwritable(let path):
            return "\(path) isn't writable."
        case .clipWriteFailed(let reason):
            return reason
        case .exportFailed(let reason):
            return reason
        case .exportCancelled:
            return "You stopped the export."
        case .hotkeyConflict(let shortcut):
            return "\(shortcut) is claimed by macOS or another app."
        case .hotkeyRegistrationFailed(let shortcut, let status):
            return "The system refused \(shortcut) (error \(status))."
        case .clipMissingOnDisk(let name):
            return "\(name) was moved or deleted outside Kaiju."
        case .invalidConfiguration(let reason):
            return reason
        }
    }

    /// The "here's the fix" line. `nil` means there is genuinely nothing to suggest.
    public var recoverySuggestion: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Open System Settings › Privacy & Security › Screen & System Audio Recording and turn Kaiju on."
        case .microphonePermissionDenied:
            return "Open System Settings › Privacy & Security › Microphone and turn Kaiju on, or switch mic capture off in Audio settings."
        case .notificationPermissionDenied:
            return "Open System Settings › Notifications › Kaiju to turn them back on."
        case .noCaptureSourceAvailable:
            return "Pick a different display or window in Recording settings."
        case .captureSourceDisappeared:
            return "Kaiju will fall back to your main display. Pick a new source in Recording settings if you want something else."
        case .encoderUnavailable:
            return "Switch codec to H.264 in Recording settings — every Apple Silicon Mac has a hardware H.264 encoder."
        case .unsupportedResolution:
            return "Choose one of the preset resolutions in Recording settings."
        case .audioDeviceUnavailable:
            return "Choose a different input in Audio settings."
        case .bufferTooShort:
            return "Give the buffer a few more seconds, or lower the clip length."
        case .bufferEmpty:
            return "Start the replay buffer first (⌘⌥R by default)."
        case .diskFull:
            return "Free up space, or turn on automatic cleanup in Storage settings."
        case .saveLocationUnwritable:
            return "Pick a different save folder in Settings."
        case .hotkeyConflict, .hotkeyRegistrationFailed:
            return "Choose a different combination in Hotkeys settings."
        case .clipMissingOnDisk:
            return "Remove it from the library, or put the file back where it was."
        case .encoderFailed, .captureStartFailed, .captureStoppedUnexpectedly:
            return "Try stopping and restarting the replay buffer. If it keeps happening, lower the resolution or frame rate."
        case .clipWriteFailed, .exportFailed:
            return "Check free disk space and the save folder, then try again."
        case .exportCancelled, .invalidConfiguration:
            return nil
        }
    }

    /// Errors the user should see immediately versus ones we only log.
    public var isUserFacing: Bool {
        switch self {
        case .notificationPermissionDenied: return false
        case .exportCancelled: return false
        default: return true
        }
    }
}

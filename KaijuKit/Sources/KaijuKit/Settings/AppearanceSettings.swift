import Foundation

public enum ThemeIdentifier: String, Codable, CaseIterable, Sendable, Identifiable {
    case kaiju
    case midnight
    case aurora
    case solar
    case synthwave

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kaiju:     return "Default"
        case .midnight:  return "Midnight"
        case .aurora:    return "Aurora"
        case .solar:     return "Solar"
        case .synthwave: return "Synthwave"
        }
    }

    public var blurb: String {
        switch self {
        case .kaiju:     return "Charcoal and molten orange."
        case .midnight:  return "Deep indigo, low contrast, easy at 3am."
        case .aurora:    return "Cool teal drifting into green."
        case .solar:     return "Warm amber on bone."
        case .synthwave: return "Magenta and cyan, unapologetic."
        }
    }

    /// sRGB hex triples the UI layer turns into colours. Kept here (rather than in
    /// SwiftUI) so themes are data, and so the CLI can print them.
    public var accentHex: String {
        switch self {
        case .kaiju:     return "FF6A2B"
        case .midnight:  return "6B7BFF"
        case .aurora:    return "2ED3A7"
        case .solar:     return "F2B134"
        case .synthwave: return "FF3CAC"
        }
    }

    public var secondaryAccentHex: String {
        switch self {
        case .kaiju:     return "FFB25C"
        case .midnight:  return "9B8CFF"
        case .aurora:    return "37C5D9"
        case .solar:     return "E8734A"
        case .synthwave: return "3CE0FF"
        }
    }
}

public enum ColorSchemePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

public enum AnimationIntensity: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, subtle, full
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none:   return "None"
        case .subtle: return "Subtle"
        case .full:   return "Full"
        }
    }
    /// Multiplier applied to every animation duration in the UI.
    public var durationScale: Double {
        switch self {
        case .none: return 0
        case .subtle: return 0.6
        case .full: return 1.0
        }
    }
}

public enum LayoutDensity: String, Codable, CaseIterable, Sendable, Identifiable {
    case compact, comfortable
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        }
    }
}

public struct AppearanceConfiguration: Codable, Equatable, Sendable {
    public var theme: ThemeIdentifier = .kaiju
    public var colorScheme: ColorSchemePreference = .system
    /// Overrides the theme's own accent when set.
    public var accentHexOverride: String? = nil
    public var animationIntensity: AnimationIntensity = .full
    public var density: LayoutDensity = .comfortable
    public var showDockIcon: Bool = true
    public var menuBarIconStyle: MenuBarIconStyle = .glyph

    public enum MenuBarIconStyle: String, Codable, CaseIterable, Sendable, Identifiable {
        case glyph, glyphWithStatus, statusDotOnly
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .glyph: return "Icon only"
            case .glyphWithStatus: return "Icon + buffer state"
            case .statusDotOnly: return "Status dot"
            }
        }
    }

    public init() {}

    public var effectiveAccentHex: String { accentHexOverride ?? theme.accentHex }
}

public struct NotificationConfiguration: Codable, Equatable, Sendable {
    public var clipSaved: Bool = true
    public var exportCompleted: Bool = true
    public var recordingStopped: Bool = true
    public var permissionIssues: Bool = true
    public var lowDiskSpace: Bool = true
    public var captureFailures: Bool = true
    public var playSound: Bool = false
    /// Show the small in-app toast in addition to the system notification.
    public var showInAppToast: Bool = true

    public init() {}
}

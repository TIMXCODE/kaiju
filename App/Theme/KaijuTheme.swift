import SwiftUI
import KaijuKit

/// Resolved colours and metrics for the current appearance settings.
///
/// Surfaces stay native — `windowBackgroundColor`, materials, `.primary` — so
/// Kaiju looks like a Mac app in both light and dark mode without maintaining ten
/// hand-tuned palettes. What a theme actually changes is the accent, the pair of
/// gradient stops, and a very light tint over the canvas. That's enough for the
/// five themes to feel genuinely different while never fighting the system.
struct KaijuTheme {
    var identifier: ThemeIdentifier
    var accent: Color
    var secondaryAccent: Color
    var canvasTint: Color
    var canvasTintOpacity: Double
    var animationScale: Double
    var density: LayoutDensity

    var gradient: LinearGradient {
        LinearGradient(colors: [accent, secondaryAccent],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var subtleGradient: LinearGradient {
        LinearGradient(colors: [accent.opacity(0.16), secondaryAccent.opacity(0.06)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Metrics

    var cardRadius: CGFloat { 14 }
    var cardPadding: CGFloat { density == .compact ? 14 : 18 }
    var sectionSpacing: CGFloat { density == .compact ? 18 : 26 }
    var rowSpacing: CGFloat { density == .compact ? 8 : 12 }
    var contentPadding: CGFloat { density == .compact ? 20 : 28 }

    func animation(_ base: Animation = .spring(response: 0.34, dampingFraction: 0.82)) -> Animation? {
        animationScale == 0 ? nil : base.speed(1 / max(0.25, animationScale))
    }

    static func resolve(_ configuration: AppearanceConfiguration) -> KaijuTheme {
        let accentHex = configuration.effectiveAccentHex
        let accent = Color(hex: accentHex) ?? Color(hex: ThemeIdentifier.kaiju.accentHex)!
        let secondary = configuration.accentHexOverride == nil
            ? (Color(hex: configuration.theme.secondaryAccentHex) ?? accent)
            : accent.opacity(0.75)

        let tint: Color
        let tintOpacity: Double
        switch configuration.theme {
        case .kaiju:     tint = Color(hex: "FF6A2B")!; tintOpacity = 0.030
        case .midnight:  tint = Color(hex: "3B4A9E")!; tintOpacity = 0.055
        case .aurora:    tint = Color(hex: "18A88C")!; tintOpacity = 0.045
        case .solar:     tint = Color(hex: "E8A33C")!; tintOpacity = 0.045
        case .synthwave: tint = Color(hex: "B4249E")!; tintOpacity = 0.070
        }

        return KaijuTheme(identifier: configuration.theme,
                          accent: accent,
                          secondaryAccent: secondary,
                          canvasTint: tint,
                          canvasTintOpacity: tintOpacity,
                          animationScale: configuration.animationIntensity.durationScale,
                          density: configuration.density)
    }

    static let fallback = KaijuTheme.resolve(AppearanceConfiguration())
}

private struct KaijuThemeKey: EnvironmentKey {
    static let defaultValue = KaijuTheme.fallback
}

extension EnvironmentValues {
    var theme: KaijuTheme {
        get { self[KaijuThemeKey.self] }
        set { self[KaijuThemeKey.self] = newValue }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((number >> 16) & 0xFF) / 255,
                  green: Double((number >> 8) & 0xFF) / 255,
                  blue: Double(number & 0xFF) / 255,
                  opacity: 1)
    }

    static let kaijuCanvas = Color(nsColor: .windowBackgroundColor)
    static let kaijuSurface = Color(nsColor: .controlBackgroundColor)
    static let kaijuSeparator = Color(nsColor: .separatorColor)
}

extension ColorSchemePreference {
    var swiftUIScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

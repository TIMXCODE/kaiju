import SwiftUI

/// The accent choices offered in Appearance, over and above each theme's own.
enum AccentSwatch: String, CaseIterable, Identifiable {
    case ember   = "FF6A2B"
    case crimson = "F2453D"
    case amber   = "F2B134"
    case lime    = "8BC63F"
    case jade    = "2ED3A7"
    case cyan    = "37C5D9"
    case azure   = "4A8DF2"
    case indigo  = "6B7BFF"
    case violet  = "9B6BFF"
    case magenta = "FF3CAC"

    var id: String { rawValue }
    var color: Color { Color(hex: rawValue) ?? .accentColor }

    var name: String {
        switch self {
        case .ember: return "Ember"
        case .crimson: return "Crimson"
        case .amber: return "Amber"
        case .lime: return "Lime"
        case .jade: return "Jade"
        case .cyan: return "Cyan"
        case .azure: return "Azure"
        case .indigo: return "Indigo"
        case .violet: return "Violet"
        case .magenta: return "Magenta"
        }
    }
}

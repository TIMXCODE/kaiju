import SwiftUI

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case clips
    case editor
    case games
    case recording
    case audio
    case hotkeys
    case appearance
    case storage
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:       return "Home"
        case .clips:      return "Clips"
        case .editor:     return "Editor"
        case .games:      return "Games"
        case .recording:  return "Recording"
        case .audio:      return "Audio"
        case .hotkeys:    return "Hotkeys"
        case .appearance: return "Appearance"
        case .storage:    return "Storage"
        case .settings:   return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home:       return "house"
        case .clips:      return "square.grid.2x2"
        case .editor:     return "scissors"
        case .games:      return "gamecontroller"
        case .recording:  return "record.circle"
        case .audio:      return "waveform"
        case .hotkeys:    return "keyboard"
        case .appearance: return "paintbrush"
        case .storage:    return "internaldrive"
        case .settings:   return "gearshape"
        }
    }

    static let primary: [AppSection] = [.home, .clips, .editor, .games]
    static let configuration: [AppSection] = [.recording, .audio, .hotkeys, .appearance, .storage, .settings]
}

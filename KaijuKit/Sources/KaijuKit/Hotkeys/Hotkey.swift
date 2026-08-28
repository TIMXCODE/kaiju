import Foundation

public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option  = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift   = HotkeyModifiers(rawValue: 1 << 3)

    public var symbolString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option)  { out += "⌥" }
        if contains(.shift)   { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }

    /// Carbon's `cmdKey`/`optionKey`/`controlKey`/`shiftKey` bits, which is what
    /// `RegisterEventHotKey` wants.
    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= 0x0100 } // cmdKey
        if contains(.shift)   { flags |= 0x0200 } // shiftKey
        if contains(.option)  { flags |= 0x0800 } // optionKey
        if contains(.control) { flags |= 0x1000 } // controlKey
        return flags
    }

    /// `NSEvent.ModifierFlags` raw values, without importing AppKit here.
    public init(appKitRawValue: UInt) {
        var set = HotkeyModifiers()
        if appKitRawValue & (1 << 20) != 0 { set.insert(.command) }
        if appKitRawValue & (1 << 19) != 0 { set.insert(.option) }
        if appKitRawValue & (1 << 18) != 0 { set.insert(.control) }
        if appKitRawValue & (1 << 17) != 0 { set.insert(.shift) }
        self = set
    }

    public var appKitRawValue: UInt {
        var raw: UInt = 0
        if contains(.command) { raw |= (1 << 20) }
        if contains(.option)  { raw |= (1 << 19) }
        if contains(.control) { raw |= (1 << 18) }
        if contains(.shift)   { raw |= (1 << 17) }
        return raw
    }

    /// A shortcut with no modifier would swallow plain typing everywhere, so we
    /// require at least one of command/option/control.
    public var isSufficientForGlobalHotkey: Bool {
        contains(.command) || contains(.option) || contains(.control)
    }
}

public struct Hotkey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var displayString: String {
        modifiers.symbolString + KeyCodeNames.name(for: keyCode)
    }

    public var isValid: Bool {
        modifiers.isSufficientForGlobalHotkey && KeyCodeNames.isKnown(keyCode)
    }
}

public enum KeyCodeNames {
    private static let table: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        65: "Num .", 67: "Num *", 69: "Num +", 71: "Num Clear", 75: "Num /", 76: "Num ↩",
        78: "Num -", 81: "Num =", 82: "Num 0", 83: "Num 1", 84: "Num 2", 85: "Num 3",
        86: "Num 4", 87: "Num 5", 88: "Num 6", 89: "Num 7", 91: "Num 8", 92: "Num 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 110: "Menu", 111: "F12",
        113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]

    public static func name(for keyCode: UInt32) -> String {
        table[keyCode] ?? "Key \(keyCode)"
    }

    public static func isKnown(_ keyCode: UInt32) -> Bool {
        table[keyCode] != nil
    }
}

// MARK: - Actions

public enum HotkeyAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case captureClip
    case instantReplay
    case toggleBuffer
    case toggleWindow
    case toggleMicrophoneMute
    case markMoment

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .captureClip:          return "Capture Clip"
        case .instantReplay:        return "Instant Replay"
        case .toggleBuffer:         return "Start / Stop Replay Buffer"
        case .toggleWindow:         return "Show / Hide Kaiju"
        case .toggleMicrophoneMute: return "Mute / Unmute Microphone"
        case .markMoment:           return "Mark Moment"
        }
    }

    public var subtitle: String {
        switch self {
        case .captureClip:          return "Saves the longer capture length from the buffer."
        case .instantReplay:        return "Saves the instant replay length from the buffer."
        case .toggleBuffer:         return "Turns the rolling buffer on or off."
        case .toggleWindow:         return "Brings the main window forward, or hides it."
        case .toggleMicrophoneMute: return "Mutes the mic without stopping the buffer."
        case .markMoment:           return "Drops a marker you can jump to when you save a clip."
        }
    }

    public var symbolName: String {
        switch self {
        case .captureClip:          return "scissors"
        case .instantReplay:        return "bolt.fill"
        case .toggleBuffer:         return "record.circle"
        case .toggleWindow:         return "macwindow"
        case .toggleMicrophoneMute: return "mic.slash"
        case .markMoment:           return "flag"
        }
    }

    public var defaultHotkey: Hotkey? {
        switch self {
        case .captureClip:          return Hotkey(keyCode: 8,  modifiers: [.command, .option]) // ⌘⌥C
        case .instantReplay:        return Hotkey(keyCode: 34, modifiers: [.command, .option]) // ⌘⌥I
        case .toggleBuffer:         return Hotkey(keyCode: 15, modifiers: [.command, .option]) // ⌘⌥R
        case .toggleWindow:         return Hotkey(keyCode: 4,  modifiers: [.command, .option]) // ⌘⌥H
        case .toggleMicrophoneMute: return Hotkey(keyCode: 46, modifiers: [.command, .option]) // ⌘⌥M
        case .markMoment:           return nil
        }
    }
}

public struct HotkeyConfiguration: Codable, Equatable, Sendable {
    public var bindings: [String: Hotkey]

    public init() {
        var initial: [String: Hotkey] = [:]
        for action in HotkeyAction.allCases {
            if let key = action.defaultHotkey { initial[action.rawValue] = key }
        }
        bindings = initial
    }

    public subscript(action: HotkeyAction) -> Hotkey? {
        get { bindings[action.rawValue] }
        set { bindings[action.rawValue] = newValue }
    }

    /// Actions that share the same key combination.
    public func conflictingActions() -> [Hotkey: [HotkeyAction]] {
        var byKey: [Hotkey: [HotkeyAction]] = [:]
        for action in HotkeyAction.allCases {
            guard let key = bindings[action.rawValue] else { continue }
            byKey[key, default: []].append(action)
        }
        return byKey.filter { $0.value.count > 1 }
    }

    public static func resetToDefaults() -> HotkeyConfiguration { HotkeyConfiguration() }
}

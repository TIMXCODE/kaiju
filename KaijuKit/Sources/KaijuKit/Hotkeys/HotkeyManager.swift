import Foundation
import Combine
import Carbon.HIToolbox
import AppKit

/// Bridges Carbon's hot-key API, which is still the only way to get a shortcut
/// that fires while a full-screen game has keyboard focus.
///
/// The alternative — a CGEvent tap — needs Accessibility permission and sees every
/// keystroke the user types. Carbon needs neither, so Kaiju asks for one fewer
/// permission and never touches keys it wasn't given.
final class CarbonHotkeyRegistry {
    static let shared = CarbonHotkeyRegistry()

    private let lock = UnfairLock()
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextIdentifier: UInt32 = 1

    private init() {}

    static let signature: OSType = 0x4B41494A  // 'KAIJ'

    func installIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var reference: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            let result = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotkeyID)
            guard result == noErr else { return result }
            CarbonHotkeyRegistry.shared.fire(hotkeyID.id)
            return noErr
        }, 1, &eventType, nil, &reference)

        if status == noErr {
            eventHandler = reference
        } else {
            KaijuLog.hotkeys.error("Couldn't install the hot-key event handler (\(status)).")
        }
    }

    fileprivate func fire(_ identifier: UInt32) {
        let handler = lock.withLock { handlers[identifier] }
        guard let handler else { return }
        DispatchQueue.main.async(execute: handler)
    }

    func register(keyCode: UInt32, carbonModifiers: UInt32,
                  handler: @escaping () -> Void) -> (reference: EventHotKeyRef, identifier: UInt32)? {
        installIfNeeded()
        let identifier = lock.withLock { () -> UInt32 in
            let value = nextIdentifier
            nextIdentifier += 1
            return value
        }
        var reference: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hotkeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            KaijuLog.hotkeys.notice("RegisterEventHotKey refused key \(keyCode) mods \(carbonModifiers): \(status)")
            return nil
        }
        lock.withLock { handlers[identifier] = handler }
        return (reference, identifier)
    }

    func unregister(reference: EventHotKeyRef, identifier: UInt32) {
        _ = UnregisterEventHotKey(reference)
        lock.withLock { handlers[identifier] = nil }
    }
}

@MainActor
public final class HotkeyManager: ObservableObject {
    /// Currently live bindings.
    @Published public private(set) var active: [HotkeyAction: Hotkey] = [:]
    /// Problems the user needs to see, keyed by action.
    @Published public private(set) var problems: [HotkeyAction: KaijuError] = [:]
    /// Set while a shortcut recorder is capturing, so global keys stand down and
    /// the user can actually assign ⌘⌥C to something else.
    @Published public var isCapturing = false {
        didSet {
            if isCapturing { suspend() } else { resume() }
        }
    }

    public var onTrigger: ((HotkeyAction) -> Void)?

    private var registrations: [HotkeyAction: (reference: EventHotKeyRef, identifier: UInt32)] = [:]
    private var lastConfiguration = HotkeyConfiguration()
    private var isSuspended = false

    public init() {}

    deinit {
        for entry in registrations.values {
            CarbonHotkeyRegistry.shared.unregister(reference: entry.reference, identifier: entry.identifier)
        }
    }

    // MARK: - Applying a configuration

    public func apply(_ configuration: HotkeyConfiguration) {
        lastConfiguration = configuration
        unregisterAll()
        guard !isSuspended else { return }

        var newProblems: [HotkeyAction: KaijuError] = [:]
        var live: [HotkeyAction: Hotkey] = [:]

        let duplicates = configuration.conflictingActions()
        for (hotkey, actions) in duplicates {
            for action in actions {
                newProblems[action] = .hotkeyConflict(shortcut: hotkey.displayString)
            }
        }

        for action in HotkeyAction.allCases {
            guard let hotkey = configuration[action] else { continue }
            guard hotkey.isValid else {
                newProblems[action] = .hotkeyRegistrationFailed(
                    shortcut: hotkey.displayString, status: -1)
                continue
            }
            if duplicates[hotkey] != nil { continue }
            if let reserved = SystemShortcuts.conflict(for: hotkey) {
                newProblems[action] = .hotkeyConflict(shortcut: "\(hotkey.displayString) — \(reserved)")
                continue
            }

            let entry = CarbonHotkeyRegistry.shared.register(
                keyCode: hotkey.keyCode,
                carbonModifiers: hotkey.modifiers.carbonFlags
            ) { [weak self] in
                self?.onTrigger?(action)
            }

            if let entry {
                registrations[action] = entry
                live[action] = hotkey
            } else {
                newProblems[action] = .hotkeyConflict(shortcut: hotkey.displayString)
            }
        }

        active = live
        problems = newProblems
        if !newProblems.isEmpty {
            KaijuLog.hotkeys.notice("\(newProblems.count) shortcut(s) couldn't be registered.")
        }
    }

    public func unregisterAll() {
        for entry in registrations.values {
            CarbonHotkeyRegistry.shared.unregister(reference: entry.reference, identifier: entry.identifier)
        }
        registrations.removeAll()
        active = [:]
    }

    private func suspend() {
        isSuspended = true
        unregisterAll()
    }

    private func resume() {
        guard isSuspended else { return }
        isSuspended = false
        apply(lastConfiguration)
    }

    public func binding(for action: HotkeyAction) -> Hotkey? { active[action] }

    public func displayString(for action: HotkeyAction) -> String {
        active[action]?.displayString ?? lastConfiguration[action]?.displayString ?? "Not set"
    }
}

/// A curated list of combinations macOS keeps for itself. Registering these
/// usually "succeeds" and then never fires, which looks like a Kaiju bug — so we
/// refuse them up front and say why.
public enum SystemShortcuts {
    private static let reserved: [(keyCode: UInt32, modifiers: HotkeyModifiers, owner: String)] = [
        (49, [.command], "Spotlight / input source"),
        (49, [.control], "Input source"),
        (48, [.command], "App switcher"),
        (48, [.control], "Window switcher"),
        (53, [.command, .option], "Force Quit"),
        (12, [.command], "Quit application"),
        (13, [.command], "Close window"),
        (17, [.command], "Hide others"),
        (4,  [.command], "Hide application"),
        (0,  [.command], "Select all"),
        (3,  [.command, .control], "Full screen"),
        (43, [.command], "Settings"),
        (20, [.command, .shift, .control], "Screenshot to clipboard"),
        (21, [.command, .shift], "Screenshot tools"),
        (23, [.command, .shift], "Screenshot region"),
        (22, [.command, .shift], "Screenshot window")
    ]

    public static func conflict(for hotkey: Hotkey) -> String? {
        reserved.first {
            $0.keyCode == hotkey.keyCode && $0.modifiers == hotkey.modifiers
        }?.owner
    }
}

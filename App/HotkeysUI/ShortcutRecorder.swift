import SwiftUI
import AppKit
import KaijuKit

/// Click, press a combination, done.
///
/// While it's recording, the app's global hot keys are suspended — otherwise
/// pressing ⌘⌥C to reassign it would fire Capture Clip instead of being recorded.
struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey?
    @Binding var isCapturing: Bool
    var hasProblem: Bool

    @State private var isRecordingThis = false
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            if isRecordingThis {
                RecorderCaptureView(onCapture: handle, onCancel: stop)
                    .frame(width: 120, height: 24)
            } else {
                Button {
                    start()
                } label: {
                    Text(hotkey?.displayString ?? "Not set")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .frame(width: 108, height: 24)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.kaijuSeparator.opacity(0.32))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(hasProblem ? Color.orange.opacity(0.7)
                                                         : Color.kaijuSeparator.opacity(0.6),
                                              lineWidth: 0.6)
                        }
                        .foregroundStyle(hotkey == nil ? .secondary : .primary)
                }
                .buttonStyle(.plain)
            }

            Button {
                hotkey = nil
                stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hotkey == nil ? 0.25 : 1)
            .disabled(hotkey == nil)
            .help("Clear this shortcut")
        }
        .overlay(alignment: .bottomTrailing) {
            if let hint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .offset(y: 14)
            }
        }
    }

    private func start() {
        isRecordingThis = true
        isCapturing = true
        hint = nil
    }

    private func stop() {
        isRecordingThis = false
        isCapturing = false
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let converted = HotkeyModifiers(appKitRawValue: modifiers.rawValue)
        guard converted.isSufficientForGlobalHotkey else {
            hint = "Needs ⌘, ⌥ or ⌃"
            return
        }
        let candidate = Hotkey(keyCode: UInt32(keyCode), modifiers: converted)
        guard candidate.isValid else {
            hint = "That key can't be used"
            return
        }
        if let owner = SystemShortcuts.conflict(for: candidate) {
            hint = "Used by \(owner)"
            return
        }
        hotkey = candidate
        stop()
    }
}

/// The actual key catcher. A plain `NSView` that takes first responder and reports
/// the first non-modifier key press.
private struct RecorderCaptureView: NSViewRepresentable {
    var onCapture: (UInt16, NSEvent.ModifierFlags) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    final class CaptureView: NSView {
        var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()

            let text = "Press keys…" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.controlAccentColor
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2),
                      withAttributes: attributes)
        }

        override func keyDown(with event: NSEvent) {
            // Escape backs out without changing anything.
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            onCapture?(event.keyCode, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }

        override func flagsChanged(with event: NSEvent) {
            // Modifiers alone aren't a shortcut; wait for a real key.
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            onCancel?()
            return true
        }
    }
}

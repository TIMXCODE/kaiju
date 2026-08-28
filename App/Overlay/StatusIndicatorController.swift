import SwiftUI
import AppKit
import Combine
import KaijuKit

/// The small floating "buffer is live" indicator.
///
/// It's a non-activating panel above normal windows: visible over a game, never
/// stealing focus, never appearing in a capture (Kaiju excludes itself from its
/// own recordings), and never in the way — it ignores clicks entirely.
@MainActor
final class StatusIndicatorController {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private weak var engine: ReplayEngine?
    private weak var state: AppState?

    init(engine: ReplayEngine, state: AppState) {
        self.engine = engine
        self.state = state

        engine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        state.settings.$settings
            .map(\.automation)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
    }

    private func sync() {
        guard let engine, let state else { return }
        let automation = state.settings.settings.automation
        let shouldShow = automation.showStatusIndicator && engine.isRunning
        if shouldShow {
            show(corner: automation.indicatorCorner)
        } else {
            hide()
        }
    }

    private func show(corner: AutomationConfiguration.IndicatorCorner) {
        guard let engine, let state else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 34),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false

            let host = NSHostingView(rootView:
                StatusIndicatorView()
                    .environmentObject(engine)
                    .environmentObject(state)
                    .environment(\.theme, state.theme))
            host.frame = panel.contentView?.bounds ?? .zero
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            self.panel = panel
        }
        position(panel, corner: corner)
        panel?.orderFrontRegardless()
    }

    private func position(_ panel: NSPanel?, corner: AutomationConfiguration.IndicatorCorner) {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 18
        let origin: NSPoint
        switch corner {
        case .topLeft:
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case .topRight:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        case .bottomLeft:
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case .bottomRight:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        }
        panel.setFrameOrigin(origin)
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}

struct StatusIndicatorView: View {
    @EnvironmentObject private var engine: ReplayEngine
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 7) {
            BufferStatusDot(state: engine.state, size: 7)
            Text("REC")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1)
            Text(engine.bufferStatus.bufferedSeconds.durationLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(theme.accent.opacity(0.4), lineWidth: 0.5) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

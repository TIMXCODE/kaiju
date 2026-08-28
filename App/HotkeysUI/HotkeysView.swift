import SwiftUI
import KaijuKit

struct HotkeysView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hotkeys: HotkeyManager
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                explainerCard
                Card {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionHeader(title: "Shortcuts", systemImage: "keyboard")
                        ForEach(HotkeyAction.allCases) { action in
                            HotkeyRow(action: action)
                            if action != HotkeyAction.allCases.last { Divider() }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        settings.settings.hotkeys = HotkeyConfiguration.resetToDefaults()
                    }
                    .controlSize(.small)
                }
            }
            .padding(theme.contentPadding)
        }
    }

    private var explainerCard: some View {
        Card(tinted: true) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.badge.clock")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("These work inside games")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Kaiju registers system-wide hot keys, so they fire even when a full-screen game has keyboard focus. It does this without Accessibility permission and never sees any key you didn't assign.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct HotkeyRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var hotkeys: HotkeyManager
    @Environment(\.theme) private var theme
    var action: HotkeyAction

    private var problem: KaijuError? { hotkeys.problems[action] }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: action.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(theme.accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName).font(.system(size: 13))
                Text(action.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let problem {
                    Text(problem.failureReason ?? problem.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 12)

            ShortcutRecorder(hotkey: Binding(
                get: { settings.settings.hotkeys[action] },
                set: { settings.settings.hotkeys[action] = $0 }),
                             isCapturing: $hotkeys.isCapturing,
                             hasProblem: problem != nil)
        }
        .padding(.vertical, 8)
    }
}

import SwiftUI
import KaijuKit

/// First-run setup.
///
/// Written to answer the question people actually have — "why does this app want
/// to see my screen?" — before asking. It polls while it's open, so flipping the
/// switch in System Settings updates this screen without a restart.
struct PermissionSetupView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var wantsMicrophone: Bool { settings.settings.audio.captureMicrophone }

    private var canContinue: Bool {
        permissions.screenRecording == .granted
            && (!wantsMicrophone || permissions.microphone == .granted)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    permissionCard(.screenRecording)
                    permissionCard(.microphone)
                    permissionCard(.notifications)
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .background(Color.kaijuCanvas)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            KaijuMark().frame(width: 52, height: 52)
            Text("Set up Kaiju")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Two permissions, and only one of them is required. Here's exactly what each is for.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }

    private func permissionCard(_ kind: PermissionKind) -> some View {
        let status = permissions.status(for: kind)
        return Card(tinted: status == .granted) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 11) {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 17))
                        .foregroundStyle(status == .granted ? theme.accent : .secondary)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(kind.displayName).font(.system(size: 14, weight: .semibold))
                            if kind.isRequired {
                                BadgeView(text: "Required", tint: .orange)
                            } else {
                                BadgeView(text: "Optional", tint: .secondary)
                            }
                        }
                        statusLabel(status)
                    }
                    Spacer()
                    if status == .granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(theme.accent)
                    }
                }

                Text(kind.rationale)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if status != .granted {
                    HStack(spacing: 9) {
                        Button(status == .notDetermined ? "Allow…" : "Open System Settings") {
                            Task { await permissions.request(kind) }
                        }
                        .buttonStyle(.borderedProminent)

                        if status == .denied {
                            Text("Turn Kaiju on in the list, then come back here.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Text("Granted").font(.system(size: 11)).foregroundStyle(theme.accent)
        case .denied:
            Text("Not granted").font(.system(size: 11)).foregroundStyle(.orange)
        case .notDetermined:
            Text("Not asked yet").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            if !canContinue {
                Label("Kaiju can't record until Screen Recording is on.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Later") { finish() }
                .keyboardShortcut(.cancelAction)
            Button("Start Clipping") { finish() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
        .padding(16)
    }

    private func finish() {
        settings.settings.hasCompletedFirstRun = true
        app.isShowingPermissionSetup = false
        dismiss()
    }
}

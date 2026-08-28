import SwiftUI
import AppKit
import KaijuKit

struct GeneralSettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var exports: ExportManager
    @EnvironmentObject private var engine: ReplayEngine
    @Environment(\.theme) private var theme

    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.sectionSpacing) {
                permissionsCard
                notificationsCard
                if !exports.jobs.isEmpty { exportsCard }
                diagnosticsCard
                aboutCard
            }
            .padding(theme.contentPadding)
        }
        .task { permissions.refreshAll() }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your clips are untouched — only preferences go back to defaults.")
        }
    }

    private var permissionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader(title: "Permissions", systemImage: "lock.shield")
                    Spacer()
                    Button("Open setup") { app.isShowingPermissionSetup = true }
                        .controlSize(.small)
                }
                ForEach(PermissionKind.allCases) { kind in
                    HStack(spacing: 11) {
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(permissions.status(for: kind) == .granted
                                             ? theme.accent : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(kind.displayName).font(.system(size: 12))
                            Text(statusText(permissions.status(for: kind)))
                                .font(.system(size: 10))
                                .foregroundStyle(permissions.status(for: kind) == .granted
                                                 ? .secondary : .orange)
                        }
                        Spacer()
                        if permissions.status(for: kind) != .granted {
                            Button("Fix") { Task { await permissions.request(kind) } }
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent)
                        }
                    }
                }
            }
        }
    }

    private func statusText(_ status: PermissionStatus) -> String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .notDetermined: return "Not asked yet"
        }
    }

    private var notificationsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Notifications",
                              subtitle: "Kept sparse on purpose. An app that talks constantly is one you turn off.",
                              systemImage: "bell")

                toggleRow("Clip saved", "The small confirmation after a hotkey.",
                          $settings.settings.notifications.clipSaved)
                toggleRow("Export finished", nil,
                          $settings.settings.notifications.exportCompleted)
                toggleRow("Recording stopped", "When the buffer stops on its own.",
                          $settings.settings.notifications.recordingStopped)
                toggleRow("Permission problems", nil,
                          $settings.settings.notifications.permissionIssues)
                toggleRow("Low disk space", nil,
                          $settings.settings.notifications.lowDiskSpace)
                toggleRow("Capture failures", nil,
                          $settings.settings.notifications.captureFailures)

                Divider().padding(.vertical, 4)

                toggleRow("Show in-app confirmations", "The toast inside Kaiju's own window.",
                          $settings.settings.notifications.showInAppToast)
                toggleRow("Play a sound", nil, $settings.settings.notifications.playSound)
            }
        }
    }

    private func toggleRow(_ title: String, _ detail: String?, _ binding: Binding<Bool>) -> some View {
        SettingRow(title: title, detail: detail) {
            Toggle("", isOn: binding).toggleStyle(.switch).labelsHidden()
        }
    }

    private var exportsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: "Exports", systemImage: "square.and.arrow.up")
                    Spacer()
                    Button("Clear finished") { exports.clearFinished() }
                        .controlSize(.small)
                        .disabled(exports.jobs.allSatisfy { $0.state.isActive })
                }
                ForEach(exports.jobs) { job in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).font(.system(size: 12)).lineLimit(1)
                            Text(job.state.label)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if job.state.isActive {
                            ProgressView(value: job.progress)
                                .progressViewStyle(.linear)
                                .frame(width: 110)
                            Button("Cancel") { exports.cancel(job.id) }
                                .controlSize(.small)
                        } else if job.state == .finished {
                            Button("Show") {
                                NSWorkspace.shared.activateFileViewerSelecting([job.outputURL])
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Diagnostics", systemImage: "stethoscope")
                infoRow("Machine", SystemMetrics.machineDescription())
                infoRow("Architecture", SystemMetrics.isAppleSilicon ? "Apple Silicon" : "Intel")
                infoRow("Buffer backend", engine.backend.displayName)
                infoRow("Settings file", SettingsStore.defaultFileURL.path)
                HStack {
                    Button("Reveal settings folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.defaultFileURL])
                    }
                    .controlSize(.small)
                    Spacer()
                    Button("Reset all settings", role: .destructive) { confirmReset = true }
                        .controlSize(.small)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var aboutCard: some View {
        Card(tinted: true) {
            HStack(spacing: 14) {
                KaijuMark().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kaiju")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Rolling replay buffer for macOS. Native Swift, ScreenCaptureKit, VideoToolbox — no third-party dependencies.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }
}

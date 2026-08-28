import SwiftUI
import KaijuKit

/// Live numbers, all of them real.
///
/// CPU and memory come from mach, the frame rate is counted from stream
/// callbacks, the bitrate is measured from bytes the encoder actually emitted, and
/// the buffer figures come from the ring itself. Nothing here is a placeholder,
/// which is the only way a panel like this is worth having.
struct PerformancePanel: View {
    @EnvironmentObject private var performance: PerformanceMonitor
    @EnvironmentObject private var engine: ReplayEngine
    @Environment(\.theme) private var theme

    private var snapshot: PerformanceSnapshot { performance.snapshot }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(title: "Performance", systemImage: "gauge.with.needle")
                    Spacer()
                    if snapshot.encoderRunning {
                        BadgeView(text: snapshot.encoderIsHardware ? "Hardware" : "Software",
                                  systemImage: snapshot.encoderIsHardware ? "bolt.fill" : "cpu",
                                  tint: snapshot.encoderIsHardware ? theme.accent : .orange)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
                          spacing: 14) {
                    StatTile(label: "Kaiju CPU",
                             value: String(format: "%.1f%%", snapshot.cpuPercent),
                             caption: "\(snapshot.threadCount) threads",
                             systemImage: "cpu",
                             accent: snapshot.cpuPercent > 40 ? .orange : nil,
                             fill: min(1, snapshot.cpuPercent / 100))

                    StatTile(label: "Kaiju memory",
                             value: String(format: "%.0f MB", Double(snapshot.memoryBytes) / 1_048_576),
                             caption: "system \(Int(snapshot.systemMemoryFraction * 100))% used",
                             systemImage: "memorychip",
                             fill: snapshot.systemMemoryFraction)

                    StatTile(label: "Capture",
                             value: snapshot.captureFPS > 0
                                ? String(format: "%.0f fps", snapshot.captureFPS) : "—",
                             caption: snapshot.targetFPS > 0 ? "target \(snapshot.targetFPS)" : nil,
                             systemImage: "video",
                             accent: fpsAccent,
                             fill: snapshot.targetFPS > 0
                                ? min(1, snapshot.captureFPS / Double(snapshot.targetFPS)) : 0)

                    StatTile(label: "Encoder",
                             value: snapshot.measuredBitrateLabel,
                             caption: "\(snapshot.encoderCodec) · set \(snapshot.configuredBitrateLabel)",
                             systemImage: "square.stack.3d.down.right")

                    StatTile(label: "Buffer",
                             value: snapshot.bufferedSeconds.durationLabel,
                             caption: snapshot.bufferBackend,
                             systemImage: "clock.arrow.circlepath",
                             fill: snapshot.bufferFillFraction)

                    StatTile(label: "Dropped",
                             value: "\(snapshot.framesDropped)",
                             caption: snapshot.framesIdle > 0
                                ? "\(snapshot.framesIdle) idle frames skipped" : nil,
                             systemImage: "exclamationmark.triangle",
                             accent: snapshot.framesDropped > 30 ? .orange : nil)
                }

                Divider()

                HStack(spacing: 18) {
                    footNote("Resolution", snapshot.resolutionLabel)
                    footNote("Buffer RAM", snapshot.bufferMemoryBytes > 0
                             ? Int64(snapshot.bufferMemoryBytes).fileSizeString : "—")
                    footNote("Buffer disk", snapshot.bufferDiskBytes > 0
                             ? Int64(snapshot.bufferDiskBytes).fileSizeString : "—")
                    footNote("Free space", snapshot.availableDiskBytes.fileSizeString)
                }
            }
        }
    }

    private var fpsAccent: Color? {
        guard snapshot.targetFPS > 0, snapshot.captureFPS > 0 else { return nil }
        return snapshot.captureFPS < Double(snapshot.targetFPS) * 0.8 ? .orange : nil
    }

    private func footNote(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

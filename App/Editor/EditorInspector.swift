import SwiftUI
import KaijuKit

/// The right-hand inspector. Trim numbers, then whatever the clip actually has —
/// overlays, zooms, muted sections — each removable in one click.
struct EditorInspector: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var player: PlayerModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                trimSection
                audioSection
                if !model.plan.textOverlays.isEmpty { textSection }
                if !model.plan.imageOverlays.isEmpty { imageSection }
                if !model.plan.zoomSegments.isEmpty { zoomSection }
                if !model.plan.cuts.isEmpty { cutSection }
                if !model.plan.volumeSegments.isEmpty { volumeSection }
                cropSection
            }
            .padding(14)
        }
    }

    private var trimSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Trim", systemImage: "timeline.selection")
                HStack {
                    Text("Start").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(model.plan.trimStart.preciseTimestampString)
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                HStack {
                    Text("End").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(model.plan.trimEnd.preciseTimestampString)
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                Divider()
                HStack {
                    Text("Output").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(model.outputDurationLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.accent)
                }
            }
        }
    }

    private var audioSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Audio", systemImage: "waveform")
                HStack {
                    Text("Volume").font(.system(size: 11))
                    Spacer()
                    Text("\(Int(model.plan.masterVolume * 100))%")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(model.plan.masterVolume) },
                    set: { value in model.mutate { $0.masterVolume = Float(value) } }
                ), in: 0...2)
                Button {
                    model.muteRange(from: player.currentTime,
                                    to: min(model.plan.trimEnd, player.currentTime + 2))
                } label: {
                    Label("Mute 2s from playhead", systemImage: "speaker.slash")
                }
                .controlSize(.small)
            }
        }
    }

    private var textSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Text overlays", systemImage: "textformat")
                ForEach(model.plan.textOverlays) { overlay in
                    textEditor(for: overlay)
                    if overlay.id != model.plan.textOverlays.last?.id { Divider() }
                }
            }
        }
    }

    private func textEditor(for overlay: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                TextField("Text", text: binding(for: overlay, keyPath: \.text))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button {
                    model.removeTextOverlay(overlay.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("Size").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: binding(for: overlay, keyPath: \.relativeFontSize), in: 0.02...0.18)
                Text("\(Int(overlay.relativeFontSize * 100))")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Text("X").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { overlay.position.x },
                    set: { value in update(overlay) { $0.position.x = value } }), in: 0...1)
                Text("Y").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { overlay.position.y },
                    set: { value in update(overlay) { $0.position.y = value } }), in: 0...1)
            }

            HStack(spacing: 8) {
                Text("From").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(overlay.startTime.clipTimestampString)
                    .font(.system(size: 10)).monospacedDigit()
                Button("Set") { update(overlay) { $0.startTime = player.currentTime } }
                    .buttonStyle(.link).font(.system(size: 10))
                Spacer()
                Text("To").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text(min(overlay.endTime, model.plan.trimEnd).clipTimestampString)
                    .font(.system(size: 10)).monospacedDigit()
                Button("Set") { update(overlay) { $0.endTime = player.currentTime } }
                    .buttonStyle(.link).font(.system(size: 10))
            }

            HStack(spacing: 8) {
                Toggle("Bold", isOn: binding(for: overlay, keyPath: \.isBold))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                Spacer()
                Text("Backdrop").font(.system(size: 10)).foregroundStyle(.tertiary)
                Slider(value: binding(for: overlay, keyPath: \.backgroundOpacity), in: 0...1)
                    .frame(width: 70)
            }
        }
        .padding(.vertical, 2)
    }

    private var imageSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Image overlays", systemImage: "photo")
                ForEach(model.plan.imageOverlays) { overlay in
                    HStack {
                        Text(URL(fileURLWithPath: overlay.imagePath).lastPathComponent)
                            .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            model.removeImageOverlay(overlay.id)
                        } label: { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("Size").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Slider(value: Binding(
                            get: { overlay.relativeWidth },
                            set: { value in updateImage(overlay) { $0.relativeWidth = value } }),
                               in: 0.04...0.6)
                        Text("Opacity").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Slider(value: Binding(
                            get: { overlay.opacity },
                            set: { value in updateImage(overlay) { $0.opacity = value } }), in: 0...1)
                    }
                }
            }
        }
    }

    private var zoomSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Zoom", systemImage: "plus.magnifyingglass")
                ForEach(model.plan.zoomSegments) { zoom in
                    HStack {
                        Text("\(zoom.startTime.clipTimestampString) → \(zoom.endTime.clipTimestampString)")
                            .font(.system(size: 11)).monospacedDigit()
                        Spacer()
                        Text("\(zoom.scale, specifier: "%.1f")×")
                            .font(.system(size: 11, weight: .medium))
                        Button {
                            model.removeZoom(zoom.id)
                        } label: { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { zoom.scale },
                        set: { value in updateZoom(zoom) { $0.scale = value } }), in: 1...4)
                }
            }
        }
    }

    private var cutSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Cuts", systemImage: "scissors")
                ForEach(model.plan.cuts) { cut in
                    HStack {
                        Text("\(cut.lower.clipTimestampString) → \(cut.upper.clipTimestampString)")
                            .font(.system(size: 11)).monospacedDigit()
                        Spacer()
                        Text("−\(cut.length.durationLabel)")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        Button {
                            model.removeCut(cut.id)
                        } label: { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var volumeSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Muted sections", systemImage: "speaker.slash")
                ForEach(model.plan.volumeSegments) { segment in
                    HStack {
                        Text("\(segment.startTime.clipTimestampString) → \(segment.endTime.clipTimestampString)")
                            .font(.system(size: 11)).monospacedDigit()
                        Spacer()
                        Button {
                            model.removeVolumeSegment(segment.id)
                        } label: { Image(systemName: "trash").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var cropSection: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Crop", systemImage: "crop")
                if let crop = model.plan.cropRect {
                    Text(String(format: "%.0f%% × %.0f%% of the frame",
                                crop.width * 100, crop.height * 100))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("Width").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Slider(value: Binding(
                            get: { crop.width },
                            set: { value in model.mutate {
                                $0.cropRect?.size.width = value
                                $0.cropRect?.origin.x = min($0.cropRect!.origin.x, 1 - value)
                            } }), in: 0.2...1)
                    }
                    HStack(spacing: 8) {
                        Text("Height").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Slider(value: Binding(
                            get: { crop.height },
                            set: { value in model.mutate {
                                $0.cropRect?.size.height = value
                                $0.cropRect?.origin.y = min($0.cropRect!.origin.y, 1 - value)
                            } }), in: 0.2...1)
                    }
                    Button("Remove crop") { model.mutate { $0.cropRect = nil } }
                        .buttonStyle(.link).font(.system(size: 11))
                } else {
                    Button("Crop to 80%") {
                        model.mutate {
                            $0.cropRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Bindings

    private func binding<Value>(for overlay: TextOverlay,
                                keyPath: WritableKeyPath<TextOverlay, Value>) -> Binding<Value> {
        Binding(
            get: {
                model.plan.textOverlays.first { $0.id == overlay.id }?[keyPath: keyPath]
                    ?? overlay[keyPath: keyPath]
            },
            set: { value in update(overlay) { $0[keyPath: keyPath] = value } }
        )
    }

    private func update(_ overlay: TextOverlay, _ change: (inout TextOverlay) -> Void) {
        model.mutate { plan in
            guard let index = plan.textOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
            change(&plan.textOverlays[index])
        }
    }

    private func updateImage(_ overlay: ImageOverlay, _ change: (inout ImageOverlay) -> Void) {
        model.mutate { plan in
            guard let index = plan.imageOverlays.firstIndex(where: { $0.id == overlay.id }) else { return }
            change(&plan.imageOverlays[index])
        }
    }

    private func updateZoom(_ zoom: ZoomSegment, _ change: (inout ZoomSegment) -> Void) {
        model.mutate { plan in
            guard let index = plan.zoomSegments.firstIndex(where: { $0.id == zoom.id }) else { return }
            change(&plan.zoomSegments[index])
        }
    }
}

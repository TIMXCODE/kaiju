import SwiftUI
import AppKit
import Combine
import KaijuKit

@MainActor
final class EditorModel: ObservableObject {
    @Published var plan = EditPlan()
    @Published private(set) var clip: Clip?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var thumbnails: [NSImage] = []
    @Published private(set) var isLoadingAssets = false
    @Published var selectedTextOverlayID: UUID?
    @Published var exportSettings = ExportSettings()
    @Published var isShowingExportSheet = false

    /// Undo is just a stack of whole plans — they're small value types, and this
    /// makes every edit reversible without per-operation bookkeeping.
    private var undoStack: [EditPlan] = []
    private var redoStack: [EditPlan] = []
    private var loadedClipID: UUID?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func load(clip: Clip, directory: URL) {
        guard clip.id != loadedClipID else { return }
        loadedClipID = clip.id
        self.clip = clip
        let url = clip.url(in: directory)
        sourceURL = url
        plan = EditPlan(sourceDuration: clip.duration)
        undoStack.removeAll()
        redoStack.removeAll()
        waveform = []
        thumbnails = []

        Task {
            isLoadingAssets = true
            async let peaks = EditorAssets.waveform(for: url)
            async let strip = EditorAssets.thumbnailStrip(for: url, count: 24, height: 54)
            waveform = await peaks
            thumbnails = await strip
            isLoadingAssets = false
        }
    }

    // MARK: - Mutation with undo

    func mutate(_ change: (inout EditPlan) -> Void) {
        undoStack.append(plan)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        var copy = plan
        change(&copy)
        plan = copy
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(plan)
        plan = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(plan)
        plan = next
    }

    func reset() {
        guard let clip else { return }
        mutate { $0 = EditPlan(sourceDuration: clip.duration) }
    }

    // MARK: - Operations

    func trimStart(to time: TimeInterval) {
        mutate { $0.trimStart = min(max(0, time), $0.trimEnd - 0.2) }
    }

    func trimEnd(to time: TimeInterval) {
        guard let clip else { return }
        mutate { $0.trimEnd = max(min(clip.duration, time), $0.trimStart + 0.2) }
    }

    /// Splits at the playhead by starting a new cut region there. The second call
    /// closes it, which is how "split then delete the middle" feels natural
    /// without a separate mode.
    func addCut(from start: TimeInterval, to end: TimeInterval) {
        guard end - start > 0.05 else { return }
        mutate { $0.cuts.append(ClosedRangeBox(lower: start, upper: end)) }
    }

    func removeCut(_ id: UUID) {
        mutate { $0.cuts.removeAll { $0.id == id } }
    }

    func addTextOverlay(at time: TimeInterval) {
        var overlay = TextOverlay()
        overlay.startTime = time
        overlay.endTime = min(plan.trimEnd, time + 3)
        mutate { $0.textOverlays.append(overlay) }
        selectedTextOverlayID = overlay.id
    }

    func removeTextOverlay(_ id: UUID) {
        mutate { $0.textOverlays.removeAll { $0.id == id } }
        if selectedTextOverlayID == id { selectedTextOverlayID = nil }
    }

    func addImageOverlay(url: URL, at time: TimeInterval) {
        var overlay = ImageOverlay()
        overlay.imagePath = url.path
        overlay.startTime = time
        overlay.endTime = plan.trimEnd
        mutate { $0.imageOverlays.append(overlay) }
    }

    func removeImageOverlay(_ id: UUID) {
        mutate { $0.imageOverlays.removeAll { $0.id == id } }
    }

    func addZoom(at time: TimeInterval) {
        var zoom = ZoomSegment()
        zoom.startTime = time
        zoom.endTime = min(plan.trimEnd, time + 2)
        mutate { $0.zoomSegments.append(zoom) }
    }

    func removeZoom(_ id: UUID) {
        mutate { $0.zoomSegments.removeAll { $0.id == id } }
    }

    func muteRange(from start: TimeInterval, to end: TimeInterval) {
        guard end > start else { return }
        var segment = VolumeSegment()
        segment.startTime = start
        segment.endTime = end
        segment.gain = 0
        mutate { $0.volumeSegments.append(segment) }
    }

    func removeVolumeSegment(_ id: UUID) {
        mutate { $0.volumeSegments.removeAll { $0.id == id } }
    }

    var outputDurationLabel: String {
        plan.outputDuration.preciseTimestampString
    }
}

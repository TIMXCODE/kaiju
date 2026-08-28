import SwiftUI
import KaijuKit

/// The editor timeline: frames on top, waveform under them, trim handles at the
/// ends, cut regions in between, and a playhead you can drag.
struct ClipTimelineView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var player: PlayerModel
    @Environment(\.theme) private var theme

    var duration: TimeInterval

    @State private var draggingHandle: Handle?

    enum Handle { case start, end, playhead }

    private let trackHeight: CGFloat = 76
    private let waveHeight: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)

            ZStack(alignment: .topLeading) {
                thumbnailStrip
                waveformStrip
                dimmedRegions(width: width)
                cutRegions(width: width)
                zoomMarkers(width: width)
                overlayMarkers(width: width)
                trimHandles(width: width)
                playhead(width: width)
            }
            .frame(height: trackHeight + waveHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.kaijuSeparator.opacity(0.6), lineWidth: 0.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = self.time(at: value.location.x, width: width)
                        if draggingHandle == nil {
                            draggingHandle = nearestHandle(to: value.location.x, width: width)
                        }
                        switch draggingHandle {
                        case .start:    model.trimStart(to: time)
                        case .end:      model.trimEnd(to: time)
                        default:        player.seek(to: time)
                        }
                    }
                    .onEnded { _ in draggingHandle = nil }
            )
        }
        .frame(height: trackHeight + waveHeight)
    }

    // MARK: - Layers

    private var thumbnailStrip: some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                Rectangle().fill(Color.kaijuSeparator.opacity(0.25))
            } else {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        }
        .frame(height: trackHeight)
        .clipped()
    }

    private var waveformStrip: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            GeometryReader { proxy in
                let width = proxy.size.width
                let peaks = model.waveform
                Canvas { context, size in
                    guard !peaks.isEmpty else { return }
                    let step = max(1, peaks.count / max(1, Int(width)))
                    var path = Path()
                    let midY = size.height / 2
                    var index = 0
                    var x: CGFloat = 0
                    let dx = size.width / CGFloat(max(1, peaks.count / step))
                    while index < peaks.count {
                        let value = CGFloat(peaks[index])
                        let half = max(0.5, value * midY * 0.94)
                        path.move(to: CGPoint(x: x, y: midY - half))
                        path.addLine(to: CGPoint(x: x, y: midY + half))
                        index += step
                        x += dx
                    }
                    context.stroke(path, with: .color(theme.accent.opacity(0.85)), lineWidth: 1)
                }
            }
            .frame(height: waveHeight)
            .background(Color.black.opacity(0.35))
        }
    }

    private func dimmedRegions(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.black.opacity(0.55))
                .frame(width: position(of: model.plan.trimStart, width: width))
            Spacer(minLength: 0)
            Rectangle()
                .fill(.black.opacity(0.55))
                .frame(width: max(0, width - position(of: model.plan.trimEnd, width: width)))
        }
        .allowsHitTesting(false)
    }

    private func cutRegions(width: CGFloat) -> some View {
        ForEach(model.plan.cuts) { cut in
            let x = position(of: cut.lower, width: width)
            let w = max(2, position(of: cut.upper, width: width) - x)
            ZStack {
                Rectangle().fill(.red.opacity(0.30))
                Rectangle().strokeBorder(.red.opacity(0.8), lineWidth: 1)
                Image(systemName: "scissors")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: w)
            .offset(x: x)
            .onTapGesture { model.removeCut(cut.id) }
            .help("Cut — click to remove")
        }
    }

    private func zoomMarkers(width: CGFloat) -> some View {
        ForEach(model.plan.zoomSegments) { zoom in
            let x = position(of: zoom.startTime, width: width)
            let w = max(2, position(of: zoom.endTime, width: width) - x)
            Rectangle()
                .fill(theme.secondaryAccent.opacity(0.35))
                .frame(width: w, height: 5)
                .offset(x: x, y: trackHeight - 5)
                .onTapGesture { model.removeZoom(zoom.id) }
                .help("Zoom — click to remove")
        }
    }

    private func overlayMarkers(width: CGFloat) -> some View {
        ForEach(model.plan.textOverlays) { overlay in
            let x = position(of: overlay.startTime, width: width)
            let end = min(overlay.endTime, model.plan.trimEnd)
            let w = max(3, position(of: end, width: width) - x)
            Rectangle()
                .fill(Color.white.opacity(model.selectedTextOverlayID == overlay.id ? 0.85 : 0.45))
                .frame(width: w, height: 4)
                .offset(x: x, y: 2)
                .onTapGesture { model.selectedTextOverlayID = overlay.id }
        }
    }

    private func trimHandles(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            handle(at: position(of: model.plan.trimStart, width: width), leading: true)
            handle(at: position(of: model.plan.trimEnd, width: width), leading: false)
        }
    }

    private func handle(at x: CGFloat, leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(theme.accent)
            .frame(width: 8, height: trackHeight + waveHeight)
            .overlay {
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(.white.opacity(0.8)).frame(width: 2, height: 2)
                    }
                }
            }
            .offset(x: max(0, x - (leading ? 0 : 8)))
            .shadow(color: .black.opacity(0.3), radius: 3)
    }

    private func playhead(width: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: trackHeight + waveHeight)
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
                .offset(y: -3)
        }
        .offset(x: position(of: player.currentTime, width: width) - 1)
        .shadow(color: .black.opacity(0.45), radius: 2)
        .allowsHitTesting(false)
    }

    // MARK: - Geometry

    private func position(of time: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / duration))) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(duration, max(0, Double(x / width) * duration))
    }

    private func nearestHandle(to x: CGFloat, width: CGFloat) -> Handle {
        let startX = position(of: model.plan.trimStart, width: width)
        let endX = position(of: model.plan.trimEnd, width: width)
        if abs(x - startX) < 12 { return .start }
        if abs(x - endX) < 12 { return .end }
        return .playhead
    }
}

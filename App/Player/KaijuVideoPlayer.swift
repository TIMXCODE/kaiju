import SwiftUI
import AVFoundation
import AppKit
import KaijuKit

struct PlayerLayerView: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)
        context.coordinator.playerLayer = playerLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.playerLayer?.player = player
        context.coordinator.playerLayer?.frame = nsView.bounds
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var playerLayer: AVPlayerLayer?
    }
}

/// The built-in player: transport, scrubber, volume, speed, frame readout, and a
/// keyboard map that matches what people expect from a video app.
struct KaijuVideoPlayer: View {
    @Environment(\.theme) private var theme
    @StateObject private var model = PlayerModel()

    var url: URL
    var showsControls = true
    var compact = false

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var isHoveringSurface = false

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerLayerView(player: model.player)
                .background(Color.black)
                .onTapGesture { model.togglePlayback() }

            if let error = model.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.7))
            } else if showsControls {
                controls
                    .opacity(isHoveringSurface || !model.isPlaying ? 1 : 0)
                    .animation(theme.animation(.easeOut(duration: 0.2)), value: isHoveringSurface)
            }
        }
        .onHover { isHoveringSurface = $0 }
        .task(id: url) { model.load(url: url) }
        .onDisappear { model.pause() }
        .focusable()
        .onKeyPress(.space) { model.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { model.step(frames: -1); return .handled }
        .onKeyPress(.rightArrow) { model.step(frames: 1); return .handled }
        .onKeyPress("j") { model.skip(seconds: -10); return .handled }
        .onKeyPress("k") { model.togglePlayback(); return .handled }
        .onKeyPress("l") { model.skip(seconds: 10); return .handled }
        .onKeyPress("m") { model.isMuted.toggle(); return .handled }
    }

    private var controls: some View {
        VStack(spacing: 7) {
            scrubber

            HStack(spacing: 12) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                if !compact {
                    Button { model.step(frames: -1) } label: {
                        Image(systemName: "backward.frame.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    Button { model.step(frames: 1) } label: {
                        Image(systemName: "forward.frame.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }

                Text("\(displayTime.preciseTimestampString) / \(model.duration.preciseTimestampString)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()

                if !compact {
                    Text("f\(model.frameNumber)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer()

                if !compact {
                    Menu {
                        ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { speed in
                            Button(speed == 1 ? "Normal" : "\(speed, specifier: "%g")×") {
                                model.rate = speed
                            }
                        }
                    } label: {
                        Text(model.rate == 1 ? "1×" : "\(model.rate, specifier: "%g")×")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Button { model.isMuted.toggle() } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)

                if !compact {
                    Slider(value: $model.volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 68)
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    private var displayTime: TimeInterval {
        isScrubbing ? scrubTime : model.currentTime
    }

    private var scrubber: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(2, width * progressValue))
                Circle()
                    .fill(.white)
                    .frame(width: 10, height: 10)
                    .offset(x: max(0, width * progressValue - 5))
                    .shadow(radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        let fraction = min(1, max(0, value.location.x / max(1, width)))
                        scrubTime = model.duration * fraction
                        model.seek(to: scrubTime)
                    }
                    .onEnded { _ in isScrubbing = false }
            )
        }
        .frame(height: 10)
    }

    private var progressValue: Double {
        guard model.duration > 0 else { return 0 }
        return min(1, max(0, displayTime / model.duration))
    }
}

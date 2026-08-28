import SwiftUI
import AVFoundation
import Combine
import KaijuKit

/// Playback state for the built-in player.
///
/// AVKit's `VideoPlayer` gives you Apple's controls and nothing else. Driving
/// `AVPlayer` directly is what lets the player share the editor's timeline, honour
/// the app's keyboard map, and show frame-accurate time.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?
    @Published var volume: Double = 1 { didSet { player.volume = Float(volume) } }
    @Published var isMuted = false { didSet { player.isMuted = isMuted } }
    @Published var rate: Double = 1 { didSet { if isPlaying { player.rate = Float(rate) } } }
    @Published var frameRate: Double = 60

    let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private(set) var url: URL?

    /// Range the scrubber is limited to. The editor sets this to the trim range so
    /// preview playback matches what will be exported.
    var playbackRange: ClosedRange<TimeInterval>?

    init() {
        player.actionAtItemEnd = .pause
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            if let range = self.playbackRange, self.currentTime > range.upperBound {
                self.pause()
                self.seek(to: range.upperBound)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(url: URL) {
        guard url != self.url else { return }
        self.url = url
        isReady = false
        loadError = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = "This clip isn't on disk any more."
            return
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        player.volume = Float(volume)
        player.isMuted = isMuted

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isReady = true
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                case .failed:
                    self.loadError = item.error?.localizedDescription ?? "This clip couldn't be opened."
                default:
                    break
                }
            }
        }

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false }
        }

        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let nominal = try? await track.load(.nominalFrameRate), nominal > 0 {
                frameRate = Double(nominal)
            }
            if let assetDuration = try? await asset.load(.duration), assetDuration.seconds.isFinite {
                duration = assetDuration.seconds
            }
        }
    }

    func play() {
        if let range = playbackRange, currentTime >= range.upperBound - 0.02 {
            seek(to: range.lowerBound)
        }
        player.rate = Float(rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlayback() { isPlaying ? pause() : play() }

    func seek(to seconds: TimeInterval) {
        let clamped = clamp(seconds)
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) / max(1, frameRate))
    }

    func skip(seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func clamp(_ seconds: TimeInterval) -> TimeInterval {
        let lower = playbackRange?.lowerBound ?? 0
        let upper = playbackRange?.upperBound ?? max(0, duration)
        return min(max(lower, seconds), max(lower, upper))
    }

    var frameNumber: Int { Int((currentTime * frameRate).rounded()) }

    var progress: Double {
        let lower = playbackRange?.lowerBound ?? 0
        let upper = playbackRange?.upperBound ?? duration
        guard upper > lower else { return 0 }
        return min(1, max(0, (currentTime - lower) / (upper - lower)))
    }
}

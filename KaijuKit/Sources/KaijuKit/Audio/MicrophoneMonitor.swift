import Foundation
import AVFoundation

/// Plays microphone audio back through the current output device so you can hear
/// yourself while recording.
///
/// Deliberately fed from the same converted chunks the mixer sees, so monitoring
/// reflects the gain and mute the clip will actually get.
final class MicrophoneMonitor {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var isRunning = false
    private var scheduledBuffers = 0
    private let maximumScheduledBuffers = 12
    private let lock = UnfairLock()

    init?(format: AVAudioFormat) {
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    func start() {
        guard !isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            KaijuLog.audio.error("Monitoring couldn't start: \(String(describing: error))")
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        lock.withLock { scheduledBuffers = 0 }
    }

    func enqueue(_ samples: UnsafePointer<Float>, frameCount: Int) {
        guard isRunning, frameCount > 0 else { return }

        // Never let the playback queue grow: monitoring that drifts behind is
        // worse than monitoring that drops a chunk.
        let pending = lock.withLock { scheduledBuffers }
        guard pending < maximumScheduledBuffers else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let destination = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let channels = Int(format.channelCount)
        if format.isInterleaved {
            destination[0].update(from: samples, count: frameCount * channels)
        } else {
            for channel in 0..<channels {
                for frame in 0..<frameCount {
                    destination[channel][frame] = samples[frame * channels + channel]
                }
            }
        }

        lock.withLock { scheduledBuffers += 1 }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.scheduledBuffers = max(0, self.scheduledBuffers - 1) }
        }
    }
}

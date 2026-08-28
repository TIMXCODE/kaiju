import Foundation
import QuartzCore
import AVFoundation
import CoreMedia

public enum AudioTrackKind: String, Sendable, Hashable, CaseIterable {
    case mixed
    case system
    case microphone

    public var trackName: String {
        switch self {
        case .mixed:      return "Audio"
        case .system:     return "Game & Desktop"
        case .microphone: return "Microphone"
        }
    }
}

public struct AudioLevelSnapshot: Sendable, Equatable {
    public var systemPeak: Float = 0
    public var systemRMS: Float = 0
    public var microphonePeak: Float = 0
    public var microphoneRMS: Float = 0
    public var systemActive = false
    public var microphoneActive = false

    public init() {}
}

protocol AudioMixerDelegate: AnyObject {
    /// Interleaved float frames in the mixer's output format. Called on the
    /// capture audio queue; copy and return.
    func audioMixer(_ mixer: AudioMixer,
                    didProduce samples: UnsafePointer<Float>,
                    frameCount: Int,
                    pts: CMTime,
                    track: AudioTrackKind)
}

/// Aligns system audio and microphone audio onto one timeline, applies per-source
/// gain and mute, and emits fixed-size chunks.
///
/// The timeline is anchored to the first audio sample's presentation timestamp,
/// which comes off the same host clock ScreenCaptureKit stamps video with. That
/// is what keeps a saved clip in sync: audio isn't nudged to fit, it's placed
/// where its own timestamp says it goes.
final class AudioMixer {
    weak var delegate: AudioMixerDelegate?
    /// Microphone-only tap for live monitoring. Kept separate from the delegate so
    /// monitoring never plays system audio back into the room, which would be a
    /// feedback loop rather than a feature.
    var onMicrophoneMonitorChunk: ((UnsafePointer<Float>, Int) -> Void)?

    let outputFormat: AVAudioFormat
    private let sampleRate: Double
    private let channels: Int
    private let chunkFrames = 1024

    private var configuration: AudioConfiguration
    private let configurationLock = UnfairLock()

    private let systemRing: PCMJitterRing
    private let microphoneRing: PCMJitterRing
    private var systemConverter: AudioSampleConverter?
    private var microphoneConverter: AudioSampleConverter?

    private var anchor: CMTime?
    private var mixCursor: Int = 0
    private var scratch: [Float]

    private var monitorScratch: [Float]
    private let levelLock = UnfairLock()
    private var levels = AudioLevelSnapshot()

    /// A source quiet for longer than this is treated as absent, so a dead mic
    /// can't stall the mix by never advancing its write index.
    private let stalenessThreshold: CFTimeInterval = 0.25

    init?(configuration: AudioConfiguration) {
        let rate = configuration.sampleRate
        let channelCount = max(1, configuration.channelCount)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: true) else { return nil }
        self.outputFormat = format
        self.sampleRate = rate
        self.channels = channelCount
        self.configuration = configuration
        // Two seconds of slack absorbs any realistic scheduling jitter between
        // the two sources without adding latency to the common case.
        let capacity = Int(rate * 2)
        self.systemRing = PCMJitterRing(capacityFrames: capacity, channels: channelCount)
        self.microphoneRing = PCMJitterRing(capacityFrames: capacity, channels: channelCount)
        self.scratch = [Float](repeating: 0, count: chunkFrames * channelCount)
        self.monitorScratch = [Float](repeating: 0, count: chunkFrames * channelCount)
        self.systemConverter = AudioSampleConverter(sampleRate: rate, channels: channelCount)
        self.microphoneConverter = AudioSampleConverter(sampleRate: rate, channels: channelCount)
    }

    var currentLevels: AudioLevelSnapshot { levelLock.withLock { levels } }

    func updateConfiguration(_ configuration: AudioConfiguration) {
        configurationLock.withLock { self.configuration = configuration }
    }

    private var config: AudioConfiguration { configurationLock.withLock { configuration } }

    func reset() {
        systemRing.reset()
        microphoneRing.reset()
        anchor = nil
        mixCursor = 0
        levelLock.withLock { levels = AudioLevelSnapshot() }
    }

    /// Called on the capture engine's audio queue, one source at a time.
    func ingest(_ sampleBuffer: CMSampleBuffer, from source: AudioSourceKind) {
        let converter = (source == .system) ? systemConverter : microphoneConverter
        guard let converter else { return }

        converter.withConvertedSamples(from: sampleBuffer) { samples, frameCount, pts in
            if anchor == nil { anchor = pts }
            guard let anchor else { return }

            let offsetSeconds = CMTimeGetSeconds(CMTimeSubtract(pts, anchor))
            guard offsetSeconds.isFinite else { return }
            let index = Int((offsetSeconds * sampleRate).rounded())
            guard index >= 0 else { return }

            measure(samples, frameCount: frameCount, source: source)

            switch source {
            case .system:     systemRing.write(samples, frames: frameCount, at: index)
            case .microphone: microphoneRing.write(samples, frames: frameCount, at: index)
            }
        }

        drain()
    }

    // MARK: - Levels

    private func measure(_ samples: UnsafePointer<Float>, frameCount: Int, source: AudioSourceKind) {
        var peak: Float = 0
        var sumSquares: Float = 0
        let total = frameCount * channels
        var index = 0
        while index < total {
            let value = samples[index]
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
            sumSquares += value * value
            index += 1
        }
        let rms = total > 0 ? (sumSquares / Float(total)).squareRoot() : 0

        levelLock.withLock {
            switch source {
            case .system:
                // Peak falls back gradually so the meter reads like a meter and
                // not like a strobe.
                levels.systemPeak = max(peak, levels.systemPeak * 0.82)
                levels.systemRMS = rms
                levels.systemActive = true
            case .microphone:
                levels.microphonePeak = max(peak, levels.microphonePeak * 0.82)
                levels.microphoneRMS = rms
                levels.microphoneActive = true
            }
        }
    }

    // MARK: - Draining

    private func drain() {
        guard let anchor else { return }
        let settings = config
        let now = CACurrentMediaTime()

        let systemLive = settings.captureSystemAudio && systemRing.isStarted
            && (now - systemRing.lastWriteTime) < stalenessThreshold
        let microphoneLive = settings.captureMicrophone && microphoneRing.isStarted
            && (now - microphoneRing.lastWriteTime) < stalenessThreshold

        levelLock.withLock {
            levels.systemActive = systemLive
            levels.microphoneActive = microphoneLive
            if !systemLive { levels.systemPeak *= 0.5; levels.systemRMS = 0 }
            if !microphoneLive { levels.microphonePeak *= 0.5; levels.microphoneRMS = 0 }
        }

        var ready = Int.max
        if systemLive { ready = min(ready, systemRing.writtenUpTo) }
        if microphoneLive { ready = min(ready, microphoneRing.writtenUpTo) }
        guard ready != Int.max else { return }

        // Jumping the cursor forward after a long stall keeps the mixer from
        // trying to emit minutes of backlog in one go.
        if mixCursor + Int(sampleRate * 3) < ready {
            mixCursor = max(0, ready - chunkFrames)
        }

        let systemGain = settings.systemMuted ? 0 : settings.systemGain
        let microphoneGain = settings.microphoneMuted ? 0 : settings.microphoneGain

        while mixCursor + chunkFrames <= ready {
            if settings.separateTracks {
                if settings.captureSystemAudio {
                    emit(ring: systemRing, gain: systemGain, track: .system, anchor: anchor)
                }
                if settings.captureMicrophone {
                    emit(ring: microphoneRing, gain: microphoneGain, track: .microphone, anchor: anchor)
                }
            } else {
                emitMixed(systemGain: systemGain, microphoneGain: microphoneGain, anchor: anchor)
            }
            if settings.captureMicrophone && settings.monitorMicrophone {
                emitMonitorChunk(gain: microphoneGain)
            }
            mixCursor += chunkFrames
        }
    }

    private func chunkTime(anchor: CMTime) -> CMTime {
        CMTimeAdd(anchor, CMTime(value: Int64(mixCursor), timescale: CMTimeScale(sampleRate)))
    }

    private func emitMixed(systemGain: Float, microphoneGain: Float, anchor: CMTime) {
        let settings = config
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(repeating: 0, count: buffer.count)
            if settings.captureSystemAudio {
                systemRing.mix(into: base, frames: chunkFrames, at: mixCursor, gain: systemGain)
            }
            if settings.captureMicrophone {
                microphoneRing.mix(into: base, frames: chunkFrames, at: mixCursor, gain: microphoneGain)
            }
            // Two full-scale sources summed can exceed ±1. Soft-clip rather than
            // wrap, so a loud game plus a loud mic distorts gracefully.
            softClip(base, count: buffer.count)
            delegate?.audioMixer(self, didProduce: UnsafePointer(base),
                                 frameCount: chunkFrames,
                                 pts: chunkTime(anchor: anchor),
                                 track: .mixed)
        }
    }

    private func emit(ring: PCMJitterRing, gain: Float, track: AudioTrackKind, anchor: CMTime) {
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(repeating: 0, count: buffer.count)
            ring.mix(into: base, frames: chunkFrames, at: mixCursor, gain: gain)
            softClip(base, count: buffer.count)
            delegate?.audioMixer(self, didProduce: UnsafePointer(base),
                                 frameCount: chunkFrames,
                                 pts: chunkTime(anchor: anchor),
                                 track: track)
        }
    }

    private func emitMonitorChunk(gain: Float) {
        guard let handler = onMicrophoneMonitorChunk else { return }
        monitorScratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(repeating: 0, count: buffer.count)
            microphoneRing.mix(into: base, frames: chunkFrames, at: mixCursor, gain: gain)
            handler(UnsafePointer(base), chunkFrames)
        }
    }

    private func softClip(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        var index = 0
        while index < count {
            let value = samples[index]
            if value > 1 || value < -1 {
                // tanh-ish knee without the transcendental cost
                let sign: Float = value < 0 ? -1 : 1
                let magnitude = min(abs(value), 2.0)
                samples[index] = sign * (1 - (2 - magnitude) * (2 - magnitude) * 0.25)
            }
            index += 1
        }
    }
}

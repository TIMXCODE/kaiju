import Foundation
import QuartzCore

/// A short circular PCM buffer addressed by *absolute frame index*.
///
/// System audio and microphone audio arrive on their own schedules and in their
/// own chunk sizes. Writing both into frame-indexed rings turns "line these two
/// streams up" into arithmetic: each source lands at the index its timestamp says
/// it belongs at, gaps become silence, and the mixer reads a common index range
/// out of both.
final class PCMJitterRing {
    let capacityFrames: Int
    let channels: Int

    private var storage: [Float]
    private(set) var writtenUpTo: Int = 0
    private var hasStarted = false
    /// Wall-clock of the last write, used to notice a source that has gone away.
    private(set) var lastWriteTime: CFTimeInterval = 0
    private(set) var discontinuityCount: Int = 0

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = max(1024, capacityFrames)
        self.channels = max(1, channels)
        self.storage = [Float](repeating: 0, count: self.capacityFrames * self.channels)
    }

    var isStarted: Bool { hasStarted }

    func reset() {
        hasStarted = false
        writtenUpTo = 0
        discontinuityCount = 0
        lastWriteTime = 0
        for index in storage.indices { storage[index] = 0 }
    }

    func write(_ source: UnsafePointer<Float>, frames: Int, at index: Int) {
        guard frames > 0 else { return }
        lastWriteTime = CACurrentMediaTime()

        if !hasStarted {
            hasStarted = true
            writtenUpTo = index
        }

        if index > writtenUpTo {
            let gap = index - writtenUpTo
            if gap >= capacityFrames {
                // Longer than the ring: everything buffered is stale anyway.
                discontinuityCount += 1
                zeroAll()
                writtenUpTo = index
            } else {
                zero(from: writtenUpTo, count: gap)
                writtenUpTo = index
            }
        }

        // Clamp a write that is older than anything we still hold.
        var writeIndex = index
        var writeFrames = frames
        var sourceOffset = 0
        let oldestValid = max(0, writtenUpTo - capacityFrames)
        if writeIndex < oldestValid {
            let skip = oldestValid - writeIndex
            if skip >= writeFrames { return }
            sourceOffset = skip
            writeIndex += skip
            writeFrames -= skip
        }
        if writeFrames > capacityFrames {
            sourceOffset += writeFrames - capacityFrames
            writeIndex += writeFrames - capacityFrames
            writeFrames = capacityFrames
        }

        storage.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            var remaining = writeFrames
            var absolute = writeIndex
            var offset = sourceOffset
            while remaining > 0 {
                let physical = absolute % capacityFrames
                let run = min(remaining, capacityFrames - physical)
                base.advanced(by: physical * channels)
                    .update(from: source.advanced(by: offset * channels), count: run * channels)
                remaining -= run
                absolute += run
                offset += run
            }
        }

        writtenUpTo = max(writtenUpTo, writeIndex + writeFrames)
    }

    /// Adds `frames` starting at `index` into `destination`, scaled by `gain`.
    /// Anything not held any more contributes silence, which is exactly right:
    /// a source that stalled shouldn't shift everything else in time.
    func mix(into destination: UnsafeMutablePointer<Float>, frames: Int, at index: Int, gain: Float) {
        guard frames > 0, gain != 0, hasStarted else { return }
        let oldestValid = max(0, writtenUpTo - capacityFrames)

        storage.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            var remaining = frames
            var absolute = index
            var offset = 0
            while remaining > 0 {
                guard absolute >= oldestValid, absolute < writtenUpTo else {
                    // Outside what we hold — silence. Advance one frame at a time
                    // only at the edges; this loop is not hot.
                    remaining -= 1
                    absolute += 1
                    offset += 1
                    continue
                }
                let available = min(writtenUpTo - absolute, remaining)
                let physical = absolute % capacityFrames
                let run = min(available, capacityFrames - physical)
                let sourceBase = base.advanced(by: physical * channels)
                let destinationBase = destination.advanced(by: offset * channels)
                for sample in 0..<(run * channels) {
                    destinationBase[sample] += sourceBase[sample] * gain
                }
                remaining -= run
                absolute += run
                offset += run
            }
        }
    }

    private func zero(from index: Int, count: Int) {
        guard count > 0 else { return }
        storage.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            var remaining = count
            var absolute = index
            while remaining > 0 {
                let physical = absolute % capacityFrames
                let run = min(remaining, capacityFrames - physical)
                base.advanced(by: physical * channels)
                    .update(repeating: 0, count: run * channels)
                remaining -= run
                absolute += run
            }
        }
    }

    private func zeroAll() {
        storage.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            base.update(repeating: 0, count: destination.count)
        }
    }
}

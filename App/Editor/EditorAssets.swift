import Foundation
import AVFoundation
import AppKit
import CoreMedia
import KaijuKit

/// Pulls the two things the timeline needs to be readable: a strip of frames and
/// an audio envelope. Both are computed once per clip, off the main thread.
enum EditorAssets {

    /// Peak amplitude per bucket, 0…1.
    static func waveform(for url: URL, buckets: Int = 900) async -> [Float] {
        await Task.detached(priority: .utility) { () async -> [Float] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }

            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let sampleRate = (try? await track.load(.naturalTimeScale)).map(Double.init) ?? 48_000
            let channels = 2.0
            let totalSamples = max(1.0, duration * sampleRate * channels)
            let samplesPerBucket = max(1, Int(totalSamples / Double(buckets)))

            var peaks = [Float](repeating: 0, count: buckets)
            var bucket = 0
            var counter = 0
            var runningPeak: Float = 0

            while let sample = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var lengthAtOffset = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                                  lengthAtOffsetOut: &lengthAtOffset,
                                                  totalLengthOut: &length,
                                                  dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                      let pointer, lengthAtOffset >= length else { continue }

                let count = length / MemoryLayout<Float>.size
                pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                    for index in 0..<count {
                        let magnitude = abs(samples[index])
                        if magnitude > runningPeak { runningPeak = magnitude }
                        counter += 1
                        if counter >= samplesPerBucket {
                            if bucket < buckets { peaks[bucket] = min(1, runningPeak) }
                            bucket += 1
                            counter = 0
                            runningPeak = 0
                        }
                    }
                }
                if bucket >= buckets { break }
            }
            reader.cancelReading()
            return peaks
        }.value
    }

    /// Evenly spaced frames across the clip, sized for the timeline strip.
    static func thumbnailStrip(for url: URL, count: Int, height: CGFloat) async -> [NSImage] {
        await Task.detached(priority: .utility) { () async -> [NSImage] in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.seconds.isFinite, duration.seconds > 0 else { return [] }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: height * 4, height: height * 2)
            // Loose tolerances: the strip is a map, not a frame-accurate preview,
            // and exact seeks here would make it crawl.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

            var images: [NSImage] = []
            for index in 0..<count {
                let fraction = (Double(index) + 0.5) / Double(count)
                let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
                guard let result = try? await generator.image(at: time) else { continue }
                images.append(NSImage(cgImage: result.image,
                                      size: NSSize(width: result.image.width,
                                                   height: result.image.height)))
            }
            return images
        }.value
    }
}

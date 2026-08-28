import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// Renders an `EditPlan` to a new file.
///
/// Decode is hardware, the per-frame work is Core Image on a Metal device, and
/// encode is VideoToolbox through `AVAssetWriter`. The CPU's job is bookkeeping,
/// which is why exporting doesn't lock up the machine mid-game.
enum VideoExportPipeline {

    struct Request {
        var sourceURL: URL
        var outputURL: URL
        var plan: EditPlan
        var settings: ExportSettings
        var overlays: [PreparedOverlay]
    }

    struct Cancellation: Error {}

    static func run(_ request: Request,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> URL {

        let asset = AVURLAsset(url: request.sourceURL,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw KaijuError.exportFailed(reason: "The source has no video track.")
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        let sourceSize = try await naturalDisplaySize(of: videoTrack)
        let sourceFrameRate = Int(((try? await videoTrack.load(.nominalFrameRate)) ?? 60).rounded())

        // Work out the output geometry: crop first, then fit the chosen preset.
        let cropped = request.plan.cropRect.map { rect -> CGSize in
            CGSize(width: sourceSize.width * rect.width, height: sourceSize.height * rect.height)
        } ?? sourceSize

        let outputSize: CGSize
        if request.settings.matchSource {
            outputSize = evenSize(cropped)
        } else {
            outputSize = evenSize(request.settings.resolution.encodeSize(forSource: cropped))
        }
        let outputFrameRate = request.settings.matchSource
            ? max(1, sourceFrameRate)
            : request.settings.frameRate.rawValue

        guard outputSize.width >= 2, outputSize.height >= 2 else {
            throw KaijuError.unsupportedResolution(width: Int(outputSize.width),
                                                   height: Int(outputSize.height))
        }

        try? FileManager.default.removeItem(at: request.outputURL)
        try FileManager.default.createDirectory(at: request.outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        // MARK: Reader

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw KaijuError.exportFailed(reason: error.localizedDescription)
        }
        let readStart = CMTime(seconds: request.plan.trimStart, preferredTimescale: 600)
        let readEnd = CMTime(seconds: max(request.plan.trimStart + 0.05, request.plan.trimEnd),
                             preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: readStart, end: readEnd)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                             kCVPixelBufferMetalCompatibilityKey as String: true])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw KaijuError.exportFailed(reason: "Couldn't read the source video track.")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
            output.alwaysCopiesSampleData = true
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        // MARK: Writer

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mp4)
        } catch {
            throw KaijuError.exportFailed(reason: error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true

        let bitrate = request.settings.bitrate(width: Int(outputSize.width),
                                               height: Int(outputSize.height),
                                               fps: outputFrameRate)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: outputFrameRate,
            AVVideoMaxKeyFrameIntervalKey: outputFrameRate * 2,
            AVVideoAllowFrameReorderingKey: false
        ]
        compression[AVVideoProfileLevelKey] = request.settings.codec == .h264
            ? AVVideoProfileLevelH264HighAutoLevel : nil

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: request.settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw KaijuError.exportFailed(reason: "The encoder rejected \(Int(outputSize.width))×\(Int(outputSize.height)).")
        }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: request.settings.audioBitrate
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw KaijuError.exportFailed(reason: reader.error?.localizedDescription ?? "Couldn't start reading.")
        }
        guard writer.startWriting() else {
            throw KaijuError.exportFailed(reason: writer.error?.localizedDescription ?? "Couldn't start writing.")
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Frame processing

        let device = MTLCreateSystemDefaultDevice()
        let context: CIContext = device.map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false,
                                               .workingColorSpace: CGColorSpaceCreateDeviceRGB()])
        } ?? CIContext(options: [.cacheIntermediates: false])

        let plan = request.plan
        let overlays = request.overlays
        let totalDuration = max(0.01, plan.outputDuration)
        let progressBox = Guarded(0.0)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pumpAdaptor(videoInput, adaptor: adaptor,
                                  label: "com.mac.Kaiju.export.video") {
                    while true {
                        if isCancelled() { return nil }
                        guard let sample = videoOutput.copyNextSampleBuffer() else { return nil }
                        let sourceTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                        // Frames inside a cut simply never reach the writer.
                        guard let outputTime = plan.outputTime(forSource: sourceTime) else { continue }
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
                              let pool = adaptor.pixelBufferPool else { continue }

                        var destination: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
                                == kCVReturnSuccess, let destination else { continue }

                        let rendered = composite(pixelBuffer: pixelBuffer,
                                                 plan: plan,
                                                 overlays: overlays,
                                                 sourceTime: sourceTime,
                                                 outputSize: outputSize)
                        context.render(rendered, to: destination)

                        let fraction = min(1, outputTime / totalDuration)
                        progressBox.withLock { $0 = fraction }
                        progress(fraction)

                        return (destination, CMTime(seconds: outputTime, preferredTimescale: 90_000))
                    }
                }
            }

            if let audioInput, let audioOutput {
                group.addTask {
                    await ClipWriter.pump(audioInput, label: "com.mac.Kaiju.export.audio") {
                        while true {
                            if isCancelled() { return nil }
                            guard let sample = audioOutput.copyNextSampleBuffer() else { return nil }
                            let sourceTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                            guard let outputTime = plan.outputTime(forSource: sourceTime) else { continue }
                            let gain = plan.volume(atSource: sourceTime)
                            if gain != 1.0 { applyGain(gain, to: sample) }
                            let shift = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample),
                                                       CMTime(seconds: outputTime, preferredTimescale: 90_000))
                            guard let retimed = SampleBufferFactory.retime(sample, by: shift) else { continue }
                            return retimed
                        }
                    }
                }
            }
        }

        if isCancelled() {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: request.outputURL)
            throw KaijuError.exportCancelled
        }

        await ClipWriter.finish(writer)
        reader.cancelReading()

        guard writer.status == .completed else {
            throw KaijuError.exportFailed(reason: writer.error?.localizedDescription
                                          ?? "The export stopped before finishing.")
        }
        progress(1)
        return request.outputURL
    }

    /// Same idea as `ClipWriter.pump`, but for a pixel-buffer adaptor rather than
    /// ready-made sample buffers.
    private static func pumpAdaptor(_ input: AVAssetWriterInput,
                                    adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                    label: String,
                                    next: @escaping () -> (CVPixelBuffer, CMTime)?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: label)
            let finished = Guarded(false)
            func complete() {
                let alreadyDone = finished.withLock { flag -> Bool in
                    if flag { return true }
                    flag = true
                    return false
                }
                guard !alreadyDone else { return }
                input.markAsFinished()
                continuation.resume()
            }
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let (buffer, time) = next() else { complete(); return }
                    if !adaptor.append(buffer, withPresentationTime: time) { complete(); return }
                }
            }
        }
    }

    // MARK: - Compositing

    private static func composite(pixelBuffer: CVPixelBuffer,
                                  plan: EditPlan,
                                  overlays: [PreparedOverlay],
                                  sourceTime: TimeInterval,
                                  outputSize: CGSize) -> CIImage {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = image.extent

        // 1. Crop.
        if let crop = plan.cropRect {
            let rect = CGRect(x: crop.origin.x * sourceExtent.width,
                              // Plan crops use a top-left origin.
                              y: (1 - crop.origin.y - crop.height) * sourceExtent.height,
                              width: crop.width * sourceExtent.width,
                              height: crop.height * sourceExtent.height)
            image = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        }

        // 2. Zoom, around the requested focal point.
        if let zoom = plan.zoomSegments.first(where: { $0.contains(sourceTime) }), zoom.scale > 1.001 {
            let extent = image.extent
            let width = extent.width / zoom.scale
            let height = extent.height / zoom.scale
            let centreX = zoom.center.x * extent.width
            let centreY = (1 - zoom.center.y) * extent.height
            var rect = CGRect(x: centreX - width / 2, y: centreY - height / 2,
                              width: width, height: height)
            rect.origin.x = min(max(0, rect.origin.x), extent.width - width)
            rect.origin.y = min(max(0, rect.origin.y), extent.height - height)
            image = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.origin.x, y: -rect.origin.y))
        }

        // 3. Fit to the output size.
        let extent = image.extent
        if abs(extent.width - outputSize.width) > 0.5 || abs(extent.height - outputSize.height) > 0.5 {
            let scaleX = outputSize.width / max(1, extent.width)
            let scaleY = outputSize.height / max(1, extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        // 4. Overlays on top.
        for overlay in overlays where overlay.isVisible(at: sourceTime) {
            var layer = overlay.image.transformed(
                by: CGAffineTransform(translationX: overlay.origin.x, y: overlay.origin.y))
            if overlay.opacity < 0.999 {
                let filter = CIFilter(name: "CIColorMatrix")
                filter?.setValue(layer, forKey: kCIInputImageKey)
                filter?.setValue(CIVector(x: 0, y: 0, z: 0, w: CGFloat(overlay.opacity)),
                                 forKey: "inputAVector")
                if let output = filter?.outputImage { layer = output }
            }
            image = layer.composited(over: image)
        }

        return image.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// Scales interleaved float PCM in place.
    private static func applyGain(_ gain: Float, to sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var lengthAtOffset = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, lengthAtOffset >= totalLength else { return }
        let count = totalLength / MemoryLayout<Float>.size
        pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
            for index in 0..<count { samples[index] *= gain }
        }
    }

    private static func naturalDisplaySize(of track: AVAssetTrack) async throws -> CGSize {
        let size = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let applied = size.applying(transform)
        return CGSize(width: abs(applied.width), height: abs(applied.height))
    }

    private static func evenSize(_ size: CGSize) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat {
            let rounded = max(2, Int(value.rounded()))
            return CGFloat(rounded - (rounded % 2))
        }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

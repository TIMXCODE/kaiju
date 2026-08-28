import Foundation
import AppKit
import CoreImage
import CoreGraphics

/// A single overlay, already rasterised at output resolution and positioned.
struct PreparedOverlay {
    var image: CIImage
    /// Bottom-left origin, in output pixels (Core Image's coordinate space).
    var origin: CGPoint
    var opacity: Double
    var startTime: TimeInterval
    var endTime: TimeInterval

    func isVisible(at time: TimeInterval) -> Bool {
        time >= startTime && time <= endTime
    }
}

/// Rasterises text and image overlays once, up front.
///
/// Doing this per frame would mean laying out text 1,800 times for a 30-second
/// clip. Doing it once means the export loop is just a composite.
@MainActor
enum OverlayRenderer {

    static func prepare(plan: EditPlan, outputSize: CGSize) -> [PreparedOverlay] {
        var prepared: [PreparedOverlay] = []
        for overlay in plan.textOverlays {
            if let entry = renderText(overlay, outputSize: outputSize) { prepared.append(entry) }
        }
        for overlay in plan.imageOverlays {
            if let entry = renderImage(overlay, outputSize: outputSize) { prepared.append(entry) }
        }
        return prepared
    }

    private static func renderText(_ overlay: TextOverlay, outputSize: CGSize) -> PreparedOverlay? {
        let trimmed = overlay.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fontSize = max(8, overlay.relativeFontSize * outputSize.height)
        let font = NSFont.systemFont(ofSize: fontSize, weight: overlay.isBold ? .bold : .regular)
        let color = NSColor(hexString: overlay.colorHex) ?? .white
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let attributed = NSAttributedString(string: trimmed, attributes: attributes)

        let textSize = attributed.size()
        let padding = fontSize * 0.4
        let boxWidth = Int(ceil(textSize.width + padding * 2))
        let boxHeight = Int(ceil(textSize.height + padding * 1.1))
        guard boxWidth > 0, boxHeight > 0 else { return nil }

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: boxWidth, pixelsHigh: boxHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        let bounds = NSRect(x: 0, y: 0, width: boxWidth, height: boxHeight)
        if overlay.backgroundOpacity > 0.01 {
            let background = (NSColor(hexString: overlay.backgroundHex) ?? .black)
                .withAlphaComponent(overlay.backgroundOpacity)
            background.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: padding * 0.6, yRadius: padding * 0.6).fill()
        }
        attributed.draw(at: NSPoint(x: padding, y: padding * 0.55))
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = representation.cgImage else { return nil }

        // Plan positions use a top-left origin; Core Image works bottom-left.
        let centreX = overlay.position.x * outputSize.width
        let centreY = (1 - overlay.position.y) * outputSize.height
        let origin = CGPoint(x: (centreX - CGFloat(boxWidth) / 2).rounded(),
                             y: (centreY - CGFloat(boxHeight) / 2).rounded())

        return PreparedOverlay(image: CIImage(cgImage: cgImage),
                               origin: origin,
                               opacity: 1,
                               startTime: overlay.startTime,
                               endTime: overlay.endTime)
    }

    private static func renderImage(_ overlay: ImageOverlay, outputSize: CGSize) -> PreparedOverlay? {
        guard let url = overlay.url,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let targetWidth = max(8, overlay.relativeWidth * outputSize.width)
        let aspect = CGFloat(cgImage.height) / CGFloat(max(1, cgImage.width))
        let targetHeight = targetWidth * aspect
        let scale = targetWidth / CGFloat(cgImage.width)

        let scaled = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let centreX = overlay.position.x * outputSize.width
        let centreY = (1 - overlay.position.y) * outputSize.height
        let origin = CGPoint(x: (centreX - targetWidth / 2).rounded(),
                             y: (centreY - targetHeight / 2).rounded())

        return PreparedOverlay(image: scaled,
                               origin: origin,
                               opacity: overlay.opacity,
                               startTime: overlay.startTime,
                               endTime: overlay.endTime)
    }
}

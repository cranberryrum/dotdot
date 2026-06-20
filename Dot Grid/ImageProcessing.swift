//
//  ImageProcessing.swift
//  Dot Grid
//
//  Turns a framed photo into a tiny, widget-safe JPEG. The widget must NEVER see
//  a full-res image (it would blow the ~30MB widget memory limit and render
//  blank), so everything is cropped + downscaled + JPEG-compressed here first.
//

import UIKit

enum ImageProcessing {
    /// Crop `image` to `normalizedRect` (a square region in 0...1 image space),
    /// downscale to `targetPixels` square, and JPEG-encode. HEIC and any odd
    /// orientation are normalized to an upright JPEG so the widget renders
    /// consistently. Returns nil only if the image is unreadable.
    static func widgetJPEG(
        from image: UIImage,
        normalizedRect rect: CGRect,
        targetPixels: CGFloat = WidgetMetrics.targetPixels,
        quality: CGFloat = 0.8
    ) -> Data? {
        let upright = image.normalizedUp()
        guard let cg = upright.cgImage else { return nil }

        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)

        // Clamp into bounds so panoramas / tiny images never leave empty gaps.
        var px = (rect.origin.x * w).rounded()
        var py = (rect.origin.y * h).rounded()
        var side = (rect.width * w).rounded()
        side = min(side, w, h)
        px = min(max(0, px), w - side)
        py = min(max(0, py), h - side)

        let cropRect = CGRect(x: px, y: py, width: side, height: side)
        guard let cropped = cg.cropping(to: cropRect) else { return nil }

        let outSide = min(targetPixels, side)   // never upscale past the source
        let size = CGSize(width: outSide, height: outSide)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1            // size is already in pixels
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

extension UIImage {
    /// Redraws the image in `.up` orientation so pixel-space crops line up with
    /// what the user framed (camera/HEIC images often carry rotation metadata).
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

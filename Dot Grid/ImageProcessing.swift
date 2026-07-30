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
    /// Profile-photo badge size. Small enough to ride App Group / Drawing records
    /// without bloating history (~10–20 KB JPEG), sharp enough at widget badge sizes.
    static let avatarPixels: CGFloat = 256

    /// Center-crop a gallery pick into a tiny avatar JPEG. Same pipeline spirit as
    /// widget photos — upright, square, never full-res.
    static func avatarJPEG(from image: UIImage, quality: CGFloat = 0.72) -> Data? {
        let upright = image.normalizedUp()
        guard let cg = upright.cgImage else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let side = min(w, h)
        let rect = CGRect(x: (w - side) / 2 / w, y: (h - side) / 2 / h,
                          width: side / w, height: side / h)
        return widgetJPEG(from: upright, normalizedRect: rect,
                          targetPixels: avatarPixels, quality: quality)
    }

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
        croppedSquare(from: image, normalizedRect: rect, targetPixels: targetPixels)?
            .jpegData(compressionQuality: quality)
    }

    /// The framed square, cropped + downscaled to a widget-safe size, as a UIImage.
    /// Used directly for plain photos and as the base layer when baking stickers in.
    static func croppedSquare(
        from image: UIImage,
        normalizedRect rect: CGRect,
        targetPixels: CGFloat = WidgetMetrics.targetPixels
    ) -> UIImage? {
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
        return renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

extension UIImage {
    /// Redraws the image in `.up` orientation so pixel-space crops line up with
    /// what the user framed (camera/HEIC images often carry rotation metadata).
    /// `nonisolated`: full-res redraws run in detached tasks, off the main actor
    /// (the project's default isolation is MainActor).
    nonisolated func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

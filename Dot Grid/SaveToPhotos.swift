//
//  SaveToPhotos.swift
//  Dot Grid
//
//  Saves a dotdot from the inbox feed to the photo library. Every export bakes
//  in a small "dotdot · sent date" watermark (SaveWatermark) — dots render
//  fresh at feed-card proportions same as before; photos/doodles get ONE extra
//  re-encode on top of their exact sent JPEG to composite it in.
//

import Photos
import SwiftUI

@MainActor
enum DotdotExporter {
    enum Outcome { case saved, denied, failed }

    /// Add-only Photos access: the system prompt appears on the first save and
    /// never grants read access to the library.
    static func save(_ drawing: DisplayDrawing) async -> Outcome {
        guard let data = exportData(for: drawing) else { return .failed }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return .saved
        } catch {
            return .failed
        }
    }

    private static func exportData(for drawing: DisplayDrawing) -> Data? {
        switch drawing.kind {
        case .photo, .doodle:
            return watermarkedPhotoJPEG(drawing)
        case .dots:
            return dotsPNG(drawing.grid ?? .empty, sentAt: drawing.sentAt)
        }
    }

    /// The reference canvas SaveWatermark is sized for — same one the dots
    /// board renders at, so the mark looks the same proportion on any kind.
    private static let referenceSide: CGFloat = 400

    /// The board at feed-card proportions (spacing/inset match DotdotView), but
    /// rendered at 3× of a 400pt square → a 1200px PNG. PNG because flat color
    /// fields stay lossless and small.
    private static func dotsPNG(_ grid: Grid, sentAt: Date) -> Data? {
        let side = referenceSide
        let board = ZStack(alignment: .bottomLeading) {
            Theme.panel
            GridBoardView(grid: grid, spacing: 4)
                .padding(side * 0.07)
            SaveWatermark(sentAt: sentAt).padding(side * 0.04)
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: board)
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    /// Re-composites the exact sent JPEG with the watermark baked on top, at
    /// the image's OWN pixel size (never upscaled or downscaled) — one extra
    /// JPEG encode is the cost of carrying the sent-date mark out of the app.
    private static func watermarkedPhotoJPEG(_ drawing: DisplayDrawing) -> Data? {
        guard let data = drawing.imageData, let base = UIImage(data: data) else { return nil }
        let pixelWidth = base.size.width * base.scale
        let pixelHeight = base.size.height * base.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return data }

        let side = referenceSide
        let displaySize = CGSize(width: side, height: side * pixelHeight / pixelWidth)
        let composite = ZStack(alignment: .bottomLeading) {
            Image(uiImage: base)
                .resizable()
                .frame(width: displaySize.width, height: displaySize.height)
            SaveWatermark(sentAt: drawing.sentAt).padding(side * 0.04)
        }
        .frame(width: displaySize.width, height: displaySize.height)

        let renderer = ImageRenderer(content: composite)
        renderer.scale = pixelWidth / displaySize.width   // lands back on the source's own pixel size
        renderer.isOpaque = true
        guard let baked = renderer.uiImage else { return data }
        return baked.jpegData(compressionQuality: 0.92) ?? data
    }
}

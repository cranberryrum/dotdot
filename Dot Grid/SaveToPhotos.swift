//
//  SaveToPhotos.swift
//  Dot Grid
//
//  Saves a dotdot from the inbox feed to the photo library. Photos and doodles
//  save their exact sent JPEG (no recompression); dots render to a crisp PNG of
//  the board — panel background, same inset the feed card and widget use, so
//  what lands in the gallery is what the card shows.
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
            return drawing.imageData
        case .dots:
            return dotsPNG(drawing.grid ?? .empty)
        }
    }

    /// The board at feed-card proportions (spacing/inset match DotdotView), but
    /// rendered at 3× of a 400pt square → a 1200px PNG. PNG because flat color
    /// fields stay lossless and small.
    private static func dotsPNG(_ grid: Grid) -> Data? {
        let side: CGFloat = 400
        let board = ZStack {
            Theme.panel
            GridBoardView(grid: grid, spacing: 4)
                .padding(side * 0.07)
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: board)
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }
}

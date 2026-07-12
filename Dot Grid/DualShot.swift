//
//  DualShot.swift
//  Dot Grid
//
//  Dual shot: back photo first, then an automatic selfie — composited into ONE
//  image (back full-frame, selfie as a rounded picture-in-picture card). These are
//  the pieces shared by the on-screen editor and the baked render, so the card you
//  drag is exactly the card your friend sees (same trick as the caption chip).
//

import SwiftUI
import UIKit

/// Which corner of the square frame the selfie card sits in — draggable between all four.
enum PipCorner: String, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }

    /// The card's center point when parked in this corner.
    func center(in side: CGFloat, cardSize: CGSize, inset: CGFloat) -> CGPoint {
        CGPoint(
            x: isLeading ? inset + cardSize.width / 2 : side - inset - cardSize.width / 2,
            y: isTop ? inset + cardSize.height / 2 : side - inset - cardSize.height / 2
        )
    }

    /// Where a dragged card should snap: whichever quadrant its center landed in.
    static func nearest(to point: CGPoint, in side: CGFloat) -> PipCorner {
        switch (point.x < side / 2, point.y < side / 2) {
        case (true, true):   .topLeading
        case (false, true):  .topTrailing
        case (true, false):  .bottomLeading
        case (false, false): .bottomTrailing
        }
    }
}

/// Geometry shared by the on-screen pip and the baked composite (WYSIWYG).
enum PipMetrics {
    static let widthFraction: CGFloat = 0.30
    static let portraitAspect: CGFloat = 4.0 / 3.0   // height = width × 4/3
    static let inset: CGFloat = 12
    static let cornerRadius: CGFloat = 18

    static func size(for side: CGFloat) -> CGSize {
        let width = side * widthFraction
        return CGSize(width: width, height: width * portraitAspect)
    }
}

/// The selfie picture-in-picture card — rendered identically on-screen and in the
/// baked JPEG. Rounded, with the app's subtle hairline border; no material (the
/// ImageRenderer can't bake those).
struct PipCard: View {
    let image: UIImage
    let side: CGFloat   // the square frame's side; the card scales from it

    var body: some View {
        let size = PipMetrics.size(for: side)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
    }
}

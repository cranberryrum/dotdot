//
//  PhotoDoodle.swift
//  Dot Grid
//
//  The freehand scribble layer for the photo carousel's doodle page. Strokes are
//  drawn over the chosen photo and baked into the sent JPEG. The same canvas renders
//  both on-screen and in the bake, so what you draw is exactly what your friend sees.
//

import SwiftUI
import UIKit

/// A soft progressive blur: a UIKit blur masked by a vertical gradient so it's clear at
/// the top and frosts toward the bottom. UIKit-backed (not a SwiftUI material) so it
/// slides without the black flash materials show while their container is animated.
struct ProgressiveBlur: UIViewRepresentable {
    var style: UIBlurEffect.Style = .systemThickMaterialDark

    func makeUIView(context: Context) -> BlurView { BlurView(style: style) }
    func updateUIView(_ uiView: BlurView, context: Context) {}

    final class BlurView: UIView {
        private let effectView: UIVisualEffectView
        private let gradient = CAGradientLayer()

        init(style: UIBlurEffect.Style) {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: style))
            super.init(frame: .zero)
            addSubview(effectView)
            gradient.colors = [
                UIColor.clear.cgColor,
                UIColor.white.withAlphaComponent(0.55).cgColor,
                UIColor.white.cgColor,
            ]
            gradient.locations = [0, 0.45, 1]
            effectView.layer.mask = gradient   // fades the blur in from top → bottom
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            effectView.frame = bounds
            // No implicit animation on the mask as the panel resizes / lays out.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = bounds
            CATransaction.commit()
        }
    }
}

/// One freehand stroke over a photo. Points are normalized (0...1) to the square
/// frame so they scale from the on-screen canvas to the high-res baked image.
struct PhotoStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var colorIndex: Int
    var widthFraction: CGFloat   // stroke width as a fraction of the canvas width
}

/// Renders photo-doodle strokes into a transparent Canvas, including the in-progress
/// `live` stroke. Reused by the on-screen overlay and the baked render.
struct PhotoDoodleCanvas: View {
    let strokes: [PhotoStroke]
    var live: [CGPoint] = []
    var liveColorIndex: Int = 0
    var liveWidthFraction: CGFloat = 0.02
    let size: CGSize

    var body: some View {
        Canvas { context, csize in
            for stroke in strokes {
                draw(stroke.points, colorIndex: stroke.colorIndex,
                     widthFraction: stroke.widthFraction, into: &context, size: csize)
            }
            if !live.isEmpty {
                draw(live, colorIndex: liveColorIndex, widthFraction: liveWidthFraction,
                     into: &context, size: csize)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func draw(_ points: [CGPoint], colorIndex: Int, widthFraction: CGFloat,
                      into context: inout GraphicsContext, size: CGSize) {
        let pts = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first else { return }
        let width = max(widthFraction * size.width, 1)
        let color = Palette.color(at: colorIndex)
        if pts.count == 1 {
            let r = width / 2
            context.fill(Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: width, height: width)),
                         with: .color(color))
        } else {
            var path = Path()
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }
}

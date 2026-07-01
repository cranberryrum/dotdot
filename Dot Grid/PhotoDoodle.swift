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

/// A TRUE variable (progressive) blur: the backdrop blur *radius* ramps from 0 at the top
/// to `maxRadius` at the bottom — the photo stays sharp up top and frosts toward the
/// toolbar. This is different from masking a uniform blur's alpha with a gradient (which
/// just fades the blur's opacity and reads as a dark opacity fade); here the blur AMOUNT
/// itself ramps, with no tint or scrim.
///
/// Implementation attaches CoreAnimation's `variableBlur` filter to the effect view's
/// backdrop layer, radius-ramped by an alpha gradient mask. That filter is PRIVATE API,
/// reached by string via KVC (no linked private symbols) — the same technique many
/// shipping apps use for progressive blur. If App Review ever flags it, swap to a layered
/// public-API blur. UIKit-backed so it slides with the tray without the material black flash.
struct VariableBlurView: UIViewRepresentable {
    var maxRadius: CGFloat = 20

    func makeUIView(context: Context) -> VariableBlurUIView { VariableBlurUIView(maxRadius: maxRadius) }
    func updateUIView(_ uiView: VariableBlurUIView, context: Context) { uiView.maxRadius = maxRadius }
}

final class VariableBlurUIView: UIVisualEffectView {
    var maxRadius: CGFloat { didSet { guard maxRadius != oldValue else { return }; apply() } }

    init(maxRadius: CGFloat) {
        self.maxRadius = maxRadius
        super.init(effect: UIBlurEffect(style: .regular))
        // Drop the tint / vibrancy overlays so it's PURE blur — no dark scrim.
        for overlay in subviews.dropFirst() { overlay.alpha = 0 }
        apply()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var lastMaskHeight: CGFloat = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.height != lastMaskHeight { apply() }   // rebuild the mask when the height changes
    }

    /// Attach the variable-blur filter (radius ramped by a top→bottom alpha gradient mask)
    /// to the effect view's backdrop layer, replacing its stock uniform gaussian blur.
    private func apply() {
        guard bounds.height > 0, let backdrop = subviews.first?.layer else { return }
        lastMaskHeight = bounds.height

        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let blur = filterClass
                .perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                .takeUnretainedValue() as? NSObject
        else { return }

        blur.setValue(maxRadius, forKey: "inputRadius")
        blur.setValue(gradientMask(height: bounds.height), forKey: "inputMaskImage")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.filters = [blur]
    }

    /// Vertical alpha ramp — transparent (no blur) at the top → opaque (full blur) at the
    /// bottom; the filter reads the mask's alpha as the per-pixel blur strength. Eased in
    /// (a slow t²-ish onset near the top) so the blur fades in smoothly instead of starting
    /// hard, then deepens toward the toolbar.
    private func gradientMask(height: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        let stops: [(loc: CGFloat, alpha: CGFloat)] =
            [(0, 0), (0.35, 0.04), (0.6, 0.20), (0.82, 0.55), (1, 1)]
        let colors = stops.map { UIColor(white: 0, alpha: $0.alpha).cgColor } as CFArray
        let locations = stops.map(\.loc)
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: height), format: format).image { ctx in
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors, locations: locations) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: 0, y: height), options: [])
        }.cgImage
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

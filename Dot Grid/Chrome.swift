//
//  Chrome.swift
//  Dot Grid
//
//  Decorative "marketing" chrome from the comp — the bright onboarding/pairing
//  layer, NOT the dark editor. Halftone dot field and a looping marquee strip.
//

import SwiftUI

/// Polka-dot halftone field: small dots on a 22pt grid, tinted to the surface.
struct HalftoneField: View {
    var color: Color
    var spacing: CGFloat = 22
    var dotRadius: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let d = dotRadius * 2
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - dotRadius, y: y - dotRadius, width: d, height: d)),
                        with: .color(color)
                    )
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Looping marquee strip, e.g. "DRAW · SEND · REPEAT". Translates 0 → -50% on a
/// linear loop. Decorative; pauses under reduce-motion.
struct Marquee: View {
    var text: String
    var font: Font = DotFont.heavy(14)
    var color: Color = .white.opacity(0.9)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shift = false

    var body: some View {
        GeometryReader { proxy in
            let unit = Text(text).font(font)
            TimelineView(.animation(minimumInterval: reduceMotion ? nil : 0.016)) { _ in
                HStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 0) {
                            unit
                            Text("    ").font(font)
                        }
                    }
                }
                .foregroundStyle(color)
                .offset(x: shift ? -proxy.size.width : 0)
            }
        }
        .frame(height: 22)
        .clipped()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {
                shift = true
            }
        }
    }
}

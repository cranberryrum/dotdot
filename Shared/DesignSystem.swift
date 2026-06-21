//
//  DesignSystem.swift
//  Dot Grid
//
//  The single source of truth for the DOTDOT "rad" look: color tokens, the four
//  bundled fonts, text styles, the neon-glow modifier, and the motion curves from
//  dotdot-design-spec.md. Every screen + the widget pull from here.
//

import SwiftUI

// MARK: - Color tokens

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum Theme {
    // Loud chrome palette (accents / lit dots / marketing chrome)
    static let blue   = Color(hex: 0x2E6BFF)
    static let pink   = Color(hex: 0xFF5FA6)
    static let lime   = Color(hex: 0xCFF000)
    static let red    = Color(hex: 0xFF3A1E)
    static let yellow = Color(hex: 0xFFC400)
    static let mint   = Color(hex: 0x3FE0A2)
    static let peri   = Color(hex: 0x7C86FF)
    static let cream  = Color(hex: 0xFFF3D6)

    // Dark editor surfaces
    static let ink     = Color(hex: 0x0B0B0D)   // app / editor background
    static let panel   = Color(hex: 0x141417)   // grid panel surface
    static let cellOff = Color(hex: 0x1E1E22)   // empty dot fill
    static let cellRim = Color(hex: 0x28282E)   // rim around empty dots
}

// MARK: - Fonts
//
// `.custom` takes the PostScript name (not the filename) and falls back to the
// system font automatically if a face fails to load.

enum DotFont {
    static func bubble(_ size: CGFloat) -> Font { .custom("BagelFatOne-Regular", fixedSize: size) }
    static func heavy(_ size: CGFloat) -> Font { .custom("ArchivoBlack-Regular", fixedSize: size) }
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("HankenGrotesk-Regular", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", fixedSize: size)
    }
}

extension Text {
    /// Space Mono metadata label, e.g. "8X8 CANVAS" · "44 DOTS".
    func metaLabel() -> some View {
        self.font(DotFont.mono(12, bold: true))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.55))
    }
}

// MARK: - Neon glow (the signature lit-dot bloom)

extension View {
    /// Two stacked colored shadows — a tight bright one and a wider soft one.
    /// `tight`/`soft` radii are tunable; the widget dials them back (glow renders
    /// heavier there).
    func neonGlow(_ color: Color, tight: CGFloat = 4, soft: CGFloat = 12, enabled: Bool = true) -> some View {
        self
            .shadow(color: enabled ? color.opacity(0.85) : .clear, radius: tight)
            .shadow(color: enabled ? color.opacity(0.55) : .clear, radius: soft)
    }
}

// MARK: - Motion (curves from the spec's table)

enum Motion {
    /// dotpop — scale .35 → 1.22 → 1, on placement.
    static let dotpop = Animation.spring(response: 0.3, dampingFraction: 0.5)
    /// reduce-motion stand-in for any of the springy ones.
    static let reduced = Animation.easeOut(duration: 0.12)
    /// popin / flashpop style snappy entrance.
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.6)
    /// gentle settle for selections / toggles.
    static let settle = Animation.snappy(duration: 0.22)

    static func place(reduceMotion: Bool) -> Animation { reduceMotion ? reduced : dotpop }
}

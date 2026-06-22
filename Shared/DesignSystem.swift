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
    static func heavy(_ size: CGFloat) -> Font { .custom("HankenGrotesk-Regular", fixedSize: size).weight(.black) }
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

// MARK: - Motion (curves from the spec's table)

enum Motion {
    /// dotpop — a quick pop on placement. Bounce kept subtle so rapid drawing
    /// reads smooth (Apple-native feel) rather than jittery.
    static let dotpop = Animation.spring(response: 0.26, dampingFraction: 0.72)
    /// reduce-motion stand-in for any of the springy ones.
    static let reduced = Animation.easeOut(duration: 0.12)
    /// popin / flashpop style snappy entrance.
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.6)
    /// gentle settle for selections / toggles.
    static let settle = Animation.snappy(duration: 0.22)

    static func place(reduceMotion: Bool) -> Animation { reduceMotion ? reduced : dotpop }
}

/// throb — the living-pixel idle breath (scale 1 → 1.045, loop). WIDGET ONLY;
/// it competes with drawing on the composer, so never use it there.
struct Throb: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.045 : 1.0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

extension View {
    func throb() -> some View { modifier(Throb()) }
}

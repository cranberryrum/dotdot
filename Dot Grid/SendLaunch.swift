//
//  SendLaunch.swift
//  Dot Grid
//
//  Two motions from the spec: the `ripple` tap-feedback ring, and `launchUp` — the
//  send juice. On send a *copy* of the board flies up and shrinks away while the
//  real drawing stays put (we never clear the board on send).
//

import SwiftUI

struct RippleEvent: Identifiable {
    let id = UUID()
    let center: CGPoint
    let color: Color
}

/// ripple — scale .3 → 2.6, opacity .55 → 0.
struct RippleRing: View {
    let color: Color
    @State private var go = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2.5)
            .frame(width: 26, height: 26)
            .scaleEffect(go ? 2.6 : 0.3)
            .opacity(go ? 0 : 0.55)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { go = true } }
            .allowsHitTesting(false)
    }
}

/// launchUp — y 0 → -18 (s1.06, r-2) → off-screen (s.18, r8), opacity → 0.
/// A flying copy of the board; the real board underneath is untouched.
struct LaunchCopy: View {
    let grid: Grid
    let spacing: CGFloat
    let onDone: () -> Void

    @State private var lifted = false
    @State private var launched = false

    var body: some View {
        GridBoardView(grid: grid, spacing: spacing, glowStrength: 0)   // flat copy = smooth flight
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.boardBackground))
            .scaleEffect(launched ? 0.18 : (lifted ? 1.06 : 1.0))
            .rotationEffect(.degrees(launched ? 8 : (lifted ? -2 : 0)))
            .offset(y: launched ? -560 : (lifted ? -18 : 0))
            .opacity(launched ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.55)) { lifted = true }
                withAnimation(.easeIn(duration: 0.5).delay(0.14)) { launched = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { onDone() }
            }
    }
}

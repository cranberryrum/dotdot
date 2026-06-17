//
//  GridBoardView.swift
//  Dot Grid
//
//  Shared between the app and the widget extension, so the widget
//  renders exactly what the app shows.
//

import SwiftUI

/// Per-chip parameters for the "gravity" clear animation. `nil` means a static
/// board — both the widget and the resting app board render without it.
struct ChipFall: Equatable {
    var trigger: Int
    var distance: CGFloat
    var delay: Double
    var tilt: Double
}

/// Per-chip parameters for the Send "lift & land" hop. `nil` = no hop (widget).
struct ChipLift: Equatable {
    var trigger: Int
    var delay: Double
}

struct GridBoardView: View {
    let grid: Grid
    var spacing: CGFloat = 6
    var fallTrigger: Int = 0
    var fallDistance: CGFloat = 0   // 0 → no falling (widget / static render)
    var liftTrigger: Int = 0

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<Grid.side, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<Grid.side, id: \.self) { column in
                        CellChipView(
                            cell: grid[row, column],
                            fall: fall(row: row, column: column),
                            lift: lift(row: row, column: column)
                        )
                    }
                }
            }
        }
    }

    // A gentle, organic stagger shared by the fall and the lift, so both
    // ripple across the board instead of moving as one rigid sheet.
    private func chipDelay(row: Int, column: Int) -> Double {
        let jitter = Double((row &* 3 &+ column) % 4) * 0.012
        return Double(row) * 0.02 + jitter
    }

    private func fall(row: Int, column: Int) -> ChipFall? {
        guard fallDistance > 0 else { return nil }   // static render → no animation
        let tilt = column < Grid.side / 2 ? -9.0 : 9.0
        return ChipFall(trigger: fallTrigger, distance: fallDistance, delay: chipDelay(row: row, column: column), tilt: tilt)
    }

    private func lift(row: Int, column: Int) -> ChipLift? {
        guard fallDistance > 0 else { return nil }   // same "interactive board" flag
        return ChipLift(trigger: liftTrigger, delay: chipDelay(row: row, column: column))
    }
}

struct CellChipView: View {
    let cell: Cell?
    var fall: ChipFall? = nil
    var lift: ChipLift? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(Palette.emptyChip)
                if let cell {
                    chip(cell: cell, side: side)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func chip(cell: Cell, side: CGFloat) -> some View {
        let chipSide = side * cell.size.scale
        let shape = RoundedRectangle(cornerRadius: chipSide * 0.3, style: .continuous)
            .fill(Palette.color(at: cell.colorIndex))
            .frame(width: chipSide, height: chipSide)
            .transition(chipTransition)

        if reduceMotion {
            shape
        } else {
            shape
                .modifier(FallingChip(fall: fall))
                .modifier(LiftingChip(lift: lift))
        }
    }

    private var chipTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .scale(scale: 0.5).combined(with: .opacity),
                removal: .scale(scale: 0.85).combined(with: .opacity)
            )
    }
}

/// Lifts the chip slightly, then drops it under "gravity" and fades it out.
/// Plays once each time `fall.trigger` changes; at rest it's the identity.
private struct FallingChip: ViewModifier {
    let fall: ChipFall?

    struct Phase {
        var y: CGFloat = 0
        var angle: Double = 0
        var opacity: Double = 1
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let fall {
            content.keyframeAnimator(initialValue: Phase(), trigger: fall.trigger) { view, phase in
                view
                    .rotationEffect(.degrees(phase.angle))
                    .offset(y: phase.y)
                    .opacity(phase.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    LinearKeyframe(0, duration: max(fall.delay, 0.0001))   // staggered hold
                    SpringKeyframe(-12, duration: 0.18, spring: .bouncy)   // the little lift
                    CubicKeyframe(fall.distance, duration: 0.5)            // fall away under gravity
                }
                KeyframeTrack(\.angle) {
                    LinearKeyframe(0, duration: fall.delay + 0.18)
                    CubicKeyframe(fall.tilt, duration: 0.5)                // slight tumble as it drops
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: fall.delay + 0.18 + 0.34)
                    LinearKeyframe(0, duration: 0.16)
                }
            }
        } else {
            content
        }
    }
}

/// Send acknowledgement: each chip hops up and lands with a bouncy settle,
/// staggered across the board. Plays once each time `lift.trigger` changes.
private struct LiftingChip: ViewModifier {
    let lift: ChipLift?

    struct Phase {
        var y: CGFloat = 0
        var scale: CGFloat = 1
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let lift {
            content.keyframeAnimator(initialValue: Phase(), trigger: lift.trigger) { view, phase in
                view
                    .scaleEffect(phase.scale)
                    .offset(y: phase.y)
            } keyframes: { _ in
                KeyframeTrack(\.y) {
                    LinearKeyframe(0, duration: max(lift.delay, 0.0001))   // staggered hold
                    SpringKeyframe(-11, duration: 0.16, spring: .snappy)   // lift up
                    SpringKeyframe(0, duration: 0.36, spring: .bouncy)     // land + settle
                }
                KeyframeTrack(\.scale) {
                    LinearKeyframe(1, duration: max(lift.delay, 0.0001))
                    SpringKeyframe(1.07, duration: 0.16, spring: .snappy)  // pop at the apex
                    SpringKeyframe(1, duration: 0.36, spring: .bouncy)     // settle
                }
            }
        } else {
            content
        }
    }
}

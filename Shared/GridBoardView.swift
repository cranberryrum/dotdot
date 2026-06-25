//
//  GridBoardView.swift
//  Dot Grid
//
//  Shared between the app and the widget extension, so the widget
//  renders exactly what the app shows.
//

import SwiftUI

/// Per-chip parameters for the Send "lift & land" hop. `nil` = no hop (widget).
struct ChipLift: Equatable {
    var trigger: Int
    var delay: Double
}

struct GridBoardView: View {
    let grid: Grid
    var spacing: CGFloat = 6
    /// The interactive composer board (vs. the widget / static renders). Only the
    /// interactive board gets the per-chip send "lift" hop.
    var interactive: Bool = false
    var liftTrigger: Int = 0

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<grid.side, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<grid.side, id: \.self) { column in
                        CellChipView(
                            cell: grid[row, column],
                            lift: lift(row: row, column: column)
                        )
                    }
                }
            }
        }
    }

    // A gentle, organic stagger so the lift ripples across the board instead of
    // moving as one rigid sheet.
    private func chipDelay(row: Int, column: Int) -> Double {
        let jitter = Double((row &* 3 &+ column) % 4) * 0.012
        return Double(row) * 0.02 + jitter
    }

    private func lift(row: Int, column: Int) -> ChipLift? {
        guard interactive else { return nil }   // static render → no animation
        return ChipLift(trigger: liftTrigger, delay: chipDelay(row: row, column: column))
    }
}

struct CellChipView: View {
    let cell: Cell?
    var lift: ChipLift? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
                    .fill(Palette.emptyChip)
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
                            .strokeBorder(Palette.cellRim, lineWidth: max(1, side * 0.04))
                    )
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
        // Corner radius matches the empty cell's (both use the 0.32 ratio of their
        // own side), so a lit dot is the same squircle as its outline, just filled.
        let chipSide = side * cell.size.scale
        let shape = RoundedRectangle(cornerRadius: chipSide * 0.32, style: .continuous)
            .fill(Palette.color(at: cell.colorIndex))
            .frame(width: chipSide, height: chipSide)
            .transition(chipTransition)

        if reduceMotion {
            shape
        } else {
            shape.modifier(LiftingChip(lift: lift))
        }
    }

    /// Dots scale in from 0 (placement / undo) and scale to 0 on the way out
    /// (erase / clear) — a smooth, centered grow and shrink.
    private var chipTransition: AnyTransition {
        reduceMotion ? .opacity : .scale.combined(with: .opacity)
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

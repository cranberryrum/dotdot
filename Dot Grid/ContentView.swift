//
//  ContentView.swift
//  Dot Grid
//
//  Created by Aditya on 11/06/26.
//

import SwiftUI
import UIKit
import WidgetKit

struct ContentView: View {
    @State private var grid: Grid = GridStore.shared.load()
    // Shared with the wordmark in ComposerView via UserDefaults — pick a color, the
    // logo follows. Persists the last-picked accent across launches too.
    @AppStorage("accentColorIndex") private var selectedColorIndex = 0
    @State private var selectedSize: ChipSize = .medium

    @State private var dragMode: DragMode?
    @State private var visitedCells: Set<Int> = []

    @State private var justSent = false
    @State private var sendResetTask: Task<Void, Never>?
    // The exact grid last shipped. The send button shows "sent" + disables while
    // the drawing is unchanged, and re-enables the moment you edit it.
    @State private var lastSentGrid: Grid?

    @State private var clearedSnapshot: Grid?

    @State private var liftTrigger = 0
    @State private var ripples: [RippleEvent] = []
    @State private var launchGrid: Grid?
    @State private var strokeRippled = false

    @State private var showStampTray = false
    @State private var stampWorkTask: Task<Void, Never>?

    @State private var showRecipientPicker = false

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let boardSpacing: CGFloat = 6
    private let paintHaptic = UIImpactFeedbackGenerator(style: .light)
    private let sendHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let clearHaptic = UIImpactFeedbackGenerator(style: .rigid)

    private enum DragMode { case paint, erase }

    var body: some View {
        VStack(spacing: 14) {
            board
            metadataRow
            VStack(spacing: 14) {
                if showStampTray {
                    stampTray
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }
                controls
            }
            Spacer(minLength: 0)
            sendArea
        }
        .sheet(isPresented: $showRecipientPicker) {
            RecipientPickerView { recipients in finalizeSend(to: recipients) }
        }
        .onAppear {
            paintHaptic.prepare()
            sendHaptic.prepare()
            clearHaptic.prepare()
        }
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { proxy in
            let boardSide = min(proxy.size.width, proxy.size.height)
            GridBoardView(
                grid: grid,
                spacing: boardSpacing,
                interactive: true,
                liftTrigger: liftTrigger
            )
            .overlay {
                ForEach(ripples) { ripple in
                    RippleRing(color: ripple.color).position(ripple.center)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        paint(at: value.location, boardSide: boardSide)
                    }
                    .onEnded { _ in
                        dragMode = nil
                        visitedCells.removeAll()
                        strokeRippled = false
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Palette.boardBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            if let launchGrid {
                LaunchCopy(grid: launchGrid, spacing: boardSpacing) { self.launchGrid = nil }
            }
        }
    }

    /// The spec's `dotpop` (scale .35 → 1.22 → 1). Shared by drawing and stamp
    /// fill so the stamp cascades on exactly like the user drew it (`drawin`).
    private var placementAnimation: Animation {
        Motion.place(reduceMotion: reduceMotion)
    }

    private func paint(at point: CGPoint, boardSide: CGFloat) {
        let cellSide = (boardSide - CGFloat(grid.side - 1) * boardSpacing) / CGFloat(grid.side)
        let step = cellSide + boardSpacing
        guard point.x >= 0, point.y >= 0 else { return }
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard (0..<grid.side).contains(row), (0..<grid.side).contains(column) else { return }

        let index = row * grid.side + column
        // The first touched cell decides the stroke: empty starts painting,
        // filled starts erasing. A plain tap therefore toggles.
        let mode = dragMode ?? (grid.cells[index] == nil ? DragMode.paint : .erase)
        dragMode = mode
        guard visitedCells.insert(index).inserted else { return }

        switch mode {
        case .paint:
            withAnimation(placementAnimation) {
                grid.cells[index] = Cell(colorIndex: selectedColorIndex, size: selectedSize)
            }
            paintHaptic.impactOccurred()
            paintHaptic.prepare()
            if !strokeRippled {        // one ring per stroke, not per cell
                emitRipple(at: point)
                strokeRippled = true
            }
        case .erase:
            withAnimation(.easeOut(duration: 0.12)) {
                grid.cells[index] = nil
            }
        }
    }

    /// ripple — a quick feedback ring at the painted point, auto-removed.
    private func emitRipple(at point: CGPoint) {
        guard !reduceMotion else { return }
        let event = RippleEvent(center: point, color: Palette.color(at: selectedColorIndex))
        ripples.append(event)
        Task {
            try? await Task.sleep(for: .seconds(0.55))
            ripples.removeAll { $0.id == event.id }
        }
    }

    // MARK: Metadata + controls

    private var filledCount: Int { grid.cells.lazy.filter { $0 != nil }.count }

    private var metadataRow: some View {
        HStack {
            Text("\(grid.side)×\(grid.side) CANVAS").metaLabel()
            Spacer()
            Text("\(filledCount) \(filledCount == 1 ? "DOT" : "DOTS")").metaLabel()
        }
        .padding(.horizontal, 4)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Palette.entries.indices, id: \.self) { index in
                    swatch(index)
                }
            }
            HStack(spacing: 12) {
                sizeButton
                shapesButton
                gridSizeButton
                Spacer()
                clearButton
            }
        }
    }

    private func swatch(_ index: Int) -> some View {
        Button {
            selectedColorIndex = index
        } label: {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Palette.color(at: index))
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.white.opacity(selectedColorIndex == index ? 0.95 : 0), lineWidth: 3)
                        .padding(5)
                )
                .scaleEffect(selectedColorIndex == index ? 1.0 : 0.88)
        }
        .buttonStyle(SquishyButtonStyle())
        .animation(
            reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.2, dampingFraction: 0.75),
            value: selectedColorIndex
        )
        .accessibilityLabel(Palette.name(at: index))
        .accessibilityAddTraits(selectedColorIndex == index ? .isSelected : [])
    }

    private var sizeButton: some View {
        Button {
            cycleSize()
        } label: {
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let chipSide = side * selectedSize.scale
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Palette.boardBackground)
                    RoundedRectangle(cornerRadius: chipSide * 0.3, style: .continuous)
                        .fill(.white)
                        .frame(width: chipSide, height: chipSide)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("dot size")
    }

    private func cycleSize() {
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        let all = ChipSize.allCases
        let nextIndex = ((all.firstIndex(of: selectedSize) ?? 0) + 1) % all.count
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) {
            selectedSize = all[nextIndex]
        }
    }

    private var clearButton: some View {
        Button {
            clearGrid()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Palette.boardBackground)
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("clear grid")
    }

    private var shapesButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                showStampTray.toggle()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(showStampTray ? Color.white.opacity(0.16) : Palette.boardBackground)
                Image(systemName: "square.on.circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(showStampTray ? 0.95 : 0.75))
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("shapes")
        .accessibilityAddTraits(showStampTray ? .isSelected : [])
    }

    /// Toggles the canvas between 8×8 and 12×12. A compact "8×" / "12×" label (the
    /// number flips with a numeric transition) reads cleaner than a dense mini-grid.
    private var gridSizeButton: some View {
        Button { cycleGridSize() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Palette.boardBackground)
                Text("\(grid.side)×")
                    .font(DotFont.heavy(18))
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.22), value: grid.side)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("grid size")
        .accessibilityValue("\(grid.side) by \(grid.side)")
    }

    private func cycleGridSize() {
        let next = grid.side >= 12 ? 8 : 12
        let previous = grid
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.86)) {
            grid = .empty(side: next)
        }
        lastSentGrid = nil
        GridStore.shared.save(grid)   // persist the chosen size (canvas saves only on send otherwise)
        // Switching tosses the drawing — offer an undo (reuses the clear toast/undo).
        if !previous.isEmpty {
            clearedSnapshot = previous
            appModel.showToast("\(next)×\(next) canvas", icon: "square.grid.3x3", actionTitle: "undo") {
                undoClear()
            }
        }
    }

    // MARK: Stamps

    private var stampTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Stamps.all) { stamp in
                    Button {
                        applyStamp(stamp)
                    } label: {
                        GridBoardView(
                            grid: stamp.grid(colorIndex: selectedColorIndex, size: .medium),
                            spacing: 2
                        )
                        .frame(width: 54, height: 54)
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Palette.boardBackground)
                        )
                    }
                    .buttonStyle(SquishyButtonStyle())
                    .accessibilityLabel("\(stamp.name) stamp")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
    }

    /// Drops a stamp onto the board as an editable starting point. Wipes the
    /// board, then cascades the pattern in using the same placement spring and
    /// per-chip stagger as drawing. Never sends.
    private func applyStamp(_ stamp: Stamp) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            showStampTray = false
        }

        // Stop any in-flight stamp cascade and start fresh (keep the canvas size).
        stampWorkTask?.cancel()
        let side = grid.side
        grid = .empty(side: side)

        let color = selectedColorIndex
        let offset = max(0, (side - 8) / 2)   // stamps are 8×8 — center them on a bigger grid
        let points = stamp.points

        stampWorkTask = Task { @MainActor in
            for (i, point) in points.enumerated() {
                if Task.isCancelled { return }
                let r = point.row + offset, c = point.col + offset
                guard r < side, c < side else { continue }
                withAnimation(placementAnimation) {
                    grid[r, c] = Cell(colorIndex: color, size: .medium)
                }
                // Throttle the light placement haptic to the cascade rhythm —
                // a few taps across the fill, not one per chip.
                if i % 5 == 0 {
                    paintHaptic.impactOccurred()
                    paintHaptic.prepare()
                }
                try? await Task.sleep(for: .seconds(0.014))
            }
        }
    }

    // MARK: Clear + undo

    private func clearGrid() {
        guard !grid.isEmpty else { return }
        clearedSnapshot = grid
        clearHaptic.impactOccurred()
        clearHaptic.prepare()
        // Every dot scales smoothly to 0 (centered) — no drop. Undo grows them back
        // from 0 (see undoClear + the chip's scale transition). Keep the canvas size.
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .easeOut(duration: 0.26)) {
            grid = .empty(side: grid.side)
        }
        presentClearedToast()
    }

    /// The unified top toast, with an undo that restores the just-cleared grid.
    private func presentClearedToast() {
        appModel.showToast("poof! grid cleared", icon: "sparkles", actionTitle: "undo", duration: 4) {
            undoClear()
        }
    }

    private func undoClear() {
        guard let snapshot = clearedSnapshot else { return }
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7)) {
            grid = snapshot   // restores the drawing AND its size
        }
        GridStore.shared.save(grid)   // keep the canvas (and size) we just put back
    }

    // MARK: Send

    /// Sheet flow: signed in with friends → pick recipients; otherwise send a
    /// local-only echo. Inline flow (flagged): send to the strip's current selection.
    private func attemptSend() {
        if SendFlow.useInlineRecipients {
            finalizeSend(to: appModel.canPickRecipients ? appModel.resolvedRecipientIDs : [])
        } else if appModel.isSignedIn && !appModel.friends.isEmpty {
            showRecipientPicker = true
        } else {
            finalizeSend(to: [])
        }
    }

    /// Persist + ship the drawing (AppModel saves locally first, then CloudKit),
    /// and play the existing send feedback (haptic, morph, dot hop).
    private func finalizeSend(to recipients: [String]) {
        appModel.send(.dots(grid), to: recipients)
        sendHaptic.impactOccurred()
        sendHaptic.prepare()

        // launchUp: a flying copy shrinks away while the real board stays put.
        if !reduceMotion, !grid.isEmpty {
            launchGrid = grid
        }

        let morph: Animation = reduceMotion
            ? .easeInOut(duration: 0.25)
            : .spring(response: 0.4, dampingFraction: 0.62)
        withAnimation(morph) {
            lastSentGrid = grid   // marks "sent" + disables until the drawing changes
            justSent = true       // transient bounce
        }
        sendResetTask?.cancel()
        sendResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(morph) { justSent = false }
        }
    }

    /// The current drawing has already been shipped, unchanged since.
    private var isSent: Bool { !grid.isEmpty && grid == lastSentGrid }
    /// Nothing to send: an empty canvas, the same thing we just sent, or — in the
    /// inline flow, when you have friends — nobody picked in the strip.
    private var sendDisabled: Bool {
        grid.isEmpty || isSent
            || (SendFlow.useInlineRecipients && appModel.canPickRecipients && !appModel.hasRecipientSelection)
    }

    /// The send button, with the inline recipient strip stacked above it when that
    /// flow is enabled (and you have friends). Otherwise just the button (sheet flow).
    private var sendArea: some View {
        VStack(spacing: 12) {
            if SendFlow.useInlineRecipients && appModel.canPickRecipients {
                RecipientStrip()
                    .transition(.opacity)
            }
            sendButton
        }
        .animation(.easeInOut(duration: 0.2), value: appModel.canPickRecipients)
    }

    private var sendButton: some View {
        Button {
            attemptSend()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSent ? "checkmark" : "paperplane.fill")
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(isSent ? "sent!" : "send")
                    .contentTransition(.opacity)
            }
            .font(DotFont.heavy(19))
            .foregroundStyle(
                Palette.entries[selectedColorIndex].prefersDarkText
                    ? Color.black.opacity(0.85)
                    : .white
            )
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Palette.color(at: selectedColorIndex))
            )
            .scaleEffect(justSent && !reduceMotion ? 1.04 : 1.0)
            .opacity(sendDisabled ? 0.45 : 1)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(sendDisabled)
        .animation(.easeInOut(duration: 0.2), value: selectedColorIndex)
        .animation(.easeInOut(duration: 0.2), value: sendDisabled)
    }
}

struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.crisp(0.14), value: configuration.isPressed)
    }
}

#Preview {
    ComposerView()
        .environment(AppModel.shared)
}

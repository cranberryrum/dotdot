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
    @State private var selectedColorIndex = 0
    @State private var selectedSize: ChipSize = .medium

    @State private var dragMode: DragMode?
    @State private var visitedCells: Set<Int> = []

    @State private var justSent = false
    @State private var sendResetTask: Task<Void, Never>?

    @State private var clearedSnapshot: Grid?
    @State private var showClearedToast = false
    @State private var toastDismissTask: Task<Void, Never>?

    @State private var fallTrigger = 0
    @State private var isClearing = false
    @State private var fallWorkTask: Task<Void, Never>?

    @State private var liftTrigger = 0
    @State private var ripples: [RippleEvent] = []
    @State private var launchGrid: Grid?
    @State private var isDrawing = false
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
    private let fallHaptic = UIImpactFeedbackGenerator(style: .soft)

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
            sendButton
        }
        .sheet(isPresented: $showRecipientPicker) {
            RecipientPickerView { recipients in finalizeSend(to: recipients) }
        }
        .overlay(alignment: .bottom) {
            if showClearedToast {
                clearedToast
                    .padding(.horizontal, 20)
                    .padding(.bottom, 92)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .onAppear {
            paintHaptic.prepare()
            sendHaptic.prepare()
            clearHaptic.prepare()
            fallHaptic.prepare()
        }
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { proxy in
            let boardSide = min(proxy.size.width, proxy.size.height)
            GridBoardView(
                grid: grid,
                spacing: boardSpacing,
                fallTrigger: fallTrigger,
                fallDistance: boardSide + 60,
                liftTrigger: liftTrigger,
                glowStrength: boardGlow
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
                        if !isDrawing { isDrawing = true }
                        paint(at: value.location, boardSide: boardSide)
                    }
                    .onEnded { _ in
                        dragMode = nil
                        visitedCells.removeAll()
                        isDrawing = false
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
        let cellSide = (boardSide - CGFloat(Grid.side - 1) * boardSpacing) / CGFloat(Grid.side)
        let step = cellSide + boardSpacing
        guard point.x >= 0, point.y >= 0 else { return }
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard (0..<Grid.side).contains(row), (0..<Grid.side).contains(column) else { return }

        let index = row * Grid.side + column
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

    /// Glow is expensive (offscreen blur per dot), so it's off while many dots are
    /// in motion and on at rest — keeps drawing/sending/clearing buttery.
    private var boardGlow: CGFloat {
        (isDrawing || isClearing || launchGrid != nil) ? 0 : 1
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
            Text("\(Grid.side)×\(Grid.side) CANVAS").metaLabel()
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

        // Stop any in-flight clear/stamp cascade and start fresh.
        fallWorkTask?.cancel()
        stampWorkTask?.cancel()
        isClearing = false
        grid = .empty

        let color = selectedColorIndex
        let points = stamp.points

        stampWorkTask = Task { @MainActor in
            for (i, point) in points.enumerated() {
                if Task.isCancelled { return }
                withAnimation(placementAnimation) {
                    grid[point.row, point.col] = Cell(colorIndex: color, size: .medium)
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

    // MARK: Clear + undo toast

    private var clearedToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white.opacity(0.6))
            Text("Poof! Grid cleared")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Button {
                undoClear()
            } label: {
                Text("Undo")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(.white))
            }
            .buttonStyle(SquishyButtonStyle())
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.16, green: 0.16, blue: 0.20))
                .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
        )
    }

    private func clearGrid() {
        guard !grid.isEmpty, !isClearing else { return }
        clearedSnapshot = grid

        guard !reduceMotion else {
            clearHaptic.impactOccurred()
            clearHaptic.prepare()
            grid = .empty
            presentToast()
            return
        }

        let occupiedRows = (0..<Grid.side).filter { row in
            (0..<Grid.side).contains { grid[row, $0] != nil }
        }.count

        isClearing = true
        fallTrigger += 1                            // kicks off every chip's keyframe fall
        fallHaptic.impactOccurred(intensity: 0.7)   // the lift-off
        fallHaptic.prepare()

        fallWorkTask?.cancel()
        fallWorkTask = Task { @MainActor in
            // A short cascade of soft taps as they tumble — enough to feel the
            // delete land, not one buzz per chip.
            let haptics = Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.16))
                let taps = min(occupiedRows, 6)
                for i in 0..<taps {
                    if Task.isCancelled { return }
                    fallHaptic.impactOccurred(intensity: max(0.3, 0.5 - Double(i) * 0.04))
                    fallHaptic.prepare()
                    try? await Task.sleep(for: .seconds(0.075))
                }
            }
            // Let the whole fall finish, then actually empty the grid.
            try? await Task.sleep(for: .seconds(0.92))
            haptics.cancel()
            guard !Task.isCancelled else { isClearing = false; return }
            grid = .empty
            isClearing = false
            presentToast()
        }
    }

    private func presentToast() {
        toastDismissTask?.cancel()
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.82)) {
            showClearedToast = true
        }
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            dismissToast()
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            showClearedToast = false
        }
        clearedSnapshot = nil
    }

    private func undoClear() {
        guard let snapshot = clearedSnapshot else { return }
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7)) {
            grid = snapshot
        }
        dismissToast()
    }

    // MARK: Send

    /// If signed in with friends, pick recipients; otherwise send a local-only
    /// echo (foundation / solo) straight through.
    private func attemptSend() {
        if appModel.isSignedIn && !appModel.friends.isEmpty {
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
        withAnimation(morph) { justSent = true }
        sendResetTask?.cancel()
        sendResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(morph) { justSent = false }
        }
    }

    private var sendButton: some View {
        Button {
            attemptSend()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: justSent ? "checkmark" : "paperplane.fill")
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(justSent ? "SENT!" : "SEND")
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
                    .neonGlow(Palette.color(at: selectedColorIndex), tight: 6, soft: 18)
            )
            .scaleEffect(justSent && !reduceMotion ? 1.04 : 1.0)
        }
        .buttonStyle(SquishyButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: selectedColorIndex)
    }
}

struct SquishyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    ComposerView()
        .environment(AppModel.shared)
}

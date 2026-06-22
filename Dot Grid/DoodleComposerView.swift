//
//  DoodleComposerView.swift
//  Dot Grid
//
//  Doodle mode: a freehand scribble canvas. Strokes are drawn on the dark board
//  (bright marks, like the dots grid) and, on send, rendered to a widget-safe JPEG
//  that rides the existing photo pipeline — so the widget needs no changes and what
//  you draw is exactly what your friend sees.
//

import SwiftUI
import UIKit

/// One freehand stroke. Points are normalized (0...1) to the square canvas so they
/// scale cleanly from the on-screen board to the high-res baked image.
private struct DoodleStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var colorIndex: Int
    var widthFraction: CGFloat
}

private enum Brush: CaseIterable {
    case thin, medium, thick
    /// Stroke width as a fraction of the canvas side (resolution-independent).
    var fraction: CGFloat {
        switch self {
        case .thin: 0.013
        case .medium: 0.024
        case .thick: 0.040
        }
    }
    /// Diameter of the dot shown in the brush-size button.
    var indicator: CGFloat {
        switch self {
        case .thin: 8
        case .medium: 13
        case .thick: 19
        }
    }
}

struct DoodleComposerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Shared with the wordmark + dots picker — pick a color, the logo follows.
    @AppStorage("accentColorIndex") private var selectedColorIndex = 0

    @State private var strokes: [DoodleStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var brush: Brush = .medium
    @State private var canvasSide: CGFloat = 0

    @State private var showRecipientPicker = false
    @State private var pendingPhoto: Data?
    @State private var justSent = false
    @State private var sendResetTask: Task<Void, Never>?
    @State private var hasSent = false

    private let paintHaptic = UIImpactFeedbackGenerator(style: .light)
    private let sendHaptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 14) {
            board
            controls
            Spacer(minLength: 0)
            sendButton
        }
        .sheet(isPresented: $showRecipientPicker) {
            RecipientPickerView { recipients in finalizeSend(to: recipients) }
        }
        .onAppear { paintHaptic.prepare(); sendHaptic.prepare() }
    }

    // MARK: Canvas

    private var board: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                canvas(side: side)
                if strokes.isEmpty && currentPoints.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 38, weight: .semibold))
                        Text("draw something").font(DotFont.ui(16, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.3))
                    .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .gesture(drawGesture(side: side))
            .onAppear { canvasSide = side }
            .onChange(of: side) { _, new in canvasSide = new }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.boardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// The strokes (plus the in-progress one), drawn into a SwiftUI Canvas. Reused
    /// verbatim by the baked render, so on-screen and sent images match exactly.
    private func canvas(side: CGFloat) -> some View {
        Canvas { context, size in
            let live = currentPoints.isEmpty
                ? strokes
                : strokes + [DoodleStroke(points: currentPoints, colorIndex: selectedColorIndex, widthFraction: brush.fraction)]
            for stroke in live {
                let pts = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard let first = pts.first else { continue }
                let lineWidth = max(stroke.widthFraction * size.width, 1)
                let color = Palette.color(at: stroke.colorIndex)
                if pts.count == 1 {   // a tap → a round dot
                    let r = lineWidth / 2
                    context.fill(
                        Path(ellipseIn: CGRect(x: first.x - r, y: first.y - r, width: lineWidth, height: lineWidth)),
                        with: .color(color)
                    )
                } else {
                    var path = Path()
                    path.move(to: first)
                    for p in pts.dropFirst() { path.addLine(to: p) }
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .frame(width: side, height: side)
    }

    private func drawGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard side > 0 else { return }
                let p = CGPoint(x: min(max(value.location.x / side, 0), 1),
                                y: min(max(value.location.y / side, 0), 1))
                currentPoints.append(p)
            }
            .onEnded { _ in
                guard !currentPoints.isEmpty else { return }
                strokes.append(DoodleStroke(points: currentPoints, colorIndex: selectedColorIndex, widthFraction: brush.fraction))
                currentPoints = []
                paintHaptic.impactOccurred(intensity: 0.5)
                paintHaptic.prepare()
                if hasSent { hasSent = false }
            }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Palette.entries.indices, id: \.self) { index in
                    swatch(index)
                }
            }
            HStack(spacing: 12) {
                brushButton
                undoButton
                Spacer()
                clearButton
            }
        }
    }

    private func swatch(_ index: Int) -> some View {
        Button { selectedColorIndex = index } label: {
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

    private var brushButton: some View {
        Button { cycleBrush() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Palette.boardBackground)
                Circle()
                    .fill(.white)
                    .frame(width: brush.indicator, height: brush.indicator)
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private func cycleBrush() {
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        let all = Brush.allCases
        let next = ((all.firstIndex(of: brush) ?? 0) + 1) % all.count
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) {
            brush = all[next]
        }
    }

    private var undoButton: some View {
        Button { undo() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Palette.boardBackground)
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(strokes.isEmpty)
        .opacity(strokes.isEmpty ? 0.4 : 1)
    }

    private func undo() {
        guard !strokes.isEmpty else { return }
        paintHaptic.impactOccurred(intensity: 0.6)
        paintHaptic.prepare()
        withAnimation(.easeOut(duration: 0.15)) { _ = strokes.removeLast() }
        if hasSent { hasSent = false }
    }

    private var clearButton: some View {
        Button { clear() } label: {
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
        .disabled(strokes.isEmpty)
        .opacity(strokes.isEmpty ? 0.4 : 1)
    }

    private func clear() {
        guard !strokes.isEmpty else { return }
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        withAnimation(.easeOut(duration: 0.2)) { strokes = [] }
        if hasSent { hasSent = false }
    }

    // MARK: Send

    private var sendDisabled: Bool { strokes.isEmpty || hasSent }

    private var sendButton: some View {
        Button { attemptSend() } label: {
            HStack(spacing: 10) {
                Image(systemName: hasSent ? "checkmark" : "paperplane.fill")
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(hasSent ? "sent!" : "send")
                    .contentTransition(.opacity)
            }
            .font(DotFont.heavy(19))
            .foregroundStyle(
                Palette.entries[selectedColorIndex].prefersDarkText ? Color.black.opacity(0.85) : .white
            )
            .frame(maxWidth: .infinity).frame(height: 62)
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

    private func attemptSend() {
        guard let data = renderJPEG() else { return }
        pendingPhoto = data
        if appModel.isSignedIn && !appModel.friends.isEmpty {
            showRecipientPicker = true
        } else {
            finalizeSend(to: [])
        }
    }

    private func finalizeSend(to recipients: [String]) {
        guard let data = pendingPhoto else { return }
        appModel.send(.photo(data), to: recipients)
        pendingPhoto = nil

        sendHaptic.impactOccurred()
        sendHaptic.prepare()
        let morph: Animation = reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.4, dampingFraction: 0.62)
        withAnimation(morph) {
            hasSent = true
            justSent = true
        }
        sendResetTask?.cancel()
        sendResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(morph) { justSent = false }
        }
    }

    /// The scribble → a widget-safe JPEG (dark board + strokes), baked at widget px.
    @MainActor
    private func renderJPEG() -> Data? {
        guard !strokes.isEmpty, canvasSide > 0 else { return nil }
        let side = canvasSide
        let composite = ZStack {
            Palette.boardBackground
            canvas(side: side)
        }
        .frame(width: side, height: side)

        let renderer = ImageRenderer(content: composite)
        renderer.scale = WidgetMetrics.targetPixels / side
        renderer.isOpaque = true
        return renderer.uiImage?.jpegData(compressionQuality: 0.9)
    }
}

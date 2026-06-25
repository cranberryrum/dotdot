//
//  DoodleComposerView.swift
//  Dot Grid
//
//  Doodle mode: a freehand scribble canvas. Strokes are drawn on the board (which
//  can be flood-filled with a color via long-press), erased, undone, and — on send —
//  rendered to a widget-safe JPEG that rides the existing photo pipeline, so what you
//  draw is exactly what your friend sees.
//

import SwiftUI
import UIKit

/// One freehand stroke. Points are normalized (0...1) to the canvas so they scale
/// cleanly from the on-screen board to the high-res baked image. An eraser stroke
/// cuts through everything drawn before it (revealing the board / fill behind).
private struct DoodleStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var colorIndex: Int
    var widthFraction: CGFloat
    var style: BrushStyle
    var isEraser: Bool = false
}

private enum Brush: CaseIterable {
    case thin, medium, thick
    /// Stroke width as a fraction of the canvas width (resolution-independent).
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

/// How a stroke is painted. Rendering is deterministic (no live randomness) so the
/// on-screen Canvas and the baked JPEG are pixel-identical.
private enum BrushStyle: CaseIterable {
    case pen, crayon, watercolor
    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .crayon: "paintbrush.pointed.fill"
        case .watercolor: "paintbrush.fill"
        }
    }
}

/// One reversible edit, so undo restores strokes AND fills in the right order.
private enum DoodleAction {
    case stroke
    case fill(previous: Int?)
}

/// A full snapshot of the doodle, used to restore after a clear (undo toast).
private struct DoodleSnapshot {
    var strokes: [DoodleStroke]
    var fill: Int?
    var history: [DoodleAction]
}

struct DoodleComposerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Shared with the wordmark + dots picker — pick a color, the logo follows.
    @AppStorage("accentColorIndex") private var selectedColorIndex = 0

    @State private var strokes: [DoodleStroke] = []
    @State private var currentPoints: [CGPoint] = []
    @State private var fillColorIndex: Int?              // long-press flood fill
    @State private var history: [DoodleAction] = []      // undo stack (strokes + fills)
    @State private var brush: Brush = .medium
    @State private var brushStyle: BrushStyle = .pen
    @State private var isErasing = false
    @State private var canvasSize: CGSize = .zero

    @State private var longPressFilled = false           // suppresses the stroke a fill rode in on
    @State private var clearedSnapshot: DoodleSnapshot?  // for the clear → undo toast

    @State private var showRecipientPicker = false
    @State private var pendingPhoto: Data?
    @State private var justSent = false
    @State private var sendResetTask: Task<Void, Never>?
    @State private var hasSent = false

    private let paintHaptic = UIImpactFeedbackGenerator(style: .light)
    private let fillHaptic = UIImpactFeedbackGenerator(style: .rigid)
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
        .onAppear { paintHaptic.prepare(); fillHaptic.prepare(); sendHaptic.prepare() }
    }

    // MARK: Canvas

    /// Strokes plus the in-progress one (tagged eraser if the eraser is on).
    private var liveStrokes: [DoodleStroke] {
        guard !currentPoints.isEmpty else { return strokes }
        return strokes + [DoodleStroke(points: currentPoints, colorIndex: selectedColorIndex,
                                       widthFraction: brush.fraction, style: brushStyle, isEraser: isErasing)]
    }

    private var board: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                StrokeCanvas(strokes: liveStrokes, fill: fillColorIndex, size: size)
                if strokes.isEmpty && currentPoints.isEmpty && fillColorIndex == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 38, weight: .semibold))
                        Text("draw something").font(DotFont.ui(16, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.3))
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(drawGesture(size: size))
            .simultaneousGesture(fillLongPress)   // hold to flood-fill with the chosen color
            .onAppear { canvasSize = proxy.size }
            .onChange(of: proxy.size) { _, new in canvasSize = new }
        }
        // Shaped like systemLarge and filled edge-to-edge, so the doodle maps 1:1
        // onto the widget — end-to-end, no crop, no letterbox. The dark board is the
        // permanent backdrop; flood-fill + strokes live in the erasable Canvas above.
        .aspectRatio(WidgetMetrics.doodleAspect, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.boardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    // MARK: Gestures

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !longPressFilled, size.width > 0, size.height > 0 else { return }
                let p = CGPoint(x: min(max(value.location.x / size.width, 0), 1),
                                y: min(max(value.location.y / size.height, 0), 1))
                currentPoints.append(p)
            }
            .onEnded { _ in
                if longPressFilled { longPressFilled = false; currentPoints = []; return }
                guard !currentPoints.isEmpty else { return }
                strokes.append(DoodleStroke(points: currentPoints, colorIndex: selectedColorIndex,
                                            widthFraction: brush.fraction, style: brushStyle, isEraser: isErasing))
                history.append(.stroke)
                currentPoints = []
                paintHaptic.impactOccurred(intensity: 0.5)
                paintHaptic.prepare()
                if hasSent { hasSent = false }
            }
    }

    /// Press and hold → flood the whole canvas with the selected color. `maximumDistance`
    /// keeps it from firing once you start actually drawing (that becomes a stroke).
    private var fillLongPress: some Gesture {
        LongPressGesture(minimumDuration: 0.4, maximumDistance: 18)
            .onEnded { _ in fillCanvas() }
    }

    private func fillCanvas() {
        longPressFilled = true          // drop the dot the drag started on this touch
        currentPoints = []
        if isErasing { isErasing = false }
        history.append(.fill(previous: fillColorIndex))
        fillHaptic.impactOccurred()
        fillHaptic.prepare()
        fillColorIndex = selectedColorIndex   // animated by the board's .animation(value:)
        if hasSent { hasSent = false }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Palette.entries.indices, id: \.self) { index in
                    swatch(index)
                }
            }
            HStack(spacing: 10) {
                brushButton
                styleButton
                eraserButton
                undoButton
                clearButton
            }
        }
    }

    private func swatch(_ index: Int) -> some View {
        Button {
            selectedColorIndex = index
            if isErasing { withAnimation(Motion.settle) { isErasing = false } }   // picking a color = paint
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

    private func toolBackground(_ active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(active ? Theme.cream : Palette.boardBackground)
    }

    private var brushButton: some View {
        Button { cycleBrush() } label: {
            ZStack {
                toolBackground(false)
                Circle().fill(.white).frame(width: brush.indicator, height: brush.indicator)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
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

    /// Cycles the brush style: pen → crayon → watercolor.
    private var styleButton: some View {
        Button { cycleStyle() } label: {
            ZStack {
                toolBackground(false)
                Image(systemName: brushStyle.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private func cycleStyle() {
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        let all = BrushStyle.allCases
        let next = ((all.firstIndex(of: brushStyle) ?? 0) + 1) % all.count
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) {
            brushStyle = all[next]
        }
    }

    private var eraserButton: some View {
        Button { toggleEraser() } label: {
            ZStack {
                toolBackground(isErasing)
                Image(systemName: "eraser.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isErasing ? Theme.ink : .white.opacity(0.8))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private func toggleEraser() {
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        withAnimation(Motion.settle) { isErasing.toggle() }
    }

    private var undoButton: some View {
        Button { undo() } label: {
            ZStack {
                toolBackground(false)
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(history.isEmpty)
        .opacity(history.isEmpty ? 0.4 : 1)
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        paintHaptic.impactOccurred(intensity: 0.6)
        paintHaptic.prepare()
        withAnimation(.easeOut(duration: 0.15)) {
            switch last {
            case .stroke:               if !strokes.isEmpty { strokes.removeLast() }
            case .fill(let previous):   fillColorIndex = previous
            }
        }
        if hasSent { hasSent = false }
    }

    private var clearButton: some View {
        Button { clear() } label: {
            ZStack {
                toolBackground(false)
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(isEmptyCanvas)
        .opacity(isEmptyCanvas ? 0.4 : 1)
    }

    private var isEmptyCanvas: Bool { strokes.isEmpty && fillColorIndex == nil }

    /// Clear the canvas and offer an undo toast.
    private func clear() {
        guard !isEmptyCanvas else { return }
        clearedSnapshot = DoodleSnapshot(strokes: strokes, fill: fillColorIndex, history: history)
        fillHaptic.impactOccurred(intensity: 0.7)
        fillHaptic.prepare()
        isErasing = false
        hasSent = false
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2)) {
            strokes = []
            fillColorIndex = nil
        }
        history = []
        presentClearedToast()
    }

    private func presentClearedToast() {
        appModel.showToast("poof! doodle cleared", icon: "sparkles", actionTitle: "undo", duration: 4) {
            undoClear()
        }
    }

    private func undoClear() {
        guard let snapshot = clearedSnapshot else { return }
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.78)) {
            strokes = snapshot.strokes
            fillColorIndex = snapshot.fill
        }
        history = snapshot.history
        clearedSnapshot = nil
        hasSent = false
    }

    // MARK: Send

    private var sendDisabled: Bool { isEmptyCanvas || hasSent }

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
        appModel.send(.doodle(data), to: recipients)
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

    /// The scribble → a widget-safe JPEG (board/fill + strokes), baked at widget px.
    @MainActor
    private func renderJPEG() -> Data? {
        guard !isEmptyCanvas, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let size = canvasSize
        let composite = ZStack {
            Palette.boardBackground
            StrokeCanvas(strokes: strokes, fill: fillColorIndex, size: size)
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: composite)
        // Cap the LONGER side at targetPixels so the widget never loads too much.
        renderer.scale = WidgetMetrics.targetPixels / max(size.width, size.height)
        renderer.isOpaque = true
        return renderer.uiImage?.jpegData(compressionQuality: 0.9)
    }
}

// MARK: - Stroke rendering (shared by the live board, the bake, and the fall)

/// Draws a set of strokes into a transparent Canvas. Whatever sits behind it (the
/// board fill) shows through eraser cuts. Reused verbatim everywhere a doodle is
/// drawn, so on-screen, baked, and falling renders match exactly.
private struct StrokeCanvas: View {
    let strokes: [DoodleStroke]
    var fill: Int? = nil
    let size: CGSize

    var body: some View {
        Canvas { context, csize in
            // The flood-fill lives INSIDE the erasable layer (drawn first, behind the
            // strokes), so the eraser's destinationOut cuts through the fill too and
            // reveals the dark board behind. The board is the permanent backdrop.
            if let fill {
                context.fill(Path(CGRect(origin: .zero, size: csize)),
                             with: .color(Palette.color(at: fill)))
            }
            for (index, stroke) in strokes.enumerated() {
                let pts = stroke.points.map { CGPoint(x: $0.x * csize.width, y: $0.y * csize.height) }
                guard !pts.isEmpty else { continue }
                let lineWidth = max(stroke.widthFraction * csize.width, 1)
                if stroke.isEraser {
                    eraseStroke(into: &context, points: pts, width: lineWidth)
                } else {
                    drawStroke(into: &context, points: pts, width: lineWidth,
                               color: Palette.color(at: stroke.colorIndex),
                               style: stroke.style, seed: index &* 1031)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Stroke styles
//
// Each style draws purely from the stroke's points + a deterministic seed, so the
// live Canvas and the ImageRenderer bake produce identical pixels.

private func drawStroke(into context: inout GraphicsContext, points pts: [CGPoint],
                        width: CGFloat, color: Color, style: BrushStyle, seed: Int) {
    switch style {
    case .pen:        drawPen(into: &context, pts: pts, width: width, color: color)
    case .crayon:     drawCrayon(into: &context, pts: pts, width: width, color: color, seed: seed)
    case .watercolor: drawWatercolor(into: &context, pts: pts, width: width, color: color)
    }
}

/// Cuts through everything drawn before it, revealing the board / fill behind.
private func eraseStroke(into context: inout GraphicsContext, points pts: [CGPoint], width: CGFloat) {
    context.blendMode = .destinationOut
    if pts.count == 1 {
        let r = width / 2
        context.fill(Path(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: width, height: width)),
                     with: .color(.black))
    } else {
        context.stroke(polyline(pts), with: .color(.black),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    context.blendMode = .normal
}

/// Solid round-cap ink — the original brush.
private func drawPen(into context: inout GraphicsContext, pts: [CGPoint], width: CGFloat, color: Color) {
    if pts.count == 1 {
        let r = width / 2
        context.fill(Path(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: width, height: width)),
                     with: .color(color))
    } else {
        context.stroke(polyline(pts), with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// Waxy crayon: a soft base pass plus scattered grain so coverage is uneven and the
/// edges read rough — paper showing through, like a real crayon.
private func drawCrayon(into context: inout GraphicsContext, pts: [CGPoint],
                        width w: CGFloat, color: Color, seed: Int) {
    if pts.count == 1 {
        let r = w / 2
        context.fill(Path(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: w, height: w)),
                     with: .color(color.opacity(0.5)))
    } else {
        context.stroke(polyline(pts), with: .color(color.opacity(0.5)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
    let dense = densify(pts, spacing: max(w * 0.4, 1.2))
    let baseR = max(w * 0.17, 0.6)
    for (i, p) in dense.enumerated() {
        for k in 0..<2 {
            let s = seed &+ i &* 17 &+ k &* 101
            let jx = (pseudo(s) - 0.5) * w
            let jy = (pseudo(s &+ 53) - 0.5) * w
            let r = baseR * (0.55 + pseudo(s &+ 91))
            let op = 0.22 + pseudo(s &+ 7) * 0.38
            context.fill(Path(ellipseIn: CGRect(x: p.x + jx - r, y: p.y + jy - r, width: r * 2, height: r * 2)),
                         with: .color(color.opacity(op)))
        }
    }
}

/// Watercolor: a wide, soft, translucent wash plus a denser core, both blurred so
/// edges bleed. Overlapping strokes build up, like layered washes.
private func drawWatercolor(into context: inout GraphicsContext, pts: [CGPoint],
                            width w: CGFloat, color: Color) {
    func paint(into ctx: inout GraphicsContext, scale: CGFloat) {
        if pts.count == 1 {
            let r = w * scale / 2
            ctx.fill(Path(ellipseIn: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: w * scale, height: w * scale)),
                     with: .color(color))
        } else {
            ctx.stroke(polyline(pts), with: .color(color),
                       style: StrokeStyle(lineWidth: w * scale, lineCap: .round, lineJoin: .round))
        }
    }
    context.drawLayer { layer in            // soft outer wash
        layer.addFilter(.blur(radius: w * 0.55))
        layer.opacity = 0.45
        paint(into: &layer, scale: 1.6)
    }
    context.drawLayer { layer in            // denser core
        layer.addFilter(.blur(radius: w * 0.2))
        layer.opacity = 0.5
        paint(into: &layer, scale: 0.85)
    }
}

private func polyline(_ pts: [CGPoint]) -> Path {
    var path = Path()
    guard let first = pts.first else { return path }
    path.move(to: first)
    for p in pts.dropFirst() { path.addLine(to: p) }
    return path
}

/// Evenly spaced points along the polyline, for laying down crayon grain.
private func densify(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
    guard pts.count > 1, spacing > 0 else { return pts }
    var out: [CGPoint] = [pts[0]]
    var carry: CGFloat = 0
    for i in 1..<pts.count {
        let a = pts[i - 1], b = pts[i]
        let dx = b.x - a.x, dy = b.y - a.y
        let segLen = (dx * dx + dy * dy).squareRoot()
        guard segLen > 0 else { continue }
        var d = spacing - carry
        while d <= segLen {
            let t = d / segLen
            out.append(CGPoint(x: a.x + dx * t, y: a.y + dy * t))
            d += spacing
        }
        carry = segLen - (d - spacing)
    }
    return out
}

/// Deterministic hash → [0,1). Classic `fract(sin(x))`; stable across renders.
private func pseudo(_ n: Int) -> CGFloat {
    let s = sin(Double(n) * 12.9898) * 43_758.5453
    return CGFloat(s - floor(s))
}

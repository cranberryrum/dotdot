//
//  DoodleComposerView.swift
//  Dot Grid
//
//  Doodle mode: a freehand scribble canvas backed by Apple's native PencilKit inks
//  (the same engine Notes uses). Strokes are drawn on the board (which can be filled
//  with a color), erased, undone, and — on send — rendered to a widget-safe JPEG that
//  rides the existing photo pipeline, so what you draw is exactly what your friend sees.
//

import Combine
import PencilKit
import SwiftUI
import UIKit

/// Brush size → the native ink's base width in points (velocity still modulates it).
private enum Brush: CaseIterable {
    case thin, medium, thick
    var width: CGFloat {
        switch self {
        case .thin: 4
        case .medium: 9
        case .thick: 18
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

/// The three native PencilKit inks we expose, cycled by the style button.
private enum BrushStyle: CaseIterable {
    case pen, crayon, watercolor
    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .crayon: "paintbrush.pointed.fill"
        case .watercolor: "paintbrush.fill"
        }
    }
    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: .pen
        case .crayon: .crayon
        case .watercolor: .watercolor
        }
    }
}

/// A snapshot to restore after a clear (undo toast): the native drawing + the fill.
private struct DoodleSnapshot { let drawing: PKDrawing; let fill: Int? }

/// Owns the `PKCanvasView` and bridges it to SwiftUI. The canvas draws with real
/// PencilKit inks; the flood-fill lives behind it as a background layer (so the eraser
/// reveals it rather than removing it) but is still undoable through the canvas's own
/// undo manager, interleaved correctly with strokes.
private final class DoodleCanvasController: NSObject, ObservableObject, PKCanvasViewDelegate {
    let canvas = PKCanvasView()

    @Published private(set) var isEmpty = true
    @Published private(set) var canUndo = false
    @Published var fillColorIndex: Int?
    @Published private(set) var changeCount = 0   // bumps on any edit → view re-enables send

    var canvasSize: CGSize = .zero

    override init() {
        super.init()
        canvas.drawingPolicy = .anyInput          // finger drawing (not just Apple Pencil)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false            // it's a UIScrollView — lock it to a canvas
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.bouncesZoom = false
        canvas.delegate = self
        canvas.tool = PKInkingTool(.pen, color: UIColor(Palette.color(at: 0)), width: Brush.medium.width)
    }

    // MARK: Tool

    func applyTool(style: BrushStyle, brush: Brush, colorIndex: Int, erasing: Bool) {
        if erasing {
            canvas.tool = PKEraserTool(.bitmap)   // erases ink only; the fill layer stays
        } else {
            canvas.tool = PKInkingTool(style.inkType,
                                       color: UIColor(Palette.color(at: colorIndex)),
                                       width: brush.width)
        }
    }

    // MARK: Fill (undoable via the canvas's undo manager, interleaved with strokes)

    func applyFill(_ index: Int?) {
        let previous = fillColorIndex
        canvas.undoManager?.registerUndo(withTarget: self) { $0.applyFill(previous) }
        fillColorIndex = index
        bump()
    }

    // MARK: Edits

    func undo() { canvas.undoManager?.undo(); bump() }

    func snapshot() -> DoodleSnapshot { DoodleSnapshot(drawing: canvas.drawing, fill: fillColorIndex) }

    func clear() {
        canvas.drawing = PKDrawing()
        fillColorIndex = nil
        canvas.undoManager?.removeAllActions()
        bump()
    }

    func restore(_ snapshot: DoodleSnapshot) {
        canvas.drawing = snapshot.drawing
        fillColorIndex = snapshot.fill
        canvas.undoManager?.removeAllActions()
        bump()
    }

#if DEBUG
    func installCaptureDrawing(_ drawing: PKDrawing, fillColorIndex: Int?) {
        canvas.drawing = drawing
        self.fillColorIndex = fillColorIndex
        canvas.undoManager?.removeAllActions()
        bump()
    }
#endif

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { bump() }

    private func bump() {
        isEmpty = canvas.drawing.strokes.isEmpty && fillColorIndex == nil
        canUndo = canvas.undoManager?.canUndo ?? false
        changeCount &+= 1
    }

    // MARK: Bake

    /// board + fill + native ink, composited at widget pixels → a widget-safe JPEG.
    @MainActor
    func bakedJPEG(boardColor: UIColor, targetPixels: CGFloat, caption: CaptionOverlay?) -> Data? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let scale = targetPixels / max(canvasSize.width, canvasSize.height)   // cap the longer side
        let pixelSize = CGSize(width: canvasSize.width * scale, height: canvasSize.height * scale)

        // Pre-render the caption chip (same view as on-screen) at bake scale, so it's WYSIWYG.
        var captionImage: UIImage?
        if let caption, !caption.isBlank {
            let renderer = ImageRenderer(content: CaptionChip(caption: caption,
                                                              maxWidth: canvasSize.width * 0.78))
            renderer.scale = scale
            captionImage = renderer.uiImage
        }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixelSize, format: format).image { ctx in
            boardColor.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            if let fillColorIndex {
                UIColor(Palette.color(at: fillColorIndex)).setFill()
                ctx.fill(CGRect(origin: .zero, size: pixelSize))
            }
            let ink = canvas.drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: scale)
            ink.draw(in: CGRect(origin: .zero, size: pixelSize))
            if let captionImage, let caption {
                let drawSize = CGSize(width: captionImage.size.width * scale, height: captionImage.size.height * scale)
                let center = CGPoint(x: caption.position.x * pixelSize.width, y: caption.position.y * pixelSize.height)
                captionImage.draw(in: CGRect(x: center.x - drawSize.width / 2, y: center.y - drawSize.height / 2,
                                             width: drawSize.width, height: drawSize.height))
            }
        }
        return image.jpegData(compressionQuality: 0.9)
    }
}

/// Thin SwiftUI wrapper — the controller owns and configures the canvas.
private struct PencilCanvas: UIViewRepresentable {
    let controller: DoodleCanvasController
    func makeUIView(context: Context) -> PKCanvasView { controller.canvas }
    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

struct DoodleComposerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Shared with the wordmark + dots picker — pick a color, the logo follows.
    @AppStorage("accentColorIndex") private var selectedColorIndex = 0

    @StateObject private var canvas = DoodleCanvasController()
    @State private var brush: Brush = .medium
    @State private var brushStyle: BrushStyle = .pen
    @State private var isErasing = false
    @State private var clearedSnapshot: DoodleSnapshot?   // for the clear → undo toast

    // Free-dragged text caption, baked into the sent doodle (see Caption.swift).
    @State private var caption: CaptionOverlay?
    @State private var clearedCaption: CaptionOverlay?
    @State private var editingCaption = false
    @State private var captionDragFrom: CGPoint?   // chip position when the drag began (nil = not dragging)

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
            sendArea
        }
        .sheet(isPresented: $showRecipientPicker) {
            RecipientPickerView { recipients in finalizeSend(to: recipients) }
        }
        .onAppear {
            paintHaptic.prepare()
            fillHaptic.prepare()
            sendHaptic.prepare()
            applyTool()
#if DEBUG
            applyAppStoreCaptureIfNeeded()
#endif
        }
        .onChange(of: brushStyle) { _, _ in applyTool() }
        .onChange(of: brush) { _, _ in applyTool() }
        .onChange(of: isErasing) { _, _ in applyTool() }
        .onChange(of: selectedColorIndex) { _, _ in applyTool() }
        // Any edit (stroke, fill, undo) re-enables the send button.
        .onChange(of: canvas.changeCount) { _, _ in if hasSent { hasSent = false } }
        // Full-screen so the frost covers EVERYTHING (tab toggle included). Presented
        // with animations disabled — the editor fades itself in/out; the system slide
        // would read as a modal, and this isn't one.
        .fullScreenCover(isPresented: $editingCaption) {
            CaptionEditor(
                caption: Binding(get: { caption ?? CaptionOverlay(text: "", colorIndex: selectedColorIndex) },
                                 set: { caption = $0 }),
                onDone: commitCaption,
                onRemove: removeCaption
            )
            .presentationBackground(.clear)
        }
    }

    private func applyTool() {
        canvas.applyTool(style: brushStyle, brush: brush, colorIndex: selectedColorIndex, erasing: isErasing)
    }

#if DEBUG
    private func applyAppStoreCaptureIfNeeded() {
        guard AppStoreCapture.scene == .doodle, canvas.isEmpty else { return }
        selectedColorIndex = 2
        brushStyle = .crayon
        brush = .thick
        canvas.installCaptureDrawing(AppStoreCapture.doodleDrawing(side: 340), fillColorIndex: 7)
        caption = CaptionOverlay(
            text: "made for you",
            position: CGPoint(x: 0.5, y: 0.18),
            colorIndex: 3,
            size: .small,
            alignment: .center
        )
        applyTool()
    }
#endif

    private func startCaption() {
        if caption == nil { caption = CaptionOverlay(text: "", colorIndex: selectedColorIndex) }
        presentEditor(true)
    }

    private func commitCaption() {
        presentEditor(false)
        if caption?.isBlank == true { caption = nil }
        if hasSent { hasSent = false }
    }

    private func removeCaption() {
        caption = nil
        presentEditor(false)
        if hasSent { hasSent = false }
    }

    /// Presents/dismisses the caption cover with the system animation suppressed —
    /// the editor runs its own fade (see CaptionEditor).
    private func presentEditor(_ show: Bool) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { editingCaption = show }
    }

    // MARK: Canvas

    private var board: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let fill = canvas.fillColorIndex {
                    Palette.color(at: fill)
                        .transition(.opacity)   // flood-fill fades in / out
                }
                PencilCanvas(controller: canvas)
                if canvas.isEmpty && caption == nil {
                    ComposerEmptyState(systemImage: "scribble.variable", title: "draw something")
                        .allowsHitTesting(false)
                }
                captionOverlay(side: size.width)
                textToolButton
            }
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: "doodleFrame")
            .onAppear { canvas.canvasSize = size }
            .onChange(of: size) { _, new in canvas.canvasSize = new }
        }
        // Square, matching the dots and photo boards. The dark board is the permanent
        // backdrop; the flood-fill sits above it and the native ink above that.
        .aspectRatio(1, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.boardBackground))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// The free-dragged caption over the doodle (hidden while editing). Its own gesture
    /// wins over the PencilKit canvas, so touching the chip moves it instead of drawing.
    /// Tap to re-edit; drag past 6pt to move (the threshold is what lets the tap land).
    @ViewBuilder
    private func captionOverlay(side: CGFloat) -> some View {
        if let cap = caption, !editingCaption, !cap.isBlank {
            CaptionChip(caption: cap, maxWidth: side * 0.78)
                .scaleEffect(captionDragFrom != nil && !reduceMotion ? 1.04 : 1)   // picked-up lift
                .position(x: cap.position.x * side, y: cap.position.y * side)
                .onTapGesture { startCaption() }
                .gesture(captionDrag(side: side))
                .animation(Motion.crisp(0.18), value: captionDragFrom != nil)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        }
    }

    /// Drag by translation from where the chip STARTED (in the fixed frame space) —
    /// grab it anywhere and it never jumps to recenter under the finger. The 6pt
    /// minimum leaves stationary touches to the tap gesture (tap = re-edit).
    private func captionDrag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("doodleFrame"))
            .onChanged { value in
                guard side > 0, let cap = caption else { return }
                let from = captionDragFrom ?? cap.position
                captionDragFrom = from
                caption?.position = CGPoint(
                    x: min(max(from.x + value.translation.width / side, 0.12), 0.88),
                    y: min(max(from.y + value.translation.height / side, 0.08), 0.92))
                if hasSent { hasSent = false }
            }
            .onEnded { _ in captionDragFrom = nil }
    }

    /// The floating "Aa" text tool, top-right of the board. (A button, not a canvas tap —
    /// the PencilKit canvas would otherwise start a stroke.)
    private var textToolButton: some View {
        VStack {
            HStack {
                Spacer()
                CaptionToolButton { startCaption() }
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Palette.entries.indices, id: \.self) { index in
                    swatch(index)
                }
            }
            HStack(spacing: 8) {
                brushButton
                styleButton
                eraserButton
                fillButton
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
        .accessibilityLabel(Palette.name(at: index))
        .accessibilityAddTraits(selectedColorIndex == index ? .isSelected : [])
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
        .accessibilityLabel("brush size")
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

    /// Cycles the native ink: pen → crayon → watercolor.
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
        .accessibilityLabel("brush style")
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
        .accessibilityLabel("eraser")
        .accessibilityAddTraits(isErasing ? .isSelected : [])
    }

    private func toggleEraser() {
        paintHaptic.impactOccurred()
        paintHaptic.prepare()
        withAnimation(Motion.settle) { isErasing.toggle() }
    }

    /// Flood-fill the whole canvas with the selected color. (Moved from a long-press to
    /// a button because the PencilKit canvas captures touches to draw.)
    private var fillButton: some View {
        Button { fillCanvas() } label: {
            ZStack {
                toolBackground(false)
                Image(systemName: "drop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.color(at: selectedColorIndex))
            }
            .frame(maxWidth: .infinity).frame(height: 52)
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("fill background")
    }

    private func fillCanvas() {
        fillHaptic.impactOccurred()
        fillHaptic.prepare()
        if isErasing { withAnimation(Motion.settle) { isErasing = false } }
        withAnimation(.easeOut(duration: 0.2)) { canvas.applyFill(selectedColorIndex) }
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
        .disabled(!canvas.canUndo)
        .opacity(canvas.canUndo ? 1 : 0.4)
        .accessibilityLabel("undo")
    }

    private func undo() {
        guard canvas.canUndo else { return }
        paintHaptic.impactOccurred(intensity: 0.6)
        paintHaptic.prepare()
        withAnimation(.easeOut(duration: 0.15)) { canvas.undo() }
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
        .disabled(nothingToClear)
        .opacity(nothingToClear ? 0.4 : 1)
        .accessibilityLabel("clear")
    }

    private var nothingToClear: Bool { canvas.isEmpty && caption == nil }

    /// Clear the canvas and offer an undo toast.
    private func clear() {
        guard !nothingToClear else { return }
        clearedSnapshot = canvas.snapshot()
        clearedCaption = caption
        fillHaptic.impactOccurred(intensity: 0.7)
        fillHaptic.prepare()
        isErasing = false
        hasSent = false
        withAnimation(.easeOut(duration: 0.2)) {
            canvas.clear()
            caption = nil
        }
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
            canvas.restore(snapshot)
            caption = clearedCaption
        }
        clearedSnapshot = nil
        clearedCaption = nil
        hasSent = false
    }

    // MARK: Send

    /// Nothing to send: an empty canvas, the same doodle we just sent, or (when you
    /// have friends) nobody picked in the strip.
    private var sendDisabled: Bool {
        (canvas.isEmpty && (caption?.isBlank ?? true)) || hasSent
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
        guard let data = renderJPEG() else {
            appModel.showToast("couldn't prepare that doodle", icon: "exclamationmark.triangle.fill")
            return
        }
        pendingPhoto = data
        if SendFlow.useInlineRecipients {
            finalizeSend(to: appModel.canPickRecipients ? appModel.resolvedRecipientIDs : [])
        } else if appModel.isSignedIn && !appModel.friends.isEmpty {
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

    @MainActor
    private func renderJPEG() -> Data? {
        canvas.bakedJPEG(boardColor: UIColor(Palette.boardBackground),
                         targetPixels: WidgetMetrics.targetPixels, caption: caption)
    }
}

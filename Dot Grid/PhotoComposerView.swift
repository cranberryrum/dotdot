//
//  PhotoComposerView.swift
//  Dot Grid
//
//  Photo mode: shoot (live camera) or pick a photo. It's shown center-cropped to the
//  widget's square — no manual crop/zoom. Swiping the photo pages a little carousel of
//  add-ons: plain → a draggable time pill → a draggable place pill (one at a time).
//  Whatever's on the current page is baked into the sent JPEG — WYSIWYG with the widget.
//

import AVFoundation
import SwiftUI
import UIKit

struct PhotoComposerView: View {
    /// The Photo tab is the visible one. Gates the live camera (and its permission
    /// prompt + battery/indicator cost) so it only runs while you're on this tab.
    var isActive: Bool = true

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var image: UIImage?
    @State private var camera = CameraController()

    // One sheet at a time. Two separate `.sheet` modifiers on the same view
    // corrupt SwiftUI's presentation state when the PHPicker dismisses itself,
    // which left the whole screen unresponsive (you had to kill the app).
    private enum ActiveSheet: Identifiable {
        case gallery, recipients
        var id: Int { hashValue }
    }
    @State private var activeSheet: ActiveSheet?

    @State private var pendingPhoto: Data?
    @State private var justSent = false
    @State private var sendResetTask: Task<Void, Never>?
    // True once this exact shot has been sent; the button shows "sent" + disables
    // until you pick a new photo or change the pill.
    @State private var hasSent = false

    // The pill carousel over the photo. `pillPage` 0 = plain photo; 1… indexes into
    // `pillPages`. Only the current page's pill shows, draggable to any spot. Each pill
    // is created lazily and remembers its own placement + text.
    @State private var pillPage = 0
    @State private var pills: [StickerKind: PhotoSticker] = [:]
    @State private var frameSide: CGFloat = 0
    @State private var locationProvider = LocationProvider()

    // The doodle page (the last carousel page): freehand strokes drawn over the photo.
    // Pen color is the shared app accent, so it follows whatever you last picked.
    @AppStorage("accentColorIndex") private var penColorIndex = 0
    @State private var doodleStrokes: [PhotoStroke] = []
    @State private var currentStroke: [CGPoint] = []
    @State private var isDrawing = false        // page-0 doodle tray settled open (draw mode)
    @State private var dragHeight: CGFloat = 0   // live tray drag (negative = pulling up)
    @State private var panelHeight: CGFloat = 160 // measured doodle-panel height (to hide it)

    // First-run "pull up to doodle" nudge: a bouncing chevron shown the first few times a
    // photo lands, then never again. `doodleHintCount` persists the budget across launches.
    @AppStorage("photoDoodleHintCount") private var doodleHintCount = 0
    @State private var hintVisible = false
    @State private var hintOffset: CGFloat = 0
    @State private var hintTask: Task<Void, Never>?
    private let doodleHintBudget = 3

    // Free-dragged text caption, baked into the sent photo (see Caption.swift).
    @State private var caption: CaptionOverlay?
    @State private var editingCaption = false
    @State private var captionDragFrom: CGPoint?   // chip position when the drag began (nil = not dragging)

    // Dual shot: back photo, then an automatic selfie PiP (see DualShot.swift).
    @AppStorage("dualShotMode") private var dualShot = false
    @State private var pipImage: UIImage?
    @State private var pipCorner: PipCorner = .bottomTrailing
    @State private var pipDragOffset: CGSize = .zero
    @State private var pipDragging = false
    @State private var pipSwapped = false          // selfie is currently the big frame
    @State private var pipMissing = false          // selfie failed → retake chip
    @State private var selfieStepActive = false    // keeps the camera alive during the flow
    @State private var selfieCountdown: Int?       // 3 → 2 → 1 over the live second shot
    @State private var selfieTask: Task<Void, Never>?
    // The camera the countdown runs on — the opposite of whichever took the first
    // shot, so dual works front-first too. Retakes re-run against the same one.
    @State private var secondShotPosition: AVCaptureDevice.Position = .front
    private let tickHaptic = UIImpactFeedbackGenerator(style: .light)
    private let captureHaptic = UIImpactFeedbackGenerator(style: .rigid)

    /// Carousel order after the plain photo (time, place).
    private let pillPages = StickerKind.carousel
    private let penWidthFraction: CGFloat = 0.02
    private let stickerSpace = "stickerFrame"
    private let sendHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let pageHaptic = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        VStack(spacing: 16) {
            frame
            if image != nil { pageDots }
            Spacer(minLength: 0)
            sendArea
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .gallery:
                // Reset the binding ourselves (the single dismissal path) and apply
                // the image in the same transaction. Never lean on the picker to
                // dismiss itself — see GalleryPicker for why that strands a layer.
                GalleryPicker { picked in
                    activeSheet = nil
                    if let picked { setImage(picked) }
                }
                .ignoresSafeArea()
            case .recipients:
                RecipientPickerView { recipients in finalizeSend(to: recipients) }
            }
        }
        .onAppear { sendHaptic.prepare(); pageHaptic.prepare(); syncCamera() }
        // The live camera runs only while the Photo tab is frontmost and there's no
        // captured/picked shot to frame — and never while backgrounded.
        .onChange(of: isActive) { _, active in
            if !active { cancelSelfieStep() }   // switching tabs mid-flow keeps the back shot
            syncCamera()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding mid-countdown cancels cleanly — never capture off-screen.
            if phase != .active { cancelSelfieStep() }
            syncCamera()
        }
        .onChange(of: image) { _, _ in syncCamera() }
        // The user engaged the doodle (opened the tray or paged away) — drop the nudge.
        .onChange(of: isDrawing) { _, drawing in if drawing { cancelDoodleHint() } }
        .onChange(of: pillPage) { _, page in if page != 0 { cancelDoodleHint() } }
        // Full-screen so the frost covers EVERYTHING (tab toggle included). Presented
        // with animations disabled — the editor fades itself in/out; the system slide
        // would read as a modal, and this isn't one.
        .fullScreenCover(isPresented: $editingCaption) {
            CaptionEditor(
                caption: Binding(get: { caption ?? CaptionOverlay(text: "", colorIndex: penColorIndex) },
                                 set: { caption = $0 }),
                onDone: commitCaption,
                onRemove: removeCaption
            )
            .presentationBackground(.clear)
        }
    }

    private func startCaption() {
        if caption == nil { caption = CaptionOverlay(text: "", colorIndex: penColorIndex) }
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

    /// Start the live camera only when the tab is active, frontmost, and we're not
    /// already framing a shot; otherwise stop it (frees the camera + its indicator).
    /// The dual-shot selfie step keeps the session alive even though a photo is
    /// already framed — the flow needs the front camera live for its countdown.
    private func syncCamera() {
        if isActive && scenePhase == .active && (image == nil || selfieStepActive) {
            camera.activate()
        } else {
            camera.deactivate()
        }
    }

    // MARK: Framing window

    private var frame: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Palette.boardBackground)

                if let image {
                    photoImage(image, side: side)
                    pipOverlay(side: side)   // dual shot: the selfie card / countdown
                    doodleOverlay(side: side)
                    pillOverlay(side: side)
                    captionOverlay(side: side)
                    if pillPage == 0 && !isDrawing { doodleHintChevron }
                    doodleTray
                    textToolButton
                } else {
                    cameraArea(side: side)
                }
            }
            .frame(width: side, height: side)
            .coordinateSpace(name: stickerSpace)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onAppear { frameSide = side }
            .onChange(of: side) { _, new in frameSide = new }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Carousel (over the photo)
    //
    // Pages: 0 = first photo (the doodle lives here, in a pull-up tray) · 1…N = one
    // pill each (time, place). Swipe horizontally to page; on page 0, swipe UP to doodle.

    /// The pill kind on the current page (nil on the first / doodle page).
    private var currentKind: StickerKind? {
        (1...pillPages.count).contains(pillPage) ? pillPages[pillPage - 1] : nil
    }
    private var pageCount: Int { pillPages.count + 1 }   // first photo + pills

    /// The photo. A SINGLE gesture drives every mode (draw / tray-pull / page) so the
    /// Image's identity never changes. Swapping the gesture through an if/else would put
    /// this Image in different branches of a ViewBuilder conditional, which makes SwiftUI
    /// tear it down and re-decode the full-res photo on every mode flip — that re-decode
    /// was the dark-board "black flash" and the hitch when the doodle tray opened/closed.
    private func photoImage(_ image: UIImage, side: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipped()
            .contentShape(Rectangle())
            .gesture(photoGesture(side: side))
    }

    /// The freehand strokes, shown on the first page (where the doodle lives) — both
    /// while drawing and after, so the doodle persists when the tray is tucked away.
    @ViewBuilder
    private func doodleOverlay(side: CGFloat) -> some View {
        if pillPage == 0 {
            PhotoDoodleCanvas(strokes: doodleStrokes, live: currentStroke,
                              liveColorIndex: penColorIndex, liveWidthFraction: penWidthFraction,
                              size: CGSize(width: side, height: side))
                .allowsHitTesting(false)   // input is the photo's drawGesture
        }
    }

    /// One gesture for the photo, dispatched by the current mode — kept as a single
    /// DragGesture (not swapped per mode) so `photoImage` never changes structure; see
    /// there for why that matters. `minimumDistance: 0` so a stroke captures from touch
    /// down; the paging / tray thresholds are applied on release instead.
    private func photoGesture(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(stickerSpace))
            .onChanged { value in
                if pillPage == 0 && isDrawing {
                    guard side > 0 else { return }
                    currentStroke.append(CGPoint(x: min(max(value.location.x / side, 0), 1),
                                                 y: min(max(value.location.y / side, 0), 1)))
                } else if pillPage == 0 {
                    let dx = value.translation.width, dy = value.translation.height
                    dragHeight = (dy < 0 && abs(dy) > abs(dx)) ? dy : 0   // follow upward pulls only
                }
            }
            .onEnded { value in
                if pillPage == 0 && isDrawing {
                    endStroke()
                } else if pillPage == 0 {
                    endPage0Drag(value)
                } else {
                    endPageSwipe(value)
                }
            }
    }

    private func endStroke() {
        guard !currentStroke.isEmpty else { return }
        doodleStrokes.append(PhotoStroke(points: currentStroke, colorIndex: penColorIndex,
                                         widthFraction: penWidthFraction))
        currentStroke = []
        if hasSent { hasSent = false }
    }

    /// The doodle panel on page 0: the toolbar resting on a soft progressive blur that
    /// fades up into the photo — no card, no grabber, edge-to-edge. It stays mounted (so
    /// the blur never flashes through a transition) and slides in/out via an offset that
    /// tracks the drag 1:1, settling spring-free on release.
    @ViewBuilder
    private var doodleTray: some View {
        if pillPage == 0 {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                doodlePanel
            }
            .offset(y: trayTranslation)
        }
    }

    private var doodlePanel: some View {
        doodleToolbarRow
            .padding(.top, 30)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity)
            .background(progressiveBlur)
            .background(                       // measure the panel so it tucks away exactly
                GeometryReader { geo in
                    Color.clear
                        .onAppear { panelHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in panelHeight = h }
                }
            )
            .contentShape(Rectangle())
            .gesture(panelDragGesture)
    }

    /// How far the panel is pushed down from open: 0 = open, `panelHeight` = tucked below
    /// the frame (clipped away). Tracks the live drag, clamped to the panel's travel.
    private var trayTranslation: CGFloat {
        let base: CGFloat = isDrawing ? 0 : panelHeight
        return min(max(base + dragHeight, 0), panelHeight)
    }

    /// A true variable/progressive blur behind the toolbar — no scrim/colour, the blur
    /// radius ramps toward the bottom. UIKit-backed, so it slides with the tray without
    /// flashing. The frame's clip shapes its corners.
    private var progressiveBlur: some View {
        VariableBlurView(maxRadius: 14).allowsHitTesting(false)
    }

    private var doodleToolbarRow: some View {
        HStack(spacing: 7) {
            doodleTool(icon: "arrow.uturn.backward", label: "undo", enabled: !doodleStrokes.isEmpty) { undoDoodle() }
            ForEach(Palette.entries.indices, id: \.self) { index in
                Button { penColorIndex = index } label: {
                    Circle()
                        .fill(Palette.color(at: index))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(.white.opacity(penColorIndex == index ? 0.95 : 0), lineWidth: 2))
                        .scaleEffect(penColorIndex == index ? 1 : 0.82)
                }
                .buttonStyle(SquishyButtonStyle())
                .accessibilityLabel(Palette.name(at: index))
                .accessibilityAddTraits(penColorIndex == index ? .isSelected : [])
            }
            doodleTool(icon: "trash.fill", label: "clear doodle", enabled: !doodleStrokes.isEmpty) { clearDoodle() }
        }
        .animation(.snappy(duration: 0.18), value: penColorIndex)
        .padding(.horizontal, 12)
    }

    /// A first-run nudge: a small chevron at the bottom of page 0 that hops up twice —
    /// no grabber, no text — hinting "pull up to doodle". Shown for the first few photos
    /// only (see `nudgeDoodleHint`), then never again. `hintOffset` drives the hop;
    /// `hintVisible` fades it in/out.
    private var doodleHintChevron: some View {
        VStack {
            Spacer()
            Image(systemName: "chevron.compact.up")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .offset(y: hintOffset)
                .padding(.bottom, 12)
        }
        .opacity(hintVisible ? 1 : 0)
        .allowsHitTesting(false)   // the photo's swipe-up gesture does the reveal
    }

    /// Spring-free settle for the tray — a strong ease-out so it glides to rest without
    /// overshoot (during the drag the panel tracks the finger 1:1, with no animation).
    private var traySettle: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : Motion.crisp(0.3)
    }

    /// Page 0's release handling. An upward flick/drag opens the doodle tray; a
    /// horizontal one pages the carousel; anything short eases back — no spring. (The
    /// live upward tracking happens in `photoGesture`'s onChanged.)
    private func endPage0Drag(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        let flickUp = value.predictedEndTranslation.height < -120
        if (dy < -50 || flickUp) && abs(dy) > abs(dx) {
            withAnimation(traySettle) { isDrawing = true; dragHeight = 0 }
            pageHaptic.impactOccurred(intensity: 0.6); pageHaptic.prepare()
        } else if abs(dx) > 44 && abs(dx) > abs(dy) * 1.2 {
            dragHeight = 0
            goToPage(pillPage + (dx < 0 ? 1 : -1))
        } else {
            withAnimation(traySettle) { dragHeight = 0 }   // not enough → ease back
        }
    }

    /// A downward drag anywhere on the panel tucks the doodle away, tracking the finger
    /// and committing on distance or a downward flick. Measured in the fixed `stickerSpace`
    /// — NOT the default `.local` space: this gesture's host panel is itself offset by
    /// `trayTranslation`, so a local-space translation would be measured against an origin
    /// that the drag keeps moving, feeding back into a bouncy/jittery close. The frame's
    /// coordinate space doesn't move, so translation stays pure finger movement.
    private var panelDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(stickerSpace))
            .onChanged { value in
                guard isDrawing, value.translation.height > 0 else { return }
                dragHeight = value.translation.height
            }
            .onEnded { value in
                guard isDrawing else { return }
                let commit = value.translation.height > 50 || value.predictedEndTranslation.height > 120
                withAnimation(traySettle) {
                    if commit { isDrawing = false }
                    dragHeight = 0
                }
                if commit { pageHaptic.impactOccurred(intensity: 0.5); pageHaptic.prepare() }
            }
    }

    private func doodleTool(icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.9 : 0.3))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func undoDoodle() {
        guard !doodleStrokes.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.12)) { _ = doodleStrokes.removeLast() }
        if hasSent { hasSent = false }
    }

    private func clearDoodle() {
        guard !doodleStrokes.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) { doodleStrokes = [] }
        if hasSent { hasSent = false }
    }

    /// The one pill shown on the current page, draggable to any spot on the photo.
    @ViewBuilder
    private func pillOverlay(side: CGFloat) -> some View {
        if let kind = currentKind, let pill = pills[kind] {
            StickerChip(icon: pill.icon, text: pill.text)
                .position(x: pill.position.x * side, y: pill.position.y * side)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(stickerSpace))
                        .onChanged { value in
                            update(kind) {
                                $0.position = CGPoint(
                                    x: min(max(value.location.x / side, 0.10), 0.90),
                                    y: min(max(value.location.y / side, 0.07), 0.93)
                                )
                            }
                            if hasSent { hasSent = false }   // moved → can send again
                        }
                )
                .id(kind)   // swapping kinds across pages triggers the transition
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }

    /// The carousel page dots below the photo. Tappable, so any page is one tap away.
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<pageCount, id: \.self) { page in
                Button { goToPage(page) } label: {
                    Circle()
                        .fill(.white.opacity(page == pillPage ? 0.85 : 0.25))
                        .frame(width: 6, height: 6)
                        .padding(7)              // a comfortable tap target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.snappy(duration: 0.2), value: pillPage)
    }

    /// Pill pages' release handling: a horizontal swipe on the photo (not on a pill)
    /// pages the carousel. (Page 0 uses `endPage0Drag` so it can also swipe up to doodle.)
    private func endPageSwipe(_ value: DragGesture.Value) {
        guard abs(value.translation.width) > abs(value.translation.height) * 1.2,
              abs(value.translation.width) > 44 else { return }
        goToPage(pillPage + (value.translation.width < 0 ? 1 : -1))   // left → next
    }

    private func goToPage(_ page: Int) {
        let next = min(max(page, 0), pageCount - 1)
        guard next != pillPage else { return }
        if (1...pillPages.count).contains(next) { ensurePill(pillPages[next - 1]) }
        withAnimation(.snappy(duration: 0.3)) { pillPage = next; isDrawing = false }
        if hasSent { hasSent = false }
        pageHaptic.impactOccurred(intensity: 0.6)
        pageHaptic.prepare()
    }

    /// Create a pill the first time its page is shown (time = now; place resolves async).
    private func ensurePill(_ kind: StickerKind) {
        guard pills[kind] == nil else { return }
        let pos = CGPoint(x: 0.5, y: 0.90)   // sits low by default; stays within the 0.93 drag clamp
        switch kind {
        case .time:
            pills[.time] = PhotoSticker(kind: .time, icon: kind.defaultIcon,
                                        text: Date.now.formatted(date: .omitted, time: .shortened), position: pos)
        case .location:
            pills[.location] = PhotoSticker(kind: .location, icon: kind.defaultIcon, text: "locating…", position: pos)
            Task { await resolveLocation() }
        }
    }

    // MARK: Live camera (the default empty state)

    @ViewBuilder
    private func cameraArea(side: CGFloat) -> some View {
        if camera.showsPreview {
            ZStack {
                CameraPreview(camera: camera)
                    .frame(width: side, height: side)
                cameraOverlay
            }
        } else {
            cameraPlaceholder
        }
    }

    /// In-frame controls: wide-angle (0.5×/1×) and flip pinned to the top; the dual
    /// shot toggle bottom-left. (Capture lives in the bottom bar.)
    private var cameraOverlay: some View {
        VStack {
            HStack {
                if camera.hasUltraWide { wideButton }
                Spacer()
                flipButton
            }
            Spacer()
            HStack {
                dualShotToggle
                Spacer()
            }
        }
        .padding(16)
    }

    /// Single ↔ dual shot. Dual: shutter grabs the back camera, then auto-flips for
    /// a countdown selfie composited as a pip card. Last choice is remembered.
    private var dualShotToggle: some View {
        Button {
            withAnimation(Motion.settle) { dualShot.toggle() }
            pageHaptic.impactOccurred(intensity: 0.6)
            pageHaptic.prepare()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12, weight: .bold))
                Text("dual")
                    .font(DotFont.mono(12, bold: true))
            }
            .foregroundStyle(dualShot ? Theme.ink : .white)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(dualShot ? AnyShapeStyle(Theme.cream) : AnyShapeStyle(.ultraThinMaterial))
            )
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("dual shot")
        .accessibilityAddTraits(dualShot ? .isSelected : [])
    }

    private var flipButton: some View {
        cameraControl { camera.flip() } content: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 17, weight: .bold))
        }
        .accessibilityLabel("flip camera")
    }

    /// Toggles the back camera between the 1× wide and 0.5× ultra-wide lens.
    private var wideButton: some View {
        cameraControl { withAnimation(Motion.settle) { camera.toggleWide() } } content: {
            Text(camera.isWide ? "0.5×" : "1×")
                .font(DotFont.heavy(14))
                .contentTransition(.numericText())
        }
        .accessibilityLabel("camera lens")
        .accessibilityValue(camera.isWide ? "ultra wide" : "wide")
    }

    private func cameraControl<Content: View>(action: @escaping () -> Void,
                                               @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                // A little frosted blur of the live scene behind each control, so the
                // icons stay legible over a bright camera without a hard dark disc.
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private func captureTapped() {
        sendHaptic.impactOccurred()   // a shutter thunk on tap
        sendHaptic.prepare()
        // Second shot = whichever camera you WEREN'T on: back-first users get the
        // selfie countdown; front-first users get it on the back camera.
        let secondPosition: AVCaptureDevice.Position = camera.position == .front ? .back : .front
        Task {
            guard let shot = await camera.capturePhoto() else { return }
            if dualShot {
                // Kick the flip IMMEDIATELY — it runs while the first shot is
                // normalized off-main below. Serializing these (normalize, THEN
                // flip) was most of the dead time before the countdown appeared.
                startSecondShot(to: secondPosition)
            }
            // Orientation-normalizing a full-res frame is a CPU redraw — off the
            // main thread so the UI (and the countdown card) never stalls on it.
            let normalized = await Task.detached(priority: .userInitiated) { shot.normalizedUp() }.value
            applyImage(normalized)
        }
    }

    // MARK: Dual shot (second-shot step)

    /// Flip to the second camera, wait for a LIVE preview (never count down over a
    /// black frame), run a bold 3-2-1 over the pip card, then capture automatically.
    private func startSecondShot(to position: AVCaptureDevice.Position) {
        selfieTask?.cancel()
        secondShotPosition = position
        // Retaking while swapped: put the first shot up front again, so the new
        // second shot lands in the pip and you never end up with two of the same.
        if pipSwapped, let pip = pipImage { image = pip; pipSwapped = false }
        pipImage = nil
        pipMissing = false
        selfieStepActive = true
        syncCamera()   // keep the session alive though a photo is framed
        selfieTask = Task {
            await camera.setPosition(position)
            await camera.waitUntilPreviewLive()
            guard !Task.isCancelled else { return }
            for n in [3, 2, 1] {
                withAnimation(Motion.crisp(0.25)) { selfieCountdown = n }
                tickHaptic.impactOccurred()
                tickHaptic.prepare()
                try? await Task.sleep(for: .milliseconds(833))
                if Task.isCancelled { return }
            }
            guard scenePhase == .active, !Task.isCancelled else { return }
            let second = await camera.capturePhoto()
            guard !Task.isCancelled else { return }
            captureHaptic.impactOccurred()
            captureHaptic.prepare()
            if let second {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pop) { pipImage = second }
            } else {
                // Never lose both: the first shot stays; the pip slot offers a retake.
                pipMissing = true
                appModel.showToast(position == .front ? "couldn't get the selfie" : "couldn't get the back shot",
                                   icon: "camera.badge.ellipsis",
                                   actionTitle: "retry") { startSecondShot(to: position) }
            }
            endSelfieStep()
        }
    }

    /// Wind the flow down: clear the countdown, hand the camera back to the lens the
    /// user had open, and let syncCamera stop the session (a photo is framed).
    private func endSelfieStep() {
        selfieCountdown = nil
        selfieStepActive = false
        camera.resetPosition(to: secondShotPosition == .front ? .back : .front)
        syncCamera()
    }

    /// Abort the selfie step (cancel ×, backgrounding, tab switch, retake). The back
    /// shot stays as a normal single photo.
    private func cancelSelfieStep() {
        guard selfieStepActive else { return }
        selfieTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { endSelfieStep() }
    }

    /// Swap which shot is primary: selfie big ↔ back big.
    private func swapPip() {
        guard let pip = pipImage, let base = image else { return }
        pageHaptic.impactOccurred(intensity: 0.6)
        pageHaptic.prepare()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.settle) {
            image = pip
            pipImage = base
            pipSwapped.toggle()
        }
        if hasSent { hasSent = false }
    }

    /// Shown until the camera is ready: asks for permission the first time, routes to
    /// Settings when off, and falls back to the gallery when there's no camera at all.
    private var cameraPlaceholder: some View {
        Button { placeholderTapped() } label: {
            ComposerEmptyState(systemImage: "camera.fill", title: placeholderTitle)
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private var placeholderTitle: String {
        if !camera.hasCamera { return "camera unavailable\nchoose from gallery" }
        switch camera.status {
        case .notDetermined:       return "enable camera"
        case .denied, .restricted: return "camera is off\nenable it in settings"
        default:                   return "starting camera…"
        }
    }

    private func placeholderTapped() {
        if !camera.hasCamera { activeSheet = .gallery; return }
        switch camera.status {
        case .notDetermined:
            camera.activate()
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        default:
            break
        }
    }

    // MARK: Cancel / retake

    /// Reset the photo canvas back to the live camera — the bottom bar's cancel action.
    private func retake() {
        cancelSelfieStep()
        withAnimation(.snappy(duration: 0.3)) {
            image = nil
            pills = [:]
            pillPage = 0
            doodleStrokes = []
            currentStroke = []
            isDrawing = false
            hasSent = false
            caption = nil
            pipImage = nil
            pipMissing = false
            pipSwapped = false
            pipCorner = .bottomTrailing
            pipDragOffset = .zero
        }
    }

    // MARK: Pill data (place resolution)

    private func resolveLocation() async {
        do {
            let loc = try await locationProvider.current()
            let name = await locationProvider.placeName(for: loc)
            update(.location) { $0.text = name }
        } catch {
            update(.location) { $0.text = "location off" }
            appModel.showToast("couldn't get your location", icon: "location.slash.fill")
        }
    }

    private func update(_ kind: StickerKind, _ change: (inout PhotoSticker) -> Void) {
        guard var pill = pills[kind] else { return }
        change(&pill)
        pills[kind] = pill
    }

    // MARK: Send

    /// The send button, with the inline recipient strip stacked above it when that
    /// flow is enabled (and you have friends). Otherwise just the button (sheet flow).
    private var sendArea: some View {
        VStack(spacing: 12) {
            if SendFlow.useInlineRecipients && appModel.canPickRecipients && image != nil {
                RecipientStrip()
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                secondaryButton
                primaryButton
            }
        }
        // The whole bar re-flows as a photo is taken / cleared — both buttons morph
        // their glyph + label in place rather than swapping out.
        .animation(.snappy(duration: 0.3), value: image != nil)
        .animation(.easeInOut(duration: 0.2), value: appModel.canPickRecipients)
    }

    /// Gallery while the camera's live; a cancel (×) that resets the canvas once a photo
    /// is taken. The glyph swaps with a symbol-replace morph.
    private var secondaryButton: some View {
        Button { secondaryTapped() } label: {
            Image(systemName: image == nil ? "photo" : "xmark")
                .font(.system(size: 19, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 62, height: 62)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.boardBackground))
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel(image == nil ? "choose from gallery" : "discard photo")
    }

    private func secondaryTapped() {
        if image == nil { activeSheet = .gallery } else { retake() }
    }

    /// Doubles as the shutter (capture) while the camera's live and the send button once
    /// there's a photo. Icon + label morph in place across capture → send → sent.
    private var primaryButton: some View {
        Button { primaryTapped() } label: {
            HStack(spacing: 10) {
                Image(systemName: primaryIcon)
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(primaryTitle)
                    .contentTransition(.opacity)
            }
            .font(DotFont.heavy(19))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.blue)
            )
            .scaleEffect(justSent && !reduceMotion ? 1.04 : 1.0)
            .opacity(primaryDisabled ? 0.45 : 1)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(primaryDisabled)
        .animation(.easeInOut(duration: 0.2), value: primaryDisabled)
    }

    private func primaryTapped() {
        if image == nil { captureTapped() } else { attemptSend() }
    }

    private var primaryIcon: String {
        if image == nil { return "camera.fill" }
        return hasSent ? "checkmark" : "paperplane.fill"
    }
    private var primaryTitle: String {
        if image == nil { return "capture" }
        return hasSent ? "sent!" : "send"
    }

    /// Capture is disabled until the live preview is up; send is disabled once sent,
    /// while the selfie step is still running (or, in the inline flow with friends,
    /// until someone's picked).
    private var primaryDisabled: Bool {
        if image == nil { return !camera.showsPreview }
        return hasSent || selfieStepActive
            || (SendFlow.useInlineRecipients && appModel.canPickRecipients && !appModel.hasRecipientSelection)
    }

    private func attemptSend() {
        guard let data = renderWidgetJPEG() else {
            appModel.showToast("couldn't prepare that photo", icon: "exclamationmark.triangle.fill")
            return
        }
        pendingPhoto = data
        if SendFlow.useInlineRecipients {
            finalizeSend(to: appModel.canPickRecipients ? appModel.resolvedRecipientIDs : [])
        } else if appModel.isSignedIn && !appModel.friends.isEmpty {
            activeSheet = .recipients
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
            hasSent = true    // disables until a new photo / re-frame
            justSent = true   // transient bounce
        }
        sendResetTask?.cancel()
        sendResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(morph) { justSent = false }
        }
    }

    /// The free-dragged text caption over the photo (hidden while editing — the editor
    /// shows the text then). Baked into the sent JPEG regardless of the current page.
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
        DragGesture(minimumDistance: 6, coordinateSpace: .named(stickerSpace))
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

    // MARK: Dual shot (pip card, countdown, retake)

    /// The selfie layer over the framed photo: the live countdown card while the
    /// selfie step runs, the draggable/swappable pip card once captured, or a
    /// retake chip if the selfie failed. Tap the card to swap primary; drag past
    /// 6pt to move it (the threshold keeps the tap alive — see the caption chip).
    @ViewBuilder
    private func pipOverlay(side: CGFloat) -> some View {
        if selfieStepActive {
            selfieCountdownCard(side: side)
        } else if let pipImage {
            PipCard(image: pipImage, side: side)
                .overlay(alignment: .topLeading) { pipRetakeButton }
                .scaleEffect(pipDragging && !reduceMotion ? 1.05 : 1)   // picked-up lift
                .position(pipCenter(side: side))
                .offset(pipDragOffset)
                .onTapGesture { swapPip() }
                .gesture(pipDrag(side: side))
                .animation(Motion.crisp(0.18), value: pipDragging)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if pipMissing {
            retakeSelfieChip
                .position(pipCenter(side: side))
        }
    }

    private func pipCenter(side: CGFloat) -> CGPoint {
        pipCorner.center(in: side, cardSize: PipMetrics.size(for: side), inset: PipMetrics.inset)
    }

    /// Drag follows the finger 1:1; on release the card snaps (crisp, no overshoot)
    /// to whichever of the four corners its center landed nearest.
    private func pipDrag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                pipDragging = true
                pipDragOffset = value.translation
            }
            .onEnded { value in
                let start = pipCenter(side: side)
                let end = CGPoint(x: start.x + value.translation.width,
                                  y: start.y + value.translation.height)
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.crisp(0.28)) {
                    pipCorner = PipCorner.nearest(to: end, in: side)
                    pipDragOffset = .zero
                    pipDragging = false
                }
                if hasSent { hasSent = false }
            }
    }

    /// The live selfie preview in the pip slot, with a bold Archivo 3-2-1 centered
    /// on it and a cancel × that keeps just the back shot.
    private func selfieCountdownCard(side: CGFloat) -> some View {
        let size = PipMetrics.size(for: side)
        return ZStack {
            CameraPreview(camera: camera)
            Color.black.opacity(selfieCountdown == nil ? 0.45 : 0.28)
            if let n = selfieCountdown {
                Text("\(n)")
                    .font(.custom("ArchivoBlack-Regular", fixedSize: 54))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
            } else {
                ProgressView().tint(.white)   // flipping — countdown starts once live
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button { cancelSelfieStep() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .buttonStyle(SquishyButtonStyle())
            .padding(5)
            .accessibilityLabel("skip selfie")
        }
        .animation(Motion.crisp(0.3), value: selfieCountdown)
        .position(pipCenter(side: side))
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    /// Small retake on the pip card — re-runs the flip + countdown, first shot intact.
    private var pipRetakeButton: some View {
        Button { startSecondShot(to: secondShotPosition) } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.black.opacity(0.5)))
        }
        .buttonStyle(SquishyButtonStyle())
        .padding(5)
        .accessibilityLabel("retake selfie")
    }

    /// The second shot failed — its slot offers the retake so the first is never lost.
    private var retakeSelfieChip: some View {
        Button { startSecondShot(to: secondShotPosition) } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .bold))
                Text(secondShotPosition == .front ? "selfie" : "camera")
                    .font(DotFont.mono(11, bold: true))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(.black.opacity(0.5)))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("retake selfie")
    }

    /// The floating "Aa" text tool, top-right of the photo.
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

    /// The current pill, if any — baked over the photo on its page.
    private var activeStickers: [PhotoSticker] {
        guard let kind = currentKind, let pill = pills[kind] else { return [] }
        return [pill]
    }

    /// Is there anything to bake over the photo (pip, pill, doodle, or caption)?
    private var hasOverlay: Bool {
        let pageOverlay = pillPage == 0 ? !doodleStrokes.isEmpty : !activeStickers.isEmpty
        return pageOverlay || !(caption?.isBlank ?? true) || pipImage != nil
    }

    /// The center-cropped square → downscaled, widget-safe JPEG, with the current
    /// page's overlay (pill or doodle) baked in at the same spot you see on screen.
    @MainActor
    private func renderWidgetJPEG() -> Data? {
        guard let image, let rect = centerSquareRect() else { return nil }

        // Plain photo (nothing on this page) → the straight center-crop fast path.
        guard hasOverlay, frameSide > 0,
              let base = ImageProcessing.croppedSquare(from: image, normalizedRect: rect)
        else { return ImageProcessing.widgetJPEG(from: image, normalizedRect: rect) }

        // Compose the on-screen layout, then upscale to widget pixels in one shot.
        let side = frameSide
        let composite = ZStack {
            Image(uiImage: base)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipped()
            // The selfie pip is part of the photo — under the doodle/pill/caption.
            if let pipImage {
                PipCard(image: pipImage, side: side)
                    .position(pipCenter(side: side))
            }
            if pillPage == 0 {
                PhotoDoodleCanvas(strokes: doodleStrokes, size: CGSize(width: side, height: side))
            } else {
                ForEach(activeStickers) { s in
                    StickerChip(icon: s.icon, text: s.text)
                        .position(x: s.position.x * side, y: s.position.y * side)
                }
            }
            if let cap = caption, !cap.isBlank {
                CaptionChip(caption: cap, maxWidth: side * 0.78)
                    .position(x: cap.position.x * side, y: cap.position.y * side)
            }
        }
        .frame(width: side, height: side)

        let renderer = ImageRenderer(content: composite)
        renderer.scale = WidgetMetrics.targetPixels / side
        renderer.isOpaque = true
        guard let baked = renderer.uiImage else {
            return ImageProcessing.widgetJPEG(from: image, normalizedRect: rect)
        }
        return baked.jpegData(compressionQuality: 0.8)
    }

    /// The centered square crop of the image, in normalized image coordinates — the
    /// region that aspect-fills the square frame (no manual crop, so it's just center).
    private func centerSquareRect() -> CGRect? {
        guard let image else { return nil }
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let s = min(w, h)
        return CGRect(x: (w - s) / 2 / w, y: (h - s) / 2 / h, width: s / w, height: s / h)
    }

    /// Gallery picks and other one-off frames: any in-flight selfie step is superseded.
    private func setImage(_ new: UIImage) {
        cancelSelfieStep()
        applyImage(new.normalizedUp())
    }

    /// Land an already-normalized frame WITHOUT touching the selfie step — the dual
    /// shot flow starts its flip before the first frame finishes normalizing.
    private func applyImage(_ normalized: UIImage) {
        withAnimation(.snappy(duration: 0.3)) {
            image = normalized   // first page; the bottom bar morphs capture → send
            pills = [:]
            pillPage = 0
            doodleStrokes = []
            currentStroke = []
            isDrawing = false
            hasSent = false
            caption = nil
            pipImage = nil
            pipMissing = false
            pipSwapped = false
            pipCorner = .bottomTrailing
            pipDragOffset = .zero
        }
        nudgeDoodleHint()
    }

    /// Fire the first-run doodle nudge for the first `doodleHintBudget` photos, then
    /// stop — unless the debug "replay first-time hints" toggle is on, which plays it
    /// on every photo without consuming the budget.
    private func nudgeDoodleHint() {
        let replay = DebugFlags.replayFirstRuns
        guard replay || doodleHintCount < doodleHintBudget else { return }
        if !replay { doodleHintCount += 1 }
        hintTask?.cancel()
        hintTask = Task { await runDoodleHint() }
    }

    /// Let the photo settle, then hop the chevron up-and-back twice — slow and smooth —
    /// and fade it away. Reduce Motion gets a still chevron that lingers, then fades.
    @MainActor
    private func runDoodleHint() async {
        hintOffset = 0
        try? await Task.sleep(for: .milliseconds(450))   // let the photo-in animation finish
        guard !Task.isCancelled, image != nil else { return }

        withAnimation(.easeOut(duration: 0.3)) { hintVisible = true }

        if reduceMotion {
            try? await Task.sleep(for: .milliseconds(1400))
        } else {
            for _ in 0..<2 {
                withAnimation(.easeInOut(duration: 0.55)) { hintOffset = -12 }
                try? await Task.sleep(for: .milliseconds(550))
                withAnimation(.easeInOut(duration: 0.55)) { hintOffset = 0 }
                try? await Task.sleep(for: .milliseconds(550))
                if Task.isCancelled { return }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.4)) { hintVisible = false }
    }

    /// The user engaged (opened the tray) — drop the nudge immediately.
    private func cancelDoodleHint() {
        hintTask?.cancel()
        hintVisible = false
    }
}

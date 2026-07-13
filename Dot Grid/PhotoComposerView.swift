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

    // Dual shot: TRUE simultaneous capture (multi-cam). `dualLive` = the toggle has
    // morphed into the live selfie pip and both feeds run. Ephemeral by design —
    // backgrounding / leaving the camera never auto-reenters. (See DualShot.swift.)
    @State private var dualLive = false
    @State private var pipImage: UIImage?
    @State private var pipCorner: PipCorner = .bottomTrailing
    @State private var pipDragOffset: CGSize = .zero
    @State private var pipDragging = false
    @State private var pipSwapped = false          // selfie is currently the big frame
    @Namespace private var dualMorph               // toggle ↔ live pip hero morph
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
            if !active { exitDualMode(animated: false) }   // never leave multi-cam running off-screen
            syncCamera()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding tears dual down completely; returning stays single.
            if phase != .active { exitDualMode(animated: false) }
            syncCamera()
        }
        .onChange(of: image) { _, _ in syncCamera() }
        // The controller can force-exit dual (interruption that can't resume) —
        // morph the pip back down so the UI never shows a dead black card.
        .onChange(of: camera.isDualActive) { _, active in
            if !active && dualLive {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pop) { dualLive = false }
            }
        }
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
    /// already framing a shot; otherwise stop it (frees the camera + its indicator;
    /// a live multi-cam session is torn down completely by `deactivate`).
    private func syncCamera() {
        if isActive && scenePhase == .active && image == nil {
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

                // Base layer: the framed photo or the live camera.
                if let image {
                    photoImage(image, side: side)
                } else {
                    cameraArea(side: side)
                }
                // Dual shot pip / countdown — OUTSIDE the branch, so the card keeps
                // its identity when the first shot lands mid-countdown. Rebuilding it
                // there (the ConditionalContent trap again) spawned a fresh preview
                // layer whose session attach BLOCKED the main thread against the
                // in-flight camera flip — the freeze + spinner the user reported.
                pipOverlay(side: side)
                if image != nil {
                    doodleOverlay(side: side)
                    pillOverlay(side: side)
                    captionOverlay(side: side)
                    if pillPage == 0 && !isDrawing { doodleHintChevron }
                    doodleTray
                    textToolButton
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
                // Dual shot lives ONLY where multi-cam does — no toggle at all on
                // unsupported devices or the simulator; photo mode is simply single.
                if CameraController.multiCamSupported {
                    dualEntry(side: side)
                }
            }
        } else {
            cameraPlaceholder
        }
    }

    /// In-frame controls: wide-angle (0.5×/1×) and flip pinned to the top — hidden
    /// while dual is live (the multi-cam feeds are fixed back+front).
    private var cameraOverlay: some View {
        VStack {
            HStack {
                if !dualLive {
                    if camera.hasUltraWide { wideButton }
                    Spacer()
                    flipButton
                }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Dual entry — the toggle IS the pip (hero morph)

    /// One matched-geometry pair: the small "dual" button bottom-left grows into the
    /// live selfie card (and back down via the ×) as one continuous morph, on the
    /// app's placement spring.
    @ViewBuilder
    private func dualEntry(side: CGFloat) -> some View {
        if dualLive {
            liveDualPip(side: side)
                .matchedGeometryEffect(id: "dualPip", in: dualMorph)
                .position(pipCenter(side: side))
                .offset(pipDragOffset)
        } else {
            dualToggleButton
                .matchedGeometryEffect(id: "dualPip", in: dualMorph)
                .position(x: 16 + 44, y: side - 16 - 17)   // bottom-left, 16pt inset
        }
    }

    private var dualToggleButton: some View {
        Button { enterDualMode() } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 12, weight: .bold))
                Text("dual")
                    .font(DotFont.mono(12, bold: true))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(width: 88, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(.black.opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(SquishyButtonStyle())
        .accessibilityLabel("dual shot")
    }

    /// The live selfie feed in the pip slot: draggable to corners like the captured
    /// card, a × to morph back down, and a "camera paused" veil on interruptions.
    private func liveDualPip(side: CGFloat) -> some View {
        let size = PipMetrics.size(for: side)
        return ZStack {
            Color.black.opacity(0.6)   // under the feed while the session spins up
            FrontCameraPreview(camera: camera)
            if camera.dualInterrupted {
                Color.black.opacity(0.55)
                Text("camera paused")
                    .font(DotFont.mono(10, bold: true))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button { exitDualMode() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
            .buttonStyle(SquishyButtonStyle())
            .padding(5)
            .accessibilityLabel("exit dual shot")
        }
        .scaleEffect(pipDragging && !reduceMotion ? 1.05 : 1)
        .gesture(pipDrag(side: side))   // × is a Button — taps on it win over the drag
        .animation(Motion.crisp(0.18), value: pipDragging)
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
        if dualLive {
            captureDualTapped()
            return
        }
        Task {
            guard let shot = await camera.capturePhoto() else { return }
            // Orientation-normalizing a full-res frame is a CPU redraw — off the
            // main thread so the UI never stalls on it.
            let normalized = await Task.detached(priority: .userInitiated) { shot.normalizedUp() }.value
            applyImage(normalized)
        }
    }

    // MARK: Dual shot (simultaneous capture)

    /// Tap the toggle: it morphs into the live selfie pip IMMEDIATELY (the session
    /// builds behind it — the card fills with the feed as it comes up). If the
    /// multi-cam session can't start, the morph reverses with a soft error.
    private func enterDualMode() {
        guard !dualLive else { return }
        pageHaptic.impactOccurred(intensity: 0.7)
        pageHaptic.prepare()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pop) { dualLive = true }
        Task {
            let ok = await camera.enterDual()
            if !ok {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pop) { dualLive = false }
                appModel.showToast("couldn't start the selfie camera", icon: "camera.badge.ellipsis")
            }
        }
    }

    /// The cross (or any forced exit): morph the pip back down into the toggle and
    /// tear the multi-cam session down, resuming the plain camera.
    private func exitDualMode(animated: Bool = true) {
        guard dualLive else { return }
        if animated {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.pop) { dualLive = false }
        } else {
            dualLive = false
        }
        Task { await camera.exitDual(resumeSingle: isActive && scenePhase == .active && image == nil) }
    }

    /// One tap, both frames in the same instant. Partial failure keeps whichever
    /// frame made it (never lose both); the composite editor takes over from here.
    private func captureDualTapped() {
        Task {
            let (back, front) = await camera.captureDual()
            captureHaptic.impactOccurred()
            captureHaptic.prepare()
            guard back != nil || front != nil else {
                appModel.showToast("capture failed — try again", icon: "camera.badge.ellipsis")
                return
            }
            dualLive = false   // no morph: the captured pip card appears in its place
            Task { await camera.exitDual(resumeSingle: false) }   // photo is framed; camera off

            let corner = pipCorner   // keep the corner the live pip was parked in
            let normalized = await Task.detached(priority: .userInitiated) {
                (back?.normalizedUp(), front?.normalizedUp())
            }.value
            applyImage(normalized.0 ?? normalized.1!)   // back full-frame when it exists
            if normalized.0 != nil, let selfie = normalized.1 {
                pipImage = selfie
                pipCorner = corner
            } else if normalized.0 == nil {
                appModel.showToast("couldn't get the back camera — kept your selfie",
                                   icon: "camera.badge.ellipsis")
            } else {
                appModel.showToast("couldn't get the selfie — kept the photo",
                                   icon: "camera.badge.ellipsis")
            }
        }
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

    /// Reset the photo canvas back to the live camera — the bottom bar's cancel
    /// action. Returns to SINGLE capture (dual is never auto-reentered).
    private func retake() {
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
        return hasSent
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

    // MARK: Dual shot (captured pip card)

    /// The captured selfie over the framed photo. Tap the card to swap primary;
    /// drag past 6pt to move it (the threshold keeps the tap alive — see the
    /// caption chip).
    @ViewBuilder
    private func pipOverlay(side: CGFloat) -> some View {
        if let pipImage {
            PipCard(image: pipImage, side: side)
                .scaleEffect(pipDragging && !reduceMotion ? 1.05 : 1)   // picked-up lift
                .position(pipCenter(side: side))
                .offset(pipDragOffset)
                .onTapGesture { swapPip() }
                .gesture(pipDrag(side: side))
                .animation(Motion.crisp(0.18), value: pipDragging)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
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

    /// Gallery picks: a picked frame supersedes any live dual session.
    private func setImage(_ new: UIImage) {
        exitDualMode(animated: false)
        applyImage(new.normalizedUp())
    }

    /// Land an already-normalized frame and reset the compose state around it.
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

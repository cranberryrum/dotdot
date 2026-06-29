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

    /// Carousel order after the plain photo. (Weather is parked — see StickerKind.carousel.)
    private let pillPages = StickerKind.carousel
    private let stickerSpace = "stickerFrame"
    private let sendHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let pageHaptic = UIImpactFeedbackGenerator(style: .soft)

    var body: some View {
        VStack(spacing: 16) {
            frame
            controls
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
        .onChange(of: isActive) { _, _ in syncCamera() }
        .onChange(of: scenePhase) { _, _ in syncCamera() }
        .onChange(of: image) { _, _ in syncCamera() }
    }

    /// Start the live camera only when the tab is active, frontmost, and we're not
    /// already framing a shot; otherwise stop it (frees the camera + its indicator).
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

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(pageSwipe)
                    pillOverlay(side: side)
                    pageIndicator
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

    // MARK: Pill carousel (over the photo)

    /// The pill kind on the current page (nil on the plain-photo page).
    private var currentKind: StickerKind? {
        (1...max(pillPages.count, 1)).contains(pillPage) ? pillPages[pillPage - 1] : nil
    }
    private var pageCount: Int { pillPages.count + 1 }   // + the plain-photo page

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

    /// Page dots + a first-page hint, so the swipe-for-pills carousel is discoverable.
    private var pageIndicator: some View {
        VStack(spacing: 8) {
            Spacer()
            if pillPage == 0 {
                Text("swipe for time · place")
                    .font(DotFont.mono(11, bold: true)).tracking(1)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .transition(.opacity)
            }
            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { page in
                    Circle()
                        .fill(.white.opacity(page == pillPage ? 0.95 : 0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 14)
        }
        .allowsHitTesting(false)
    }

    /// A horizontal swipe on the photo (not on the pill) pages the carousel.
    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.2,
                      abs(value.translation.width) > 44 else { return }
                changePage(forward: value.translation.width < 0)   // swipe left → next
            }
    }

    private func changePage(forward: Bool) {
        let next = forward ? min(pillPage + 1, pageCount - 1) : max(pillPage - 1, 0)
        guard next != pillPage else { return }
        if next >= 1 { ensurePill(pillPages[next - 1]) }
        withAnimation(.snappy(duration: 0.3)) { pillPage = next }
        if hasSent { hasSent = false }
        pageHaptic.impactOccurred(intensity: 0.6)
        pageHaptic.prepare()
    }

    /// Create a pill the first time its page is shown (time = now; place resolves async).
    private func ensurePill(_ kind: StickerKind) {
        guard pills[kind] == nil else { return }
        let pos = CGPoint(x: 0.5, y: 0.85)
        switch kind {
        case .time:
            pills[.time] = PhotoSticker(kind: .time, icon: kind.defaultIcon,
                                        text: Date.now.formatted(date: .omitted, time: .shortened), position: pos)
        case .location:
            pills[.location] = PhotoSticker(kind: .location, icon: kind.defaultIcon, text: "locating…", position: pos)
            Task { await resolveLocation() }
        case .weather:
            pills[.weather] = PhotoSticker(kind: .weather, icon: kind.defaultIcon, text: "…", position: pos)
            Task { await resolveWeather() }
        }
    }

    // MARK: Live camera (the default empty state)

    @ViewBuilder
    private func cameraArea(side: CGFloat) -> some View {
        if camera.showsPreview {
            ZStack {
                CameraPreview(session: camera.session)
                    .frame(width: side, height: side)
                cameraOverlay
            }
        } else {
            cameraPlaceholder
        }
    }

    /// In-frame controls: wide-angle (0.5×/1×) and flip up top, shutter at the bottom.
    private var cameraOverlay: some View {
        VStack {
            HStack {
                if camera.hasUltraWide { wideButton }
                Spacer()
                flipButton
            }
            Spacer()
            shutterButton
        }
        .padding(16)
    }

    private var shutterButton: some View {
        Button { captureTapped() } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4).frame(width: 66, height: 66)
                Circle().fill(.white).frame(width: 54, height: 54)
            }
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private var flipButton: some View {
        cameraControl { camera.flip() } content: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 17, weight: .bold))
        }
    }

    /// Toggles the back camera between the 1× wide and 0.5× ultra-wide lens.
    private var wideButton: some View {
        cameraControl { withAnimation(Motion.settle) { camera.toggleWide() } } content: {
            Text(camera.isWide ? "0.5×" : "1×")
                .font(DotFont.heavy(14))
                .contentTransition(.numericText())
        }
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
        Task {
            guard let shot = await camera.capturePhoto() else { return }
            setImage(shot)
        }
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

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            controlButton(title: "Gallery", systemImage: "photo") { activeSheet = .gallery }
            // The camera is live in the frame; once a shot is taken, offer a retake
            // (clears it → back to the live camera).
            if image != nil {
                controlButton(title: "Retake", systemImage: "camera") { retake() }
            }
        }
    }

    private func retake() {
        withAnimation(.easeInOut(duration: 0.2)) {
            image = nil
            pills = [:]
            pillPage = 0
            hasSent = false
        }
    }

    private func controlButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(DotFont.ui(15, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.boardBackground))
        }
        .buttonStyle(SquishyButtonStyle())
    }

    // MARK: Pill data (place / weather resolution)

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

    private func resolveWeather() async {
        do {
            let loc = try await locationProvider.current()
            let w = try await WeatherProvider.current(for: loc)
            update(.weather) { $0.icon = w.icon; $0.text = w.text }
        } catch {
            remove(.weather)
            appModel.showToast("couldn't get the weather", icon: "cloud.slash.fill")
        }
    }

    private func update(_ kind: StickerKind, _ change: (inout PhotoSticker) -> Void) {
        guard var pill = pills[kind] else { return }
        change(&pill)
        pills[kind] = pill
    }

    private func remove(_ kind: StickerKind) {
        pills[kind] = nil
    }

    // MARK: Send

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
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.blue)
            )
            .scaleEffect(justSent && !reduceMotion ? 1.04 : 1.0)
            .opacity(sendDisabled ? 0.45 : 1)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(sendDisabled)
        .animation(.easeInOut(duration: 0.2), value: sendDisabled)
    }

    /// Nothing to send: no photo yet, this exact framed shot already went out, or —
    /// in the inline flow, when you have friends — nobody picked in the strip.
    private var sendDisabled: Bool {
        image == nil || hasSent
            || (SendFlow.useInlineRecipients && appModel.canPickRecipients && !appModel.hasRecipientSelection)
    }

    private func attemptSend() {
        guard let data = renderWidgetJPEG() else { return }
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

    /// The current pill, if any — the only thing baked over the photo.
    private var activeStickers: [PhotoSticker] {
        guard let kind = currentKind, let pill = pills[kind] else { return [] }
        return [pill]
    }

    /// The center-cropped square → downscaled, widget-safe JPEG, with the current pill
    /// (if any) baked in at the same spot you see on screen.
    @MainActor
    private func renderWidgetJPEG() -> Data? {
        guard let image, let rect = centerSquareRect() else { return nil }

        // Plain photo (no pill) → the straight center-crop fast path.
        let active = activeStickers
        guard !active.isEmpty, frameSide > 0,
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
            ForEach(active) { s in
                StickerChip(icon: s.icon, text: s.text)
                    .position(x: s.position.x * side, y: s.position.y * side)
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

    private func setImage(_ new: UIImage) {
        image = new.normalizedUp()
        pills = [:]       // start the new photo on the plain page
        pillPage = 0
        withAnimation { hasSent = false }   // new photo → can send again
    }
}

//
//  PhotoComposerView.swift
//  Dot Grid
//
//  Photo mode (V1): pick or shoot a photo, frame it in a square crop window that
//  matches the widget, and send. What sits inside the frame is exactly what gets
//  sent — WYSIWYG with the widget.
//

import AVFoundation
import SwiftUI
import UIKit

struct PhotoComposerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: UIImage?

    // Committed framing; live gesture deltas layer on top.
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    // One sheet at a time. Two separate `.sheet` modifiers on the same view
    // corrupt SwiftUI's presentation state when the PHPicker dismisses itself,
    // which left the whole screen unresponsive (you had to kill the app).
    private enum ActiveSheet: Identifiable {
        case gallery, recipients
        var id: Int { hashValue }
    }
    @State private var activeSheet: ActiveSheet?
    @State private var showCamera = false
    @State private var showCameraDenied = false

    @State private var pendingPhoto: Data?
    @State private var justSent = false
    @State private var sendResetTask: Task<Void, Never>?
    // True once this exact framed shot has been sent; the button shows "sent" +
    // disables until you pick a new photo or re-frame it.
    @State private var hasSent = false

    // Stickers baked into the sent photo. Positions are normalized to the frame.
    @State private var stickers: [PhotoSticker] = []
    @State private var frameSide: CGFloat = 0
    @State private var locationProvider = LocationProvider()

    private let maxZoom: CGFloat = 5
    private let stickerSpace = "stickerFrame"
    private let sendHaptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 16) {
            frame
            if image != nil { stickerTray }
            controls
            Spacer(minLength: 0)
            sendButton
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .gallery:
                GalleryPicker { setImage($0) }.ignoresSafeArea()
            case .recipients:
                RecipientPickerView { recipients in finalizeSend(to: recipients) }
                    .sheetGrabber()
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { setImage($0) }.ignoresSafeArea()
        }
        .alert("camera access is off", isPresented: $showCameraDenied) {
            Button("open settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("use gallery", role: .cancel) { activeSheet = .gallery }
        } message: {
            Text("enable camera in settings to take a photo, or pick one from your gallery.")
        }
        .onAppear { sendHaptic.prepare() }
    }

    // MARK: Framing window

    private var frame: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Palette.boardBackground)

                if let image {
                    framedImage(image, side: side)
                        .gesture(framingGesture(side: side))
                    stickerLayer(side: side)
                } else {
                    emptyPrompt
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

    /// Draggable sticker pills layered over the photo (fixed size, drag to position).
    @ViewBuilder
    private func stickerLayer(side: CGFloat) -> some View {
        ForEach($stickers) { $sticker in
            StickerChip(icon: sticker.icon, text: sticker.text)
                .position(x: sticker.position.x * side, y: sticker.position.y * side)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(stickerSpace))
                        .onChanged { value in
                            sticker.position = CGPoint(
                                x: min(max(value.location.x / side, 0.10), 0.90),
                                y: min(max(value.location.y / side, 0.07), 0.93)
                            )
                            if hasSent { hasSent = false }   // moved → can send again
                        }
                )
        }
    }

    private func framedImage(_ image: UIImage, side: CGFloat) -> some View {
        let base = baseFillSize(for: image, side: side)
        let liveZoom = clampedZoom(zoom * pinch)
        let dw = base.width * liveZoom
        let dh = base.height * liveZoom
        let raw = CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
        let clamped = clampOffset(raw, dispW: dw, dispH: dh, side: side)
        return Image(uiImage: image)
            .resizable()
            .frame(width: dw, height: dh)
            .offset(x: clamped.width, y: clamped.height)
            .frame(width: side, height: side)
            .clipped()
    }

    private var emptyPrompt: some View {
        Button { activeSheet = .gallery } label: {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40, weight: .semibold))
                Text("Choose a photo")
                    .font(DotFont.ui(16, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.5))
        }
        .buttonStyle(SquishyButtonStyle())
    }

    private func framingGesture(side: CGFloat) -> some Gesture {
        let magnify = MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                guard let image else { return }
                let base = baseFillSize(for: image, side: side)
                zoom = clampedZoom(zoom * value.magnification)
                offset = clampOffset(offset, dispW: base.width * zoom, dispH: base.height * zoom, side: side)
                if hasSent { withAnimation { hasSent = false } }   // re-framed → can send again
            }
        let pan = DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                guard let image else { return }
                let base = baseFillSize(for: image, side: side)
                let dw = base.width * zoom
                let dh = base.height * zoom
                let moved = CGSize(width: offset.width + value.translation.width,
                                   height: offset.height + value.translation.height)
                offset = clampOffset(moved, dispW: dw, dispH: dh, side: side)
                if hasSent { withAnimation { hasSent = false } }   // re-framed → can send again
            }
        return magnify.simultaneously(with: pan)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            controlButton(title: "Gallery", systemImage: "photo") { activeSheet = .gallery }
            controlButton(title: "Camera", systemImage: "camera") { openCamera() }
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

    private func openCamera() {
        guard CameraPicker.isAvailable else { showCameraDenied = true; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized, .notDetermined:
            showCamera = true   // .notDetermined triggers the system prompt on present
        default:
            showCameraDenied = true
        }
    }

    // MARK: Stickers

    private var stickerTray: some View {
        HStack(spacing: 10) {
            ForEach(StickerKind.allCases) { kind in
                let active = stickers.contains { $0.kind == kind }
                Button { toggleSticker(kind) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.defaultIcon)
                        Text(kind.trayLabel)
                    }
                    .font(DotFont.ui(14, weight: .bold))
                    .foregroundStyle(active ? Theme.ink : .white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        Capsule(style: .continuous)
                            .fill(active ? Theme.cream : Palette.boardBackground)
                    )
                }
                .buttonStyle(SquishyButtonStyle())
            }
        }
    }

    /// Tap a tray pill to add that sticker; tap again to remove it.
    private func toggleSticker(_ kind: StickerKind) {
        if stickers.contains(where: { $0.kind == kind }) {
            withAnimation(.snappy(duration: 0.2)) { remove(kind) }
            if hasSent { hasSent = false }
            return
        }
        if hasSent { hasSent = false }
        switch kind {
        case .time:
            addSticker(.time, icon: kind.defaultIcon,
                       text: Date.now.formatted(date: .omitted, time: .shortened))
        case .location:
            addSticker(.location, icon: kind.defaultIcon, text: "locating…")
            Task { await resolveLocation() }
        case .weather:
            addSticker(.weather, icon: kind.defaultIcon, text: "…")
            Task { await resolveWeather() }
        }
    }

    private func addSticker(_ kind: StickerKind, icon: String, text: String) {
        // Stagger so multiple pills don't land exactly on top of each other.
        let pos = CGPoint(x: 0.5, y: min(0.30 + CGFloat(stickers.count) * 0.13, 0.85))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            stickers.append(PhotoSticker(kind: kind, icon: icon, text: text, position: pos))
        }
    }

    private func resolveLocation() async {
        do {
            let loc = try await locationProvider.current()
            let name = await locationProvider.placeName(for: loc)
            update(.location) { $0.text = name }
        } catch {
            remove(.location)
            appModel.banner = "couldn't get your location"
        }
    }

    private func resolveWeather() async {
        do {
            let loc = try await locationProvider.current()
            let w = try await WeatherProvider.current(for: loc)
            update(.weather) { $0.icon = w.icon; $0.text = w.text }
        } catch {
            remove(.weather)
            appModel.banner = "couldn't get the weather"
        }
    }

    private func update(_ kind: StickerKind, _ change: (inout PhotoSticker) -> Void) {
        guard let idx = stickers.firstIndex(where: { $0.kind == kind }) else { return }
        change(&stickers[idx])
    }

    private func remove(_ kind: StickerKind) {
        stickers.removeAll { $0.kind == kind }
    }

    // MARK: Send

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

    /// Nothing to send: no photo yet, or this exact framed shot already went out.
    private var sendDisabled: Bool { image == nil || hasSent }

    private func attemptSend() {
        guard let data = renderWidgetJPEG() else { return }
        pendingPhoto = data
        if appModel.isSignedIn && !appModel.friends.isEmpty {
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

    /// The exact framed square → downscaled, widget-safe JPEG, with any stickers
    /// baked in at the same positions you see on screen.
    @MainActor
    private func renderWidgetJPEG() -> Data? {
        guard let image, let rect = framedRect() else { return nil }

        // No stickers → the original straight-crop fast path.
        guard !stickers.isEmpty, frameSide > 0,
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
            ForEach(stickers) { s in
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

    /// The normalized square region currently framed (committed zoom/offset). Only
    /// ratios matter, so any working `side` is fine.
    private func framedRect() -> CGRect? {
        guard let image else { return nil }
        let side: CGFloat = 1000
        let base = baseFillSize(for: image, side: side)
        let dw = base.width * zoom
        let dh = base.height * zoom
        let clamped = clampOffset(offset, dispW: dw, dispH: dh, side: side)
        let normX = (dw / 2 - clamped.width - side / 2) / dw
        let normY = (dh / 2 - clamped.height - side / 2) / dh
        return CGRect(x: normX, y: normY, width: side / dw, height: side / dh)
    }

    // MARK: Framing math

    private func setImage(_ new: UIImage) {
        image = new.normalizedUp()
        zoom = 1
        offset = .zero
        stickers = []                       // start the new photo clean
        withAnimation { hasSent = false }   // new photo → can send again
    }

    /// Aspect-fill size: the smallest size that fully covers the square frame.
    private func baseFillSize(for image: UIImage, side: CGFloat) -> CGSize {
        let a = image.size.height == 0 ? 1 : image.size.width / image.size.height
        return a >= 1 ? CGSize(width: side * a, height: side)
                      : CGSize(width: side, height: side / a)
    }

    private func clampedZoom(_ z: CGFloat) -> CGFloat { min(max(z, 1), maxZoom) }

    /// Keep the image covering the frame — never let a gap show.
    private func clampOffset(_ o: CGSize, dispW: CGFloat, dispH: CGFloat, side: CGFloat) -> CGSize {
        let maxX = max(0, (dispW - side) / 2)
        let maxY = max(0, (dispH - side) / 2)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }
}

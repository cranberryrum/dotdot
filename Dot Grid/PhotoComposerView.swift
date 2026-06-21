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

    @State private var showGallery = false
    @State private var showCamera = false
    @State private var showCameraDenied = false

    @State private var showRecipientPicker = false
    @State private var pendingPhoto: Data?
    @State private var justSent = false
    @State private var sendResetTask: Task<Void, Never>?

    private let maxZoom: CGFloat = 5
    private let sendHaptic = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 16) {
            frame
            controls
            Spacer(minLength: 0)
            sendButton
        }
        .sheet(isPresented: $showGallery) {
            GalleryPicker { setImage($0) }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { setImage($0) }.ignoresSafeArea()
        }
        .sheet(isPresented: $showRecipientPicker) {
            RecipientPickerView { recipients in finalizeSend(to: recipients) }
        }
        .alert("Camera access is off", isPresented: $showCameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Use gallery", role: .cancel) { showGallery = true }
        } message: {
            Text("Enable Camera in Settings to take a photo, or pick one from your gallery.")
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
                } else {
                    emptyPrompt
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
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
        Button { showGallery = true } label: {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40, weight: .semibold))
                Text("Choose a photo")
                    .font(DotFont.ui(16, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }

    private func framingGesture(side: CGFloat) -> some Gesture {
        let magnify = MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                guard let image else { return }
                let base = baseFillSize(for: image, side: side)
                zoom = clampedZoom(zoom * value.magnification)
                offset = clampOffset(offset, dispW: base.width * zoom, dispH: base.height * zoom, side: side)
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
            }
        return magnify.simultaneously(with: pan)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            controlButton(title: "Gallery", systemImage: "photo") { showGallery = true }
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

    // MARK: Send

    private var sendButton: some View {
        Button { attemptSend() } label: {
            HStack(spacing: 10) {
                Image(systemName: justSent ? "checkmark" : "paperplane.fill")
                    .contentTransition(.symbolEffect(.replace.downUp))
                Text(justSent ? "SENT!" : "SEND")
                    .contentTransition(.opacity)
            }
            .font(DotFont.heavy(19))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.blue)
                    .neonGlow(Theme.blue, tight: 6, soft: 18, enabled: image != nil)
            )
            .scaleEffect(justSent && !reduceMotion ? 1.04 : 1.0)
            .opacity(image == nil ? 0.5 : 1)
        }
        .buttonStyle(SquishyButtonStyle())
        .disabled(image == nil)
    }

    private func attemptSend() {
        guard let data = renderWidgetJPEG() else { return }
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
        withAnimation(morph) { justSent = true }
        sendResetTask?.cancel()
        sendResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(morph) { justSent = false }
        }
    }

    /// The exact framed square → downscaled, widget-safe JPEG.
    private func renderWidgetJPEG() -> Data? {
        guard let image else { return nil }
        // Recompute the framed region using committed zoom/offset against a unit
        // frame; only ratios matter, so any side works.
        let side: CGFloat = 1000
        let base = baseFillSize(for: image, side: side)
        let dw = base.width * zoom
        let dh = base.height * zoom
        let clamped = clampOffset(offset, dispW: dw, dispH: dh, side: side)
        let normX = (dw / 2 - clamped.width - side / 2) / dw
        let normY = (dh / 2 - clamped.height - side / 2) / dh
        let rect = CGRect(x: normX, y: normY, width: side / dw, height: side / dh)
        return ImageProcessing.widgetJPEG(from: image, normalizedRect: rect)
    }

    // MARK: Framing math

    private func setImage(_ new: UIImage) {
        image = new.normalizedUp()
        zoom = 1
        offset = .zero
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

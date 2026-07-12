//
//  Camera.swift
//  Dot Grid
//
//  The embedded live camera used by the Photo composer: a square preview that opens
//  in place (no modal picker), with in-frame flip (front/back) and wide-angle
//  (0.5× ultra-wide / 1×) controls and a shutter. Permission is requested when the
//  Photo tab becomes active; until it's granted — or on a device/simulator with no
//  camera — the composer shows a placeholder instead.
//
//  All AVFoundation work (configuration, start/stop, capture) runs on a private
//  session queue via continuations; the controller only mutates UI state on the main
//  actor (after the await), so the concurrent closures never capture `self`.
//

@preconcurrency import AVFoundation
import SwiftUI
import UIKit

@Observable
final class CameraController {
    /// Live camera-permission status (mirrors iOS Settings; refreshed on activate).
    private(set) var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var position: AVCaptureDevice.Position = .back
    /// Ultra-wide (0.5×) currently selected — back camera only.
    private(set) var isWide = false
    /// An ultra-wide lens exists for the current position (gates the wide button).
    private(set) var hasUltraWide = false
    /// A usable camera was found and the session is configured (false on the simulator).
    private(set) var isConfigured = false
    private(set) var hasCamera = true

    let session = AVCaptureSession()

    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "dotdot.camera.session")
    @ObservationIgnored private var captureDelegate: PhotoCaptureDelegate?

    // Orientation: a RotationCoordinator reports the correct (and often different)
    // rotation angles for the live preview vs. the captured photo, so shots come out
    // upright instead of sideways. Replaces the old hardcoded 90°.
    @ObservationIgnored private var currentDevice: AVCaptureDevice?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?

    var isAuthorized: Bool { status == .authorized }
    /// Show the live preview only once we have a configured, usable camera.
    var showsPreview: Bool { isAuthorized && isConfigured && hasCamera }

    // MARK: Permission + lifecycle

    func refreshStatus() { status = AVCaptureDevice.authorizationStatus(for: .video) }

    /// Called when the Photo tab becomes active. Asks for permission the first time,
    /// then configures + starts the session. No-op (the placeholder shows) when denied.
    func activate() { Task { await activateFlow() } }

    private func activateFlow() async {
        refreshStatus()
        switch status {
        case .authorized:
            if isConfigured { runSession(start: true) } else { await configure() }
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
            if granted { await configure() }
        default:
            break   // denied / restricted → placeholder routes to Settings
        }
    }

    func deactivate() { runSession(start: false) }

    /// Start/stop the running session off the main thread. Captures only the session.
    private func runSession(start: Bool) {
        let session = self.session
        sessionQueue.async {
            if start {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: Lens controls

    func flip() {
        Task { await setPosition(position == .back ? .front : .back) }
    }

    /// Switch to a specific camera and wait for the session to be reconfigured.
    /// The dual-shot flow uses this to flip to the selfie camera deterministically.
    func setPosition(_ new: AVCaptureDevice.Position) async {
        position = new
        if new != .back { isWide = false }   // front has no ultra-wide
        await configure()
    }

    /// Reset the NEXT session's camera without touching the running one — used when
    /// the dual-shot flow ends and the camera is about to be deactivated; the next
    /// `activate()` configures for this position (the one the user had open).
    func resetPosition(to new: AVCaptureDevice.Position) {
        position = new
        if new != .back { isWide = false }
    }

    /// Wait until the preview layer is actually rendering frames (or the timeout
    /// passes). After an input switch the first frame can lag the configuration by
    /// a few hundred ms — the dual-shot countdown must never run over a black frame.
    func waitUntilPreviewLive(timeout: TimeInterval = 1.5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if previewLayer?.isPreviewing == true { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func toggleWide() {
        guard hasUltraWide else { return }
        isWide.toggle()
        Task { await configure() }
    }

    // MARK: Capture

    func capturePhoto() async -> UIImage? {
        guard isConfigured else { return nil }
        let output = self.photoOutput
        let mirror = position == .front
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let delegate = PhotoCaptureDelegate { image in continuation.resume(returning: image) }
            self.captureDelegate = delegate   // keep alive until the callback fires
            sessionQueue.async {
                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
                    if connection.isVideoMirroringSupported { connection.isVideoMirrored = mirror }
                }
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off   // never carries between dual-shot frames
                // Speed over max processing quality: the image is downscaled to
                // ~1100px for the widget anyway, and dual shot needs a snappy
                // handoff from the first shot to the second camera's countdown.
                settings.photoQualityPrioritization = .speed
                output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: Session configuration

    /// Configure inputs/outputs off the main thread, then publish the results when the
    /// continuation returns (back on the main actor — no `self` in the concurrent work).
    private func configure() async {
        let session = self.session
        let output = self.photoOutput
        let position = self.position
        let wantWide = self.isWide
        let result: (hasCamera: Bool, ultra: Bool, device: AVCaptureDevice?) = await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.beginConfiguration()
                session.sessionPreset = .photo
                for input in session.inputs { session.removeInput(input) }

                guard let device = Self.device(position: position, wide: wantWide),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    session.commitConfiguration()
                    continuation.resume(returning: (false, false, nil))
                    return
                }
                if session.canAddInput(input) { session.addInput(input) }
                if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
                // Cut shutter lag where the hardware supports it (no-ops elsewhere).
                if output.isResponsiveCaptureSupported { output.isResponsiveCaptureEnabled = true }
                if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = true }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: (true, Self.ultraWideAvailable(position: position), device))
            }
        }
        hasCamera = result.hasCamera
        hasUltraWide = result.ultra
        isConfigured = result.hasCamera
        currentDevice = result.device
        if let device = result.device { setUpRotation(for: device) }
    }

    // MARK: Rotation (orientation-correct preview + capture)

    /// CameraPreview hands us its layer so the coordinator can drive preview rotation.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if let device = currentDevice { setUpRotation(for: device) }
    }

    /// Bind a RotationCoordinator to the active device + preview layer. It reports the
    /// correct angles for the live preview and for the captured photo (which can differ),
    /// so what you shoot comes out upright like the preview — no hardcoded rotation.
    private func setUpRotation(for device: AVCaptureDevice) {
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        applyPreviewRotation()
        // Keep the preview level if the device rotates. KVO can fire off-main, so hop.
        rotationObservation = rotationCoordinator?.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyPreviewRotation() } }
        }
    }

    private func applyPreviewRotation() {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
              let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// The wide-angle (1×) device for a position, or its ultra-wide (0.5×) sibling when
    /// asked and available; falls back to the plain wide-angle camera.
    private static func device(position: AVCaptureDevice.Position, wide: Bool) -> AVCaptureDevice? {
        if wide, position == .back,
           let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) {
            return ultra
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private static func ultraWideAvailable(position: AVCaptureDevice.Position) -> Bool {
        position == .back &&
            AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
    }
}

/// Receives the captured photo off the AV queue and hands back a `UIImage`. Holds only
/// an immutable `@Sendable` completion, so it's safe to hand to the session queue.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (UIImage?) -> Void
    init(completion: @escaping @Sendable (UIImage?) -> Void) { self.completion = completion }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { UIImage(data: $0) }
        completion(image)
    }
}

/// A live-preview view backed by `AVCaptureVideoPreviewLayer`, aspect-filled to its
/// (square) frame. Rotation is driven by the controller's RotationCoordinator.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = camera.session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

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
        position = position == .back ? .front : .back
        if position != .back { isWide = false }   // front has no ultra-wide
        Task { await configure() }
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
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let delegate = PhotoCaptureDelegate { image in continuation.resume(returning: image) }
            self.captureDelegate = delegate   // keep alive until the callback fires
            sessionQueue.async {
                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                    if connection.isVideoMirroringSupported { connection.isVideoMirrored = mirror }
                }
                output.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
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
        let result: (hasCamera: Bool, ultra: Bool) = await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.beginConfiguration()
                session.sessionPreset = .photo
                for input in session.inputs { session.removeInput(input) }

                guard let device = Self.device(position: position, wide: wantWide),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    session.commitConfiguration()
                    continuation.resume(returning: (false, false))
                    return
                }
                if session.canAddInput(input) { session.addInput(input) }
                if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: (true, Self.ultraWideAvailable(position: position)))
            }
        }
        hasCamera = result.hasCamera
        hasUltraWide = result.ultra
        isConfigured = result.hasCamera
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
/// (square) frame and locked to portrait.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
        if let connection = uiView.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90   // portrait
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

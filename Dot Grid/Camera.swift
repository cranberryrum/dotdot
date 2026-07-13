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
    /// The position the running session is ACTUALLY configured for. `position` is the
    /// intent; after a state-only reset (dual shot winding down) they can disagree —
    /// activate must reconfigure then, not just resume the stale input.
    @ObservationIgnored private var configuredPosition: AVCaptureDevice.Position?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var rotationObservation: NSKeyValueObservation?

    var isAuthorized: Bool { status == .authorized }
    /// Show the live preview only once we have a configured, usable camera.
    var showsPreview: Bool { isAuthorized && isConfigured && hasCamera }

    // MARK: Dual (simultaneous multi-cam) state

    /// Hard device gate: dual shot exists ONLY where multi-cam does. False on the
    /// simulator and unsupported hardware — the UI must not even show the toggle.
    static var multiCamSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    /// A multi-cam session is built and running (both feeds live).
    private(set) var isDualActive = false
    /// The multi-cam session is interrupted (call, thermal, camera in use elsewhere).
    private(set) var dualInterrupted = false

    @ObservationIgnored private var multiSession: AVCaptureMultiCamSession?
    @ObservationIgnored private var dualBackInput: AVCaptureDeviceInput?
    @ObservationIgnored private var dualFrontInput: AVCaptureDeviceInput?
    @ObservationIgnored private var dualBackOutput: AVCapturePhotoOutput?
    @ObservationIgnored private var dualFrontOutput: AVCapturePhotoOutput?
    @ObservationIgnored private var dualBackRotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var dualFrontRotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private weak var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var dualObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var dualDelegates: [PhotoCaptureDelegate] = []

    // MARK: Permission + lifecycle

    func refreshStatus() { status = AVCaptureDevice.authorizationStatus(for: .video) }

    /// Called when the Photo tab becomes active. Asks for permission the first time,
    /// then configures + starts the session. No-op (the placeholder shows) when denied.
    func activate() {
        guard !isDualActive else { return }   // the multi-cam session owns the camera
        Task { await activateFlow() }
    }

    private func activateFlow() async {
        refreshStatus()
        switch status {
        case .authorized:
            // Resume only if the session is configured for the camera we INTEND —
            // after a dual shot the position is reset state-only, and resuming the
            // stale session would show (and capture!) the wrong camera.
            if isConfigured && configuredPosition == position {
                runSession(start: true)
            } else {
                await configure()
            }
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
            if granted { await configure() }
        default:
            break   // denied / restricted → placeholder routes to Settings
        }
    }

    /// Stop whatever is running. A live multi-cam session is torn down COMPLETELY —
    /// battery/thermal cost is real; it never survives off-screen.
    func deactivate() {
        if isDualActive { Task { await exitDual(resumeSingle: false) } }
        runSession(start: false)
    }

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

    // MARK: Dual (simultaneous multi-cam) engine

    /// Build + start the multi-cam session (back + front live at once). Returns
    /// whether it's running. The single session is stopped first; on failure it is
    /// restarted so the caller can stay in single mode.
    func enterDual() async -> Bool {
        guard Self.multiCamSupported, !isDualActive, isAuthorized else { return false }

        let single = self.session
        let built: (session: AVCaptureMultiCamSession,
                    backIn: AVCaptureDeviceInput, frontIn: AVCaptureDeviceInput,
                    backOut: AVCapturePhotoOutput, frontOut: AVCapturePhotoOutput)? =
            await withCheckedContinuation { continuation in
                sessionQueue.async {
                    if single.isRunning { single.stopRunning() }

                    let multi = AVCaptureMultiCamSession()
                    multi.beginConfiguration()

                    func wire(_ position: AVCaptureDevice.Position)
                        -> (AVCaptureDeviceInput, AVCapturePhotoOutput)? {
                        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                                   for: .video, position: position),
                              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
                        // Conservative, multi-cam-capable format: the composite is
                        // widget-sized, so favor thermal headroom over pixels.
                        if let format = Self.dualFormat(for: device) {
                            try? device.lockForConfiguration()
                            device.activeFormat = format
                            device.unlockForConfiguration()
                        }
                        guard multi.canAddInput(input) else { return nil }
                        multi.addInputWithNoConnections(input)
                        guard let port = input.ports(for: .video,
                                                     sourceDeviceType: device.deviceType,
                                                     sourceDevicePosition: position).first else { return nil }
                        let output = AVCapturePhotoOutput()
                        guard multi.canAddOutput(output) else { return nil }
                        multi.addOutputWithNoConnections(output)
                        let connection = AVCaptureConnection(inputPorts: [port], output: output)
                        guard multi.canAddConnection(connection) else { return nil }
                        multi.addConnection(connection)
                        if position == .front, connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = true   // selfies read like a mirror
                        }
                        return (input, output)
                    }

                    guard let back = wire(.back), let front = wire(.front) else {
                        multi.commitConfiguration()
                        if !single.isRunning { single.startRunning() }   // stay usable in single mode
                        continuation.resume(returning: nil)
                        return
                    }
                    multi.commitConfiguration()
                    // Too heavy for this device's capture hardware / thermals?
                    // Bail to single cleanly instead of a runtime error later.
                    if multi.hardwareCost > 1.0 || multi.systemPressureCost > 1.0 {
                        if !single.isRunning { single.startRunning() }
                        continuation.resume(returning: nil)
                        return
                    }
                    multi.startRunning()
                    continuation.resume(returning: (multi, back.0, front.0, back.1, front.1))
                }
            }

        guard let built else { return false }
        multiSession = built.session
        dualBackInput = built.backIn
        dualFrontInput = built.frontIn
        dualBackOutput = built.backOut
        dualFrontOutput = built.frontOut
        dualBackRotation = AVCaptureDevice.RotationCoordinator(device: built.backIn.device, previewLayer: nil)
        dualFrontRotation = AVCaptureDevice.RotationCoordinator(device: built.frontIn.device, previewLayer: nil)
        isDualActive = true
        dualInterrupted = false
        observeDualSession(built.session)
        // Re-wire whatever preview layers are already mounted onto the new session.
        if let layer = previewLayer { wireDualPreview(layer, position: .back) }
        if let layer = frontPreviewLayer { wireDualPreview(layer, position: .front) }
        return true
    }

    /// Tear the multi-cam session down completely. `resumeSingle` restarts the plain
    /// session (exiting dual while staying on the camera); leaving the screen passes
    /// false and the normal activate path takes over next time.
    func exitDual(resumeSingle: Bool) async {
        guard isDualActive || multiSession != nil else { return }
        isDualActive = false
        dualInterrupted = false
        for observer in dualObservers { NotificationCenter.default.removeObserver(observer) }
        dualObservers = []
        let multi = multiSession
        multiSession = nil
        dualBackInput = nil; dualFrontInput = nil
        dualBackOutput = nil; dualFrontOutput = nil
        dualBackRotation = nil; dualFrontRotation = nil
        dualDelegates = []

        let single = self.session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                multi?.stopRunning()   // inputs/outputs/connections die with the session
                if resumeSingle, !single.isRunning { single.startRunning() }
                continuation.resume()
            }
        }
        // Hand the main preview layer back to the single session — detaching first,
        // so it never carries a stale multi-cam connection into the re-bind.
        if resumeSingle, let layer = previewLayer {
            layer.session = nil
            layer.session = single
            if let device = currentDevice { setUpRotation(for: device) }
        }
    }

    /// One trigger, both frames — the two capture calls land on the session queue
    /// back-to-back, so the frames are captured in the same instant.
    func captureDual() async -> (back: UIImage?, front: UIImage?) {
        guard isDualActive, let backOutput = dualBackOutput, let frontOutput = dualFrontOutput else {
            return (nil, nil)
        }
        let backAngle = dualBackRotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        let frontAngle = dualFrontRotation?.videoRotationAngleForHorizonLevelCapture ?? 90
        dualDelegates.removeAll()
        async let back: UIImage? = captureDualFrame(from: backOutput, angle: backAngle)
        async let front: UIImage? = captureDualFrame(from: frontOutput, angle: frontAngle)
        return await (back, front)
    }

    private func captureDualFrame(from output: AVCapturePhotoOutput, angle: CGFloat) async -> UIImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let delegate = PhotoCaptureDelegate { image in continuation.resume(returning: image) }
            dualDelegates.append(delegate)   // keep alive until the callback fires
            sessionQueue.async {
                if let connection = output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                let settings = AVCapturePhotoSettings()
                settings.flashMode = .off
                settings.photoQualityPrioritization = .speed
                output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    /// Preview layers delegate their wiring here: plain `.session` binding in single
    /// mode, an explicit no-connection bind + connection on the multi-cam session.
    func attachFrontPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        frontPreviewLayer = layer
        if isDualActive { wireDualPreview(layer, position: .front) }
    }

    private func wireDualPreview(_ layer: AVCaptureVideoPreviewLayer, position: AVCaptureDevice.Position) {
        guard let multi = multiSession,
              let input = position == .back ? dualBackInput : dualFrontInput else { return }
        let deviceType = input.device.deviceType
        // Safe by construction: during wiring, ONLY the session queue touches the
        // layer (the Apple multi-cam sample's pattern) — hence the unsafe transfer.
        nonisolated(unsafe) let layer = layer
        // ALL layer wiring on one thread (the session queue, like Apple's multi-cam
        // sample): mixing main-thread layer mutation with in-flight session config
        // is exception territory.
        sessionQueue.async {
            guard let port = input.ports(for: .video, sourceDeviceType: deviceType,
                                         sourceDevicePosition: position).first else { return }
            // Detach from whatever session the layer was on FIRST — migrating a
            // layer that still holds its old (implicit) connection into another
            // session raises an AVFoundation exception, which kills the app.
            if layer.session != nil, layer.session !== multi { layer.session = nil }
            layer.setSessionWithNoConnection(multi)
            let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: layer)
            guard multi.canAddConnection(connection) else { return }
            multi.beginConfiguration()
            multi.addConnection(connection)
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if position == .front, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            multi.commitConfiguration()
        }
    }

    /// Interruptions (call, thermal, camera claimed elsewhere): flag a paused state
    /// the pip can show; resume clears it. A runtime error means the session is not
    /// coming back — tear down to single so the UI can morph out cleanly.
    private func observeDualSession(_ session: AVCaptureMultiCamSession) {
        let center = NotificationCenter.default
        dualObservers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                               object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dualInterrupted = true }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                               object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dualInterrupted = false }
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                               object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isDualActive else { return }
                    Task { await self.exitDual(resumeSingle: true) }
                }
            },
        ]
    }

    /// The smallest multi-cam-capable format that's still comfortably sharper than
    /// the widget composite (≥1280 wide) — thermal headroom over pixels.
    /// `nonisolated`: runs on the session queue during the dual build.
    private nonisolated static func dualFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let capable = device.formats.filter(\.isMultiCamSupported)
        func width(_ format: AVCaptureDevice.Format) -> Int32 {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
        }
        return capable.filter { width($0) >= 1280 }.min { width($0) < width($1) }
            ?? capable.max { width($0) < width($1) }
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
        configuredPosition = result.hasCamera ? position : nil
        currentDevice = result.device
        if let device = result.device { setUpRotation(for: device) }
    }

    // MARK: Rotation (orientation-correct preview + capture)

    /// CameraPreview hands us its layer; the controller owns ALL wiring — a plain
    /// `.session` bind in single mode, an explicit connection on the multi-cam session
    /// in dual mode. The representables never touch `.session` themselves.
    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        if isDualActive {
            wireDualPreview(layer, position: .back)
        } else {
            layer.session = session
            if let device = currentDevice { setUpRotation(for: device) }
        }
    }

    /// Cheap idempotent re-check from updateUIView: re-bind only when stale (each
    /// bind is a synchronous handshake with the capture pipeline — never repeat it).
    func ensureMainPreviewWiring(_ layer: AVCaptureVideoPreviewLayer) {
        if isDualActive {
            if layer.session !== multiSession { wireDualPreview(layer, position: .back) }
        } else if layer.session !== session {
            layer.session = session
            if let device = currentDevice { setUpRotation(for: device) }
        }
    }

    /// Same idempotent re-check for the selfie pip layer (dual mode only).
    func ensureFrontPreviewWiring(_ layer: AVCaptureVideoPreviewLayer) {
        guard isDualActive, layer.session !== multiSession else { return }
        wireDualPreview(layer, position: .front)
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

/// The main live preview (single-camera feed, or the BACK feed in dual mode),
/// aspect-filled to its (square) frame. All session wiring is delegated to the
/// controller — see `attachPreviewLayer`.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        camera.ensureMainPreviewWiring(uiView.previewLayer)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// The selfie feed inside the dual-mode pip card. Only meaningful while the
/// multi-cam session is live; wiring is delegated to the controller.
struct FrontCameraPreview: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> CameraPreview.PreviewView {
        let view = CameraPreview.PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachFrontPreviewLayer(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: CameraPreview.PreviewView, context: Context) {
        camera.ensureFrontPreviewWiring(uiView.previewLayer)
    }
}

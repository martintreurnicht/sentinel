@preconcurrency import AVFoundation
import Foundation

/// Grabs frames from the webcam for presence checks, two ways:
/// - One-shot (default): start a session, grab one frame, stop — the camera and its
///   indicator light are only active during a check.
/// - Continuous ("Keep Camera On"): one long-lived session stays running while
///   monitoring is active, so the light is steady instead of flashing and a check
///   just latches the next live frame.
///
/// All mutable state is confined to `sessionQueue`; both capture paths and every
/// continuous-session start/stop/rebuild serialize there, so a mode or device
/// switch during an in-flight capture simply queues behind it.
final class CameraService: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
    }

    enum CameraError: Error {
        case deviceUnavailable
        case configurationFailed
        case timeout
    }

    /// Serial queue for all session work; `startRunning()` blocks for ~0.5–1.5s,
    /// which must never happen on the main thread or a concurrency-pool thread we await on.
    private let sessionQueue = DispatchQueue(label: "com.github.martintreurnicht.sentinel.camera")

    // Continuous-session state. Only touched on `sessionQueue`.
    private var desiredContinuous = false
    private var continuousSession: AVCaptureSession?
    private var continuousLatch: LiveFrameLatch?
    /// The *configured* device ID the running session was built for (nil = automatic),
    /// so a settings change shows up as a mismatch and triggers a rebuild.
    private var continuousDeviceID: String?
    private var runtimeErrorToken: NSObjectProtocol?

    func captureFrame(deviceUniqueID: String?, warmupFrames: Int, timeout: TimeInterval) async throws -> Frame {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let result = self.capture(
                    deviceUniqueID: deviceUniqueID,
                    warmupFrames: warmupFrames,
                    timeout: timeout
                )
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Continuous session

    /// Desired continuous-session state. Fire-and-forget: reconciles asynchronously
    /// on `sessionQueue` (start, stop, or rebuild for a device change). Idempotent.
    func setContinuousCapture(enabled: Bool, deviceUniqueID: String?) {
        sessionQueue.async {
            self.desiredContinuous = enabled
            self.reconcileContinuousSession(deviceUniqueID: deviceUniqueID)
        }
    }

    /// Brings the continuous session in line with what is desired: tears it down when
    /// disabled (or unauthorized), rebuilds it when dead or built for another device,
    /// no-ops when it is already healthy. Runs on `sessionQueue`.
    private func reconcileContinuousSession(deviceUniqueID: String?) {
        guard desiredContinuous else {
            teardownContinuousSession()
            return
        }
        // Status check only — prompting stays with CameraPresenceChecker. Until access
        // is granted the session simply does not start; the first check after the
        // grant reconciles again and brings it up.
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            teardownContinuousSession()
            return
        }
        if let session = continuousSession {
            if session.isRunning, continuousDeviceID == deviceUniqueID {
                return
            }
            teardownContinuousSession()
        }
        startContinuousSession(deviceUniqueID: deviceUniqueID)
    }

    private func startContinuousSession(deviceUniqueID: String?) {
        guard let device = Self.resolveDevice(uniqueID: deviceUniqueID) else {
            Log.camera.error("no usable camera device for continuous session")
            return
        }
        let latch = LiveFrameLatch()
        let session: AVCaptureSession
        do {
            session = try Self.makeConfiguredSession(
                device: device,
                delegate: latch,
                queueLabel: "com.github.martintreurnicht.sentinel.camera.live"
            )
        } catch {
            Log.camera.error("continuous session configuration failed: \(String(describing: error), privacy: .public); will use one-shot captures")
            return
        }
        runtimeErrorToken = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self, let errored = notification.object as? AVCaptureSession else { return }
            let erroredID = ObjectIdentifier(errored)
            let description = String(describing: notification.userInfo?[AVCaptureSessionErrorKey] ?? "unknown")
            self.sessionQueue.async {
                // A stale error from an already-replaced session must not kill its successor.
                guard let current = self.continuousSession, ObjectIdentifier(current) == erroredID else { return }
                Log.camera.error("continuous session runtime error: \(description, privacy: .public); will rebuild on next check")
                self.teardownContinuousSession()
            }
        }
        Log.camera.notice("starting continuous session on \(device.localizedName, privacy: .public)")
        session.startRunning()
        continuousSession = session
        continuousLatch = latch
        continuousDeviceID = deviceUniqueID
    }

    private func teardownContinuousSession() {
        guard let session = continuousSession else { return }
        if let token = runtimeErrorToken {
            NotificationCenter.default.removeObserver(token)
        }
        runtimeErrorToken = nil
        session.stopRunning()
        continuousSession = nil
        continuousLatch = nil
        continuousDeviceID = nil
        Log.camera.notice("continuous session stopped")
    }

    // MARK: - Capture

    /// Runs on `sessionQueue`. Prefers the continuous session when it is (or can be)
    /// running; otherwise falls back to the one-shot start/stop capture.
    private func capture(deviceUniqueID: String?, warmupFrames: Int, timeout: TimeInterval) -> Result<Frame, Error> {
        let sessionBefore = continuousSession
        reconcileContinuousSession(deviceUniqueID: deviceUniqueID)
        if let latch = continuousLatch, continuousSession?.isRunning == true {
            // A session that survived reconcile is warm and delivers the next frame
            // in ~one frame interval; one reconcile just (re)built — cold start or
            // device-switch rebuild — gets the full budget for startup and warmup,
            // as in a one-shot capture.
            let wasWarm = continuousSession === sessionBefore
            let latchTimeout = wasWarm ? min(2, timeout) : timeout
            if let buffer = latch.nextFrame(warmupFrames: warmupFrames, timeout: latchTimeout) {
                Log.camera.info("captured live frame from continuous session")
                return .success(Frame(pixelBuffer: buffer))
            }
            Log.camera.error("continuous session produced no frame; falling back to one-shot capture")
            teardownContinuousSession()
        }
        return Self.blockingCapture(deviceUniqueID: deviceUniqueID, warmupFrames: warmupFrames, timeout: timeout)
    }

    /// Blocking by design: the queue's thread parks on a semaphore until the sink
    /// has seen enough frames or the timeout expires.
    private static func blockingCapture(
        deviceUniqueID: String?,
        warmupFrames: Int,
        timeout: TimeInterval
    ) -> Result<Frame, Error> {
        guard let device = resolveDevice(uniqueID: deviceUniqueID) else {
            Log.camera.error("no usable camera device found")
            return .failure(CameraError.deviceUnavailable)
        }

        let sink = FrameSink(warmupFrames: warmupFrames)
        let session: AVCaptureSession
        do {
            session = try makeConfiguredSession(
                device: device,
                delegate: sink,
                queueLabel: "com.github.martintreurnicht.sentinel.camera.frames"
            )
        } catch {
            Log.camera.error("capture configuration failed: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }

        Log.camera.info("capturing one frame from \(device.localizedName, privacy: .public)")
        session.startRunning()
        defer { session.stopRunning() }

        guard sink.semaphore.wait(timeout: .now() + timeout) == .success, let buffer = sink.capturedBuffer else {
            Log.camera.error("timed out waiting for a frame from \(device.localizedName, privacy: .public)")
            return .failure(CameraError.timeout)
        }
        return .success(Frame(pixelBuffer: buffer))
    }

    /// Shared configuration for both capture paths (VGA, discard late frames,
    /// bi-planar YCbCr) so they cannot drift apart.
    private static func makeConfiguredSession(
        device: AVCaptureDevice,
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        queueLabel: String
    ) throws -> AVCaptureSession {
        let session = AVCaptureSession()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.configurationFailed }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: queueLabel))
        guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
        session.addOutput(output)
        return session
    }

    static func resolveDevice(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, !uniqueID.isEmpty {
            if let device = AVCaptureDevice(uniqueID: uniqueID) {
                return device
            }
            Log.camera.warning("configured camera \(uniqueID, privacy: .public) not found; falling back to automatic")
        }
        return AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
    }

    static func availableCameras() -> [(name: String, uniqueID: String)] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { ($0.localizedName, $0.uniqueID) }
    }
}

/// Delegate for the continuous session. Stores nothing between requests: a request
/// latches the next frame that arrives *after* it was registered, so a check always
/// judges a live frame and no pixel buffer is retained between checks (which would
/// starve AVFoundation's small buffer pool).
final class LiveFrameLatch: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private struct Pending {
        let minFrames: Int
        let semaphore: DispatchSemaphore
        var buffer: CVPixelBuffer?
    }

    private let lock = NSLock()
    /// Frames seen since the session started. Requests require this to exceed their
    /// warmup count, so a capture right after a cold start still waits out
    /// auto-exposure settling, while requests against a warm session return the
    /// very next frame.
    private var frameCount = 0
    private var pending: Pending?

    /// Blocks until the next post-warmup frame arrives or the timeout expires.
    /// Callers are serialized on the camera's session queue, so at most one request
    /// is pending at a time. The pending slot is cleared on every exit path.
    func nextFrame(warmupFrames: Int, timeout: TimeInterval) -> CVPixelBuffer? {
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock { pending = Pending(minFrames: warmupFrames, semaphore: semaphore, buffer: nil) }
        defer { lock.withLock { pending = nil } }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { pending?.buffer }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        ingest(CMSampleBufferGetImageBuffer(sampleBuffer))
    }

    /// Internal so tests can drive the latch without AVFoundation objects.
    func ingest(_ pixelBuffer: CVPixelBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        frameCount += 1
        guard var request = pending, request.buffer == nil,
              frameCount > request.minFrames, let pixelBuffer else { return }
        request.buffer = pixelBuffer
        pending = request
        request.semaphore.signal()
    }
}

/// Counts frames on the delegate queue, keeps the first post-warmup frame, and signals.
private final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let warmupFrames: Int
    private let lock = NSLock()
    private var frameCount = 0
    private var buffer: CVPixelBuffer?

    init(warmupFrames: Int) {
        self.warmupFrames = warmupFrames
    }

    var capturedBuffer: CVPixelBuffer? {
        lock.withLock { buffer }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard buffer == nil else { return }
        frameCount += 1
        guard frameCount > warmupFrames, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        buffer = pixelBuffer
        semaphore.signal()
    }
}

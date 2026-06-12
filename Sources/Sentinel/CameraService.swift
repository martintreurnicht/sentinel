@preconcurrency import AVFoundation
import Foundation

/// Grabs frames from the webcam for presence checks, two ways:
/// - One-shot (default): start a session, grab one frame, stop — the camera and its
///   indicator light are only active during a check.
/// - Continuous ("Keep Camera On"): one long-lived session stays running while
///   monitoring is active, so the light is steady instead of flashing and a check
///   just latches the next live frame. The session follows the camera selection:
///   when its device disappears it is rebuilt on the fallback, and it moves back
///   as soon as the preferred camera reconnects.
///
/// All mutable state is confined to `sessionQueue`; both capture paths and every
/// continuous-session start/stop/rebuild serialize there, so a mode, device, or
/// resolution switch during an in-flight capture simply queues behind it.
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
    /// The *configured* device ID and resolution continuous capture should use
    /// (nil = automatic/default). Kept current by every reconcile request so the
    /// device-connected observer re-evaluates against the latest configuration.
    private var desiredDeviceID: String?
    private var desiredResolution: CaptureResolution?
    private var continuousSession: AVCaptureSession?
    private var continuousLatch: LiveFrameLatch?
    /// The *configured* resolution the running session was built for, so a settings
    /// change shows up as a mismatch and triggers a rebuild. (The device needs no such
    /// bookkeeping: reconcile compares the session's actual device against a fresh
    /// `resolveDevice`, so a re-plugged preferred camera also reads as stale.)
    private var continuousResolution: CaptureResolution?
    private var runtimeErrorToken: NSObjectProtocol?
    private var deviceConnectedToken: NSObjectProtocol?

    init() {
        // A newly connected camera may be one the running session fell back from — or
        // may outrank the current device in automatic mode. Reconcile as soon as it
        // appears so switching back doesn't wait for the next check.
        deviceConnectedToken = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self,
                  let device = notification.object as? AVCaptureDevice,
                  device.hasMediaType(.video) else { return }
            let name = device.localizedName
            self.sessionQueue.async {
                guard self.desiredContinuous else { return }
                Log.camera.info("camera connected: \(name, privacy: .public); re-evaluating continuous session")
                self.reconcileContinuousSession()
            }
        }
    }

    deinit {
        if let token = deviceConnectedToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func captureFrame(deviceUniqueID: String?, resolution: CaptureResolution?, warmupFrames: Int, timeout: TimeInterval) async throws -> Frame {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let result = self.capture(
                    deviceUniqueID: deviceUniqueID,
                    resolution: resolution,
                    warmupFrames: warmupFrames,
                    timeout: timeout
                )
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Continuous session

    /// Desired continuous-session state. Fire-and-forget: reconciles asynchronously
    /// on `sessionQueue` (start, stop, or rebuild for a device or resolution change).
    /// Idempotent.
    func setContinuousCapture(enabled: Bool, deviceUniqueID: String?, resolution: CaptureResolution?) {
        sessionQueue.async {
            self.desiredContinuous = enabled
            self.desiredDeviceID = deviceUniqueID
            self.desiredResolution = resolution
            self.reconcileContinuousSession()
        }
    }

    /// Brings the continuous session in line with what is desired: tears it down when
    /// disabled (or unauthorized), rebuilds it when dead, built for another resolution,
    /// or no longer on the device selection would pick now (a settings change, or a
    /// preferred camera reconnecting after a fallback), no-ops when it is already
    /// healthy. Runs on `sessionQueue`.
    private func reconcileContinuousSession() {
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
            let activeID = (session.inputs.first as? AVCaptureDeviceInput)?.device.uniqueID
            if session.isRunning,
               activeID == Self.resolveDevice(uniqueID: desiredDeviceID)?.uniqueID,
               continuousResolution == desiredResolution {
                return
            }
            teardownContinuousSession()
        }
        startContinuousSession(deviceUniqueID: desiredDeviceID, resolution: desiredResolution)
    }

    private func startContinuousSession(deviceUniqueID: String?, resolution: CaptureResolution?) {
        guard let device = Self.resolveDevice(uniqueID: deviceUniqueID) else {
            Log.camera.error("no usable camera device for continuous session")
            return
        }
        let customFormat = Self.resolvedFormat(on: device, for: resolution)
        let latch = LiveFrameLatch()
        let session: AVCaptureSession
        do {
            session = try Self.makeConfiguredSession(
                device: device,
                customFormat: customFormat,
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
        Self.startRunning(session, on: device, pinning: customFormat)
        continuousSession = session
        continuousLatch = latch
        continuousResolution = resolution
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
        continuousResolution = nil
        Log.camera.notice("continuous session stopped")
    }

    // MARK: - Capture

    /// Runs on `sessionQueue`. Prefers the continuous session when it is (or can be)
    /// running; otherwise falls back to the one-shot start/stop capture.
    private func capture(
        deviceUniqueID: String?,
        resolution: CaptureResolution?,
        warmupFrames: Int,
        timeout: TimeInterval
    ) -> Result<Frame, Error> {
        desiredDeviceID = deviceUniqueID
        desiredResolution = resolution
        let sessionBefore = continuousSession
        reconcileContinuousSession()
        if let latch = continuousLatch, continuousSession?.isRunning == true {
            // A session that survived reconcile is warm and delivers the next frame
            // in ~one frame interval; one reconcile just (re)built — cold start or
            // device/resolution rebuild — gets the full budget for startup and
            // warmup, as in a one-shot capture.
            let wasWarm = continuousSession === sessionBefore
            let latchTimeout = wasWarm ? min(2, timeout) : timeout
            if let buffer = latch.nextFrame(warmupFrames: warmupFrames, timeout: latchTimeout) {
                Log.camera.info("captured live \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) frame from continuous session")
                return .success(Frame(pixelBuffer: buffer))
            }
            Log.camera.error("continuous session produced no frame; falling back to one-shot capture")
            teardownContinuousSession()
        }
        return Self.blockingCapture(
            deviceUniqueID: deviceUniqueID,
            resolution: resolution,
            warmupFrames: warmupFrames,
            timeout: timeout
        )
    }

    /// Blocking by design: the queue's thread parks on a semaphore until the sink
    /// has seen enough frames or the timeout expires.
    private static func blockingCapture(
        deviceUniqueID: String?,
        resolution: CaptureResolution?,
        warmupFrames: Int,
        timeout: TimeInterval
    ) -> Result<Frame, Error> {
        guard let device = resolveDevice(uniqueID: deviceUniqueID) else {
            Log.camera.error("no usable camera device found")
            return .failure(CameraError.deviceUnavailable)
        }

        let customFormat = resolvedFormat(on: device, for: resolution)
        let sink = FrameSink(warmupFrames: warmupFrames)
        let session: AVCaptureSession
        do {
            session = try makeConfiguredSession(
                device: device,
                customFormat: customFormat,
                delegate: sink,
                queueLabel: "com.github.martintreurnicht.sentinel.camera.frames"
            )
        } catch {
            Log.camera.error("capture configuration failed: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }

        Log.camera.info("capturing one frame from \(device.localizedName, privacy: .public)")
        startRunning(session, on: device, pinning: customFormat)
        defer { session.stopRunning() }

        guard sink.semaphore.wait(timeout: .now() + timeout) == .success, let buffer = sink.capturedBuffer else {
            Log.camera.error("timed out waiting for a frame from \(device.localizedName, privacy: .public)")
            return .failure(CameraError.timeout)
        }
        Log.camera.info("captured \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) frame from \(device.localizedName, privacy: .public)")
        return .success(Frame(pixelBuffer: buffer))
    }

    /// Shared configuration for both capture paths (discard late frames, bi-planar
    /// YCbCr) so they cannot drift apart. Without a custom format the session uses
    /// the default VGA preset; with one, the preset is left alone so the pinned
    /// `activeFormat` decides the resolution.
    private static func makeConfiguredSession(
        device: AVCaptureDevice,
        customFormat: AVCaptureDevice.Format?,
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        queueLabel: String
    ) throws -> AVCaptureSession {
        let session = AVCaptureSession()
        if customFormat == nil, session.canSetSessionPreset(.vga640x480) {
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

    /// The device format to pin for the configured resolution, if any; logs when a
    /// requested resolution isn't offered and capture falls back to the 640×480 default.
    private static func resolvedFormat(on device: AVCaptureDevice, for resolution: CaptureResolution?) -> AVCaptureDevice.Format? {
        guard let resolution else { return nil }
        if let format = bestFormat(on: device, matching: resolution) {
            return format
        }
        Log.camera.warning("resolution \(resolution.storageString, privacy: .public) not offered by \(device.localizedName, privacy: .public); using default 640x480")
        return nil
    }

    /// Starts the session, pinning `customFormat` as the device's active format if set.
    /// macOS has no .inputPriority preset (unlike iOS), so on startRunning() the
    /// session reconfigures the device to match its own preset — wiping activeFormat
    /// unless the configuration lock is held until it's running.
    private static func startRunning(
        _ session: AVCaptureSession,
        on device: AVCaptureDevice,
        pinning customFormat: AVCaptureDevice.Format?
    ) {
        guard let customFormat else {
            session.startRunning()
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = customFormat
            session.startRunning()
            device.unlockForConfiguration()
        } catch {
            Log.camera.warning("could not lock \(device.localizedName, privacy: .public) to set resolution; using session default: \(String(describing: error), privacy: .public)")
            session.startRunning()
        }
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

    /// Distinct dimensions offered by the camera the given configuration resolves to
    /// (nil/empty ID = system preferred), smallest first. Empty if no camera is usable.
    static func supportedResolutions(deviceUniqueID: String?) -> [CaptureResolution] {
        guard let device = resolveDevice(uniqueID: deviceUniqueID) else { return [] }
        return resolutions(fromDimensions: device.formats.map { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (Int(dims.width), Int(dims.height))
        })
    }

    /// Dedupes raw format dimensions and sorts ascending by area, then width.
    static func resolutions(fromDimensions dims: [(width: Int, height: Int)]) -> [CaptureResolution] {
        var seen = Set<CaptureResolution>()
        var result: [CaptureResolution] = []
        for dim in dims where dim.width > 0 && dim.height > 0 {
            let res = CaptureResolution(width: dim.width, height: dim.height)
            if seen.insert(res).inserted {
                result.append(res)
            }
        }
        return result.sorted { ($0.width * $0.height, $0.width) < ($1.width * $1.height, $1.width) }
    }

    struct FormatCandidate {
        let resolution: CaptureResolution
        let maxFrameRate: Double
    }

    /// Index of the candidate matching `target` with the highest max frame rate
    /// (first wins ties), or nil when none match.
    static func bestMatch(in candidates: [FormatCandidate], target: CaptureResolution) -> Int? {
        var best: Int?
        for index in candidates.indices where candidates[index].resolution == target {
            if let current = best, candidates[index].maxFrameRate <= candidates[current].maxFrameRate { continue }
            best = index
        }
        return best
    }

    /// The device format to pin for `resolution`; among same-dimension formats prefers
    /// the highest frame rate so a low-fps variant (common for 4K) isn't picked.
    private static func bestFormat(on device: AVCaptureDevice, matching resolution: CaptureResolution) -> AVCaptureDevice.Format? {
        let candidates = device.formats.map { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return FormatCandidate(
                resolution: CaptureResolution(width: Int(dims.width), height: Int(dims.height)),
                maxFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            )
        }
        return bestMatch(in: candidates, target: resolution).map { device.formats[$0] }
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

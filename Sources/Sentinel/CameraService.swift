@preconcurrency import AVFoundation
import Foundation

/// Grabs a single frame from the webcam, starting and stopping the capture session
/// each time so the camera (and its indicator light) is only active during a check.
final class CameraService: Sendable {
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

    func captureFrame(deviceUniqueID: String?, warmupFrames: Int, timeout: TimeInterval) async throws -> Frame {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let result = Self.blockingCapture(
                    deviceUniqueID: deviceUniqueID,
                    warmupFrames: warmupFrames,
                    timeout: timeout
                )
                continuation.resume(with: result)
            }
        }
    }

    /// Runs entirely on `sessionQueue`. Blocking by design: the queue's thread parks on a
    /// semaphore until the sink has seen enough frames or the timeout expires.
    private static func blockingCapture(
        deviceUniqueID: String?,
        warmupFrames: Int,
        timeout: TimeInterval
    ) -> Result<Frame, Error> {
        guard let device = resolveDevice(uniqueID: deviceUniqueID) else {
            Log.camera.error("no usable camera device found")
            return .failure(CameraError.deviceUnavailable)
        }

        let session = AVCaptureSession()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        let sink = FrameSink(warmupFrames: warmupFrames)
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.configurationFailed }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            let frameQueue = DispatchQueue(label: "com.github.martintreurnicht.sentinel.camera.frames")
            output.setSampleBufferDelegate(sink, queue: frameQueue)
            guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
            session.addOutput(output)
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

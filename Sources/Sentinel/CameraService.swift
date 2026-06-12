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

    func captureFrame(deviceUniqueID: String?, resolution: CaptureResolution?, warmupFrames: Int, timeout: TimeInterval) async throws -> Frame {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let result = Self.blockingCapture(
                    deviceUniqueID: deviceUniqueID,
                    resolution: resolution,
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
        resolution: CaptureResolution?,
        warmupFrames: Int,
        timeout: TimeInterval
    ) -> Result<Frame, Error> {
        guard let device = resolveDevice(uniqueID: deviceUniqueID) else {
            Log.camera.error("no usable camera device found")
            return .failure(CameraError.deviceUnavailable)
        }

        let session = AVCaptureSession()
        let customFormat = resolution.flatMap { bestFormat(on: device, matching: $0) }
        if customFormat == nil {
            if let resolution {
                Log.camera.warning("resolution \(resolution.storageString, privacy: .public) not offered by \(device.localizedName, privacy: .public); using default 640x480")
            }
            if session.canSetSessionPreset(.vga640x480) {
                session.sessionPreset = .vga640x480
            }
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
            output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "com.github.martintreurnicht.sentinel.camera.frames"))
            guard session.canAddOutput(output) else { throw CameraError.configurationFailed }
            session.addOutput(output)
        } catch {
            Log.camera.error("capture configuration failed: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }

        Log.camera.info("capturing one frame from \(device.localizedName, privacy: .public)")
        if let customFormat {
            // macOS has no .inputPriority preset (unlike iOS), so on startRunning()
            // the session reconfigures the device to match its own preset — wiping
            // activeFormat unless the configuration lock is held until it's running.
            do {
                try device.lockForConfiguration()
                device.activeFormat = customFormat
                session.startRunning()
                device.unlockForConfiguration()
            } catch {
                Log.camera.warning("could not lock \(device.localizedName, privacy: .public) to set resolution; using session default: \(String(describing: error), privacy: .public)")
                session.startRunning()
            }
        } else {
            session.startRunning()
        }
        defer { session.stopRunning() }

        guard sink.semaphore.wait(timeout: .now() + timeout) == .success, let buffer = sink.capturedBuffer else {
            Log.camera.error("timed out waiting for a frame from \(device.localizedName, privacy: .public)")
            return .failure(CameraError.timeout)
        }
        Log.camera.info("captured \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) frame from \(device.localizedName, privacy: .public)")
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

@preconcurrency import AVFoundation

/// Composes camera capture + presence detection into the single async check the monitor runs.
struct CameraPresenceChecker: PresenceChecking {
    let camera: CameraService
    let detector: PresenceDetector
    let settings: Settings

    func checkPresence() async -> CheckResult {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                return .inconclusive(.cameraPermissionDenied)
            }
        default:
            return .inconclusive(.cameraPermissionDenied)
        }

        do {
            let frame = try await camera.captureFrame(
                deviceUniqueID: settings.cameraUniqueID.isEmpty ? nil : settings.cameraUniqueID,
                resolution: settings.cameraResolution,
                warmupFrames: settings.warmupFrames,
                timeout: settings.checkTimeout
            )
            switch try detector.analyze(frame, mode: settings.detectionMode) {
            case .present: return .present
            case .absent: return .absent
            case .tooDark: return .inconclusive(.tooDark)
            }
        } catch CameraService.CameraError.deviceUnavailable {
            return .inconclusive(.cameraUnavailable)
        } catch CameraService.CameraError.timeout {
            return .inconclusive(.captureFailed("timed out"))
        } catch {
            return .inconclusive(.captureFailed(String(describing: error)))
        }
    }
}

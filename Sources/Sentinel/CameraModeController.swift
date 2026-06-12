import Foundation

/// Camera-layer interface the mode controller drives. Implemented by CameraService;
/// mocked in tests.
protocol ContinuousCaptureControlling: Sendable {
    func setContinuousCapture(enabled: Bool, deviceUniqueID: String?)
}

extension CameraService: ContinuousCaptureControlling {}

/// Decides whether the continuous camera session should run — the user's
/// "Keep Camera On" mode, gated by AC power (for `.onACPower`) and by whether
/// monitoring is actively polling — and pushes every change into the camera.
///
/// Settings and power source are read live on each evaluation, so a menu change
/// or an AC↔battery flip only needs a `refresh()` to take effect.
final class CameraModeController: CameraSessionControlling, @unchecked Sendable {
    private let camera: any ContinuousCaptureControlling
    private let settings: Settings
    private let powerSource: any PowerSourceMonitoring
    private let lock = NSLock()
    private var monitoringActive = false

    init(camera: any ContinuousCaptureControlling, settings: Settings, powerSource: any PowerSourceMonitoring) {
        self.camera = camera
        self.settings = settings
        self.powerSource = powerSource
    }

    func setMonitoringActive(_ active: Bool) {
        lock.withLock {
            monitoringActive = active
            applyLocked()
        }
    }

    /// Re-evaluate after a settings change (mode or camera device) or a power flip.
    func refresh() {
        lock.withLock { applyLocked() }
    }

    /// Must run with `lock` held, covering the push into the camera: evaluations
    /// must reach the camera's queue in the order their state was read, or a
    /// refresh racing a lock-screen transition could enqueue a stale "enabled"
    /// last and leave the session running while the screen is locked. Holding the
    /// lock is safe — `setContinuousCapture` only enqueues async work and never
    /// calls back into this class.
    private func applyLocked() {
        let enabled = monitoringActive && Self.wantsContinuousSession(
            mode: settings.cameraSessionMode,
            isOnACPower: powerSource.isOnACPower
        )
        camera.setContinuousCapture(
            enabled: enabled,
            deviceUniqueID: settings.cameraUniqueID.isEmpty ? nil : settings.cameraUniqueID
        )
    }

    /// Pure policy, ignoring monitor activity: should the session run in this mode?
    static func wantsContinuousSession(mode: CameraSessionMode, isOnACPower: Bool) -> Bool {
        switch mode {
        case .onlyWhileChecking: false
        case .always: true
        case .onACPower: isOnACPower
        }
    }
}

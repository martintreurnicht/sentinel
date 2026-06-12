import Foundation

/// Why a presence check could not produce a face / no-face verdict, or why locking failed.
/// Inconclusive checks always fail open: Sentinel must never lock you out because the camera broke.
enum MonitorError: Equatable, Sendable {
    case cameraPermissionDenied
    case cameraUnavailable
    case tooDark
    case captureFailed(String)
    case lockFailed

    var displayText: String {
        switch self {
        case .cameraPermissionDenied: "Camera permission denied"
        case .cameraUnavailable: "No camera available"
        case .tooDark: "Image too dark to judge presence"
        case .captureFailed(let detail): "Capture failed (\(detail))"
        case .lockFailed: "Could not lock the screen"
        }
    }
}

enum PresenceState: Equatable, Sendable, CustomStringConvertible {
    case initializing
    case present
    /// A check saw no face; one re-check happens after the grace period before
    /// locking (or standing down, when locking is disabled).
    case graceAbsence
    /// Absence confirmed with lock-on-absence disabled: no assertion is held, the
    /// display may idle-sleep, and polling continues at `pollInterval` to catch
    /// the user's return (no unlock event exists in this mode).
    case absent
    case locked
    /// Manually paused. `until` is nil for "until resumed".
    case paused(until: Date?)
    case error(MonitorError)

    /// Whether presence checks may run in this state.
    var isActivelyPolling: Bool {
        switch self {
        case .locked, .paused: false
        case .initializing, .present, .graceAbsence, .absent, .error: true
        }
    }

    var description: String {
        switch self {
        case .initializing: "initializing"
        case .present: "present"
        case .graceAbsence: "graceAbsence"
        case .absent: "absent"
        case .locked: "locked"
        case .paused(let until): "paused(until: \(until.map { "\($0)" } ?? "resumed"))"
        case .error(let e): "error(\(e.displayText))"
        }
    }
}

enum CheckResult: Equatable, Sendable {
    case face
    case noFace
    case inconclusive(MonitorError)
}

/// Externally observed session/system transitions, forwarded into the monitor.
enum SessionEvent: Equatable, Sendable {
    case screenLocked
    case screenUnlocked
    case willSleep
    case didWake
    case sessionResignedActive
    case sessionBecameActive
}

struct MonitorSnapshot: Equatable, Sendable {
    var state: PresenceState
    var lastCheckAt: Date?
}

// MARK: - Injected dependencies (mocked in tests)

protocol PresenceChecking: Sendable {
    /// Performs one webcam presence check. Never throws — failures map to `.inconclusive`.
    func checkPresence() async -> CheckResult
}

protocol ScreenLocking: Sendable {
    /// Attempts to lock the screen (including fallbacks) and returns whether the
    /// lock was confirmed to have engaged.
    func lock() async -> Bool
}

protocol PowerAsserting: Sendable {
    /// Hold (true) or release (false) the "prevent idle display sleep" assertion. Idempotent.
    func setPresent(_ present: Bool)
    /// Reset the system's user-idle timers (screensaver / lock-after-inactivity).
    func declareUserActivity()
}

protocol CameraSessionControlling: Sendable {
    /// True while presence checks may run (any actively-polling state); false when
    /// locked, paused, sleeping, or fast-user-switched out. Idempotent — the monitor
    /// calls this on every transition.
    func setMonitoringActive(_ active: Bool)
}

protocol MonitorConfig: Sendable {
    var pollInterval: Duration { get }
    var absenceGrace: Duration { get }
    /// Whether confirmed absence locks the screen (true) or merely releases the
    /// keep-awake assertion and keeps watching for the user's return (false).
    var locksOnAbsence: Bool { get }
}

protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousSleeper: Sleeper {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration, tolerance: .seconds(2))
    }
}

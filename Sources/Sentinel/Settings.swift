import Foundation

/// UserDefaults-backed configuration. All keys are documented in the README and
/// can be set from the command line, e.g.:
///   defaults write com.github.martintreurnicht.sentinel pollInterval -float 15
struct Settings: @unchecked Sendable, MonitorConfig {
    enum Key {
        static let pollInterval = "pollInterval"
        static let absenceGracePeriod = "absenceGracePeriod"
        static let lockOnAbsence = "lockOnAbsence"
        static let cameraUniqueID = "cameraUniqueID"
        static let warmupFrames = "warmupFrames"
        static let checkTimeout = "checkTimeout"
        static let lockMethod = "lockMethod"
        static let cameraKeepOn = "cameraKeepOn"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func registerDefaults(on defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.pollInterval: 30.0,
            Key.absenceGracePeriod: 30.0,
            Key.lockOnAbsence: true,
            Key.cameraUniqueID: "",
            Key.warmupFrames: 8,
            Key.checkTimeout: 10.0,
            Key.lockMethod: LockMethod.auto.rawValue,
            Key.cameraKeepOn: CameraSessionMode.onlyWhileChecking.rawValue,
        ])
    }

    /// Seconds between presence checks while present (or recovering from errors). Minimum 5.
    var pollIntervalSeconds: TimeInterval {
        get { max(5, defaults.double(forKey: Key.pollInterval)) }
        nonmutating set { defaults.set(newValue, forKey: Key.pollInterval) }
    }

    /// Seconds to wait after a missed check before the final re-check that locks.
    /// 0 means lock immediately on the first missed check.
    var absenceGraceSeconds: TimeInterval {
        get { max(0, defaults.double(forKey: Key.absenceGracePeriod)) }
        nonmutating set { defaults.set(newValue, forKey: Key.absenceGracePeriod) }
    }

    /// When false, Sentinel never locks the screen; it only holds the display-wake
    /// assertion while present and releases it on confirmed absence.
    var locksOnAbsence: Bool {
        get { defaults.bool(forKey: Key.lockOnAbsence) }
        nonmutating set { defaults.set(newValue, forKey: Key.lockOnAbsence) }
    }

    /// Empty string means automatic (system preferred camera).
    var cameraUniqueID: String {
        get { defaults.string(forKey: Key.cameraUniqueID) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: Key.cameraUniqueID) }
    }

    /// Frames to discard after starting the camera so auto-exposure settles
    /// (dark warmup frames must not read as "absent").
    var warmupFrames: Int {
        get { min(30, max(1, defaults.integer(forKey: Key.warmupFrames))) }
        nonmutating set { defaults.set(newValue, forKey: Key.warmupFrames) }
    }

    /// Seconds allowed for a whole capture (camera start + warmup + one frame).
    var checkTimeout: TimeInterval {
        get { max(2, defaults.double(forKey: Key.checkTimeout)) }
        nonmutating set { defaults.set(newValue, forKey: Key.checkTimeout) }
    }

    var lockMethod: LockMethod {
        get { LockMethod(rawValue: defaults.string(forKey: Key.lockMethod) ?? "") ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.lockMethod) }
    }

    var cameraSessionMode: CameraSessionMode {
        get { CameraSessionMode(rawValue: defaults.string(forKey: Key.cameraKeepOn) ?? "") ?? .onlyWhileChecking }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.cameraKeepOn) }
    }

    // MARK: MonitorConfig

    var pollInterval: Duration { .seconds(pollIntervalSeconds) }
    var absenceGrace: Duration { .seconds(absenceGraceSeconds) }
}

/// When the camera capture session runs, i.e. when the camera indicator light is on.
enum CameraSessionMode: String, Sendable {
    /// Start and stop the camera for each check; the indicator light flashes. Default.
    case onlyWhileChecking
    /// Keep the session running while monitoring is active: steady light, near-instant checks.
    case always
    /// Continuous on AC power, per-check on battery. Desktops with no battery count as AC.
    case onACPower
}

enum LockMethod: String, Sendable {
    /// Try the private login.framework API, fall back to `pmset displaysleepnow`.
    case auto
    /// Only the private API.
    case privateAPI = "private"
    /// Only `pmset displaysleepnow` (requires "require password immediately after sleep").
    case pmset
}

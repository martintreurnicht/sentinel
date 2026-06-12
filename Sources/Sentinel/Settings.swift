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
        static let cameraResolution = "cameraResolution"
        static let warmupFrames = "warmupFrames"
        static let checkTimeout = "checkTimeout"
        static let lockMethod = "lockMethod"
        static let detectionMode = "detectionMode"
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
            Key.cameraResolution: "",
            Key.warmupFrames: 8,
            Key.checkTimeout: 10.0,
            Key.lockMethod: LockMethod.auto.rawValue,
            Key.detectionMode: DetectionMode.person.rawValue,
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

    /// Desired capture resolution, stored as "1920x1080". Nil (stored "") means the
    /// default 640×480. Capture falls back to the default when the active camera
    /// doesn't offer the stored resolution.
    var cameraResolution: CaptureResolution? {
        get { CaptureResolution(string: defaults.string(forKey: Key.cameraResolution) ?? "") }
        nonmutating set { defaults.set(newValue?.storageString ?? "", forKey: Key.cameraResolution) }
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

    /// How a frame is judged: `.person` counts a face or any person visible in the frame
    /// (default — looking away from the camera still counts as present); `.face` is
    /// strict face-only.
    var detectionMode: DetectionMode {
        get { DetectionMode(rawValue: defaults.string(forKey: Key.detectionMode) ?? "") ?? .person }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.detectionMode) }
    }

    // MARK: MonitorConfig

    var pollInterval: Duration { .seconds(pollIntervalSeconds) }
    var absenceGrace: Duration { .seconds(absenceGraceSeconds) }
}

/// What counts as "someone is here" in a captured frame.
enum DetectionMode: String, Sendable {
    /// A detected face or a person visible in the frame counts as present.
    case person
    /// Only a detected face counts as present (the original strict behavior).
    case face
}

enum LockMethod: String, Sendable {
    /// Try the private login.framework API, fall back to `pmset displaysleepnow`.
    case auto
    /// Only the private API.
    case privateAPI = "private"
    /// Only `pmset displaysleepnow` (requires "require password immediately after sleep").
    case pmset
}

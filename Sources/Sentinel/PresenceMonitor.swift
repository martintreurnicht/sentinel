import Foundation

/// The state machine at the heart of Sentinel.
///
/// Invariants:
/// - The display-sleep assertion is held only in `.present` and `.graceAbsence`
///   (kept during grace so the display cannot sleep while the final re-check is pending).
/// - The screen lock is invoked from exactly one place (`performLock`), after the
///   assertion has been released.
/// - Only a successfully analyzed, adequately lit frame with zero faces counts toward
///   locking; every failure mode is `.inconclusive` and fails open into `.error`.
actor PresenceMonitor {
    private let checker: any PresenceChecking
    private let locker: any ScreenLocking
    private let power: any PowerAsserting
    private let config: any MonitorConfig
    private let sleeper: any Sleeper
    private let isScreenLocked: @Sendable () -> Bool

    private(set) var state: PresenceState = .initializing
    private(set) var lastCheckAt: Date?

    private var pollTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    /// Bumped on every externally driven transition (lock/unlock/sleep/pause/resume).
    /// In-flight checks and lock attempts started under an older epoch discard their results.
    private var epoch = 0
    private var checking = false
    private var onSnapshot: (@Sendable (MonitorSnapshot) -> Void)?

    init(
        checker: any PresenceChecking,
        locker: any ScreenLocking,
        power: any PowerAsserting,
        config: any MonitorConfig,
        sleeper: any Sleeper = ContinuousSleeper(),
        isScreenLocked: @escaping @Sendable () -> Bool
    ) {
        self.checker = checker
        self.locker = locker
        self.power = power
        self.config = config
        self.sleeper = sleeper
        self.isScreenLocked = isScreenLocked
    }

    func setSnapshotHandler(_ handler: @escaping @Sendable (MonitorSnapshot) -> Void) {
        onSnapshot = handler
        publish()
    }

    func start() {
        if isScreenLocked() {
            Log.monitor.notice("starting while screen is locked; waiting for unlock")
            state = .locked
        } else {
            Log.monitor.notice("starting; scheduling first check")
            state = .initializing
            scheduleCheck(after: .zero)
        }
        publish()
    }

    func checkNow() {
        guard state.isActivelyPolling else { return }
        scheduleCheck(after: .zero)
    }

    /// `seconds == nil` pauses until explicitly resumed.
    func pause(for seconds: TimeInterval?) {
        epoch += 1
        pollTask?.cancel()
        resumeTask?.cancel()
        resumeTask = nil
        power.setPresent(false)
        if let seconds {
            state = .paused(until: Date().addingTimeInterval(seconds))
            resumeTask = Task { [weak self, sleeper] in
                try? await sleeper.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.resume()
            }
        } else {
            state = .paused(until: nil)
        }
        Log.monitor.notice("paused (\(seconds.map { "\($0)s" } ?? "until resumed", privacy: .public))")
        publish()
    }

    func resume() {
        guard case .paused = state else { return }
        epoch += 1
        resumeTask?.cancel()
        resumeTask = nil
        Log.monitor.notice("resumed; checking now")
        state = .initializing
        publish()
        scheduleCheck(after: .zero)
    }

    /// Re-reads the poll interval for the next scheduled check.
    func settingsChanged() {
        switch state {
        case .present, .error:
            scheduleCheck(after: config.pollInterval)
        default:
            break
        }
    }

    func handleSessionEvent(_ event: SessionEvent) {
        // A manual pause always wins: lock/unlock/sleep cycles do not resume monitoring.
        if case .paused = state { return }

        switch event {
        case .screenLocked, .willSleep, .sessionResignedActive:
            epoch += 1
            pollTask?.cancel()
            power.setPresent(false)
            if state != .locked {
                Log.monitor.notice("session event \(String(describing: event), privacy: .public) -> locked; polling suspended")
            }
            state = .locked
            publish()
        case .screenUnlocked:
            guard state == .locked else { return }
            // The user just authenticated — that is proof of presence. No startle-check.
            epoch += 1
            power.setPresent(true)
            state = .present
            Log.monitor.notice("screen unlocked -> present; next check after full interval")
            publish()
            scheduleCheck(after: config.pollInterval)
        case .didWake, .sessionBecameActive:
            guard state == .locked else { return }
            // Woke without a lock engaging (e.g. password delay setting): start checking again.
            guard !isScreenLocked() else { return }
            epoch += 1
            state = .initializing
            Log.monitor.notice("woke with screen unlocked; checking now")
            publish()
            scheduleCheck(after: .zero)
        }
    }

    // MARK: - Internals

    private func scheduleCheck(after delay: Duration) {
        pollTask?.cancel()
        let expectedEpoch = epoch
        pollTask = Task { [weak self, sleeper] in
            if delay > .zero {
                do { try await sleeper.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.performCheck(expectedEpoch: expectedEpoch)
        }
    }

    private func performCheck(expectedEpoch: Int) async {
        guard epoch == expectedEpoch, !checking, state.isActivelyPolling else { return }
        checking = true
        defer { checking = false }

        let result = await checker.checkPresence()

        guard epoch == expectedEpoch, state.isActivelyPolling else { return }
        await applyCheckResult(result)
    }

    /// Internal (not private) so the state machine is directly drivable from unit tests.
    func applyCheckResult(_ result: CheckResult) async {
        guard state.isActivelyPolling else { return }
        lastCheckAt = Date()

        switch result {
        case .face:
            power.setPresent(true)
            power.declareUserActivity()
            if state != .present {
                Log.monitor.notice("face detected -> present")
            }
            state = .present
            scheduleCheck(after: config.pollInterval)
        case .noFace:
            if case .graceAbsence = state {
                Log.monitor.notice("still no face after grace period -> locking")
                await performLock()
            } else if config.absenceGrace <= .zero {
                Log.monitor.notice("no face and no grace period -> locking")
                await performLock()
            } else {
                Log.monitor.notice("no face -> grace period before locking")
                power.setPresent(true)
                state = .graceAbsence
                scheduleCheck(after: config.absenceGrace)
            }
        case .inconclusive(let reason):
            power.setPresent(false)
            state = .error(reason)
            Log.monitor.warning("check inconclusive (\(reason.displayText, privacy: .public)) -> failing open, no lock")
            scheduleCheck(after: config.pollInterval)
        }
        publish()
    }

    private func performLock() async {
        power.setPresent(false)
        let expectedEpoch = epoch
        let confirmed = await locker.lock()
        // The screenIsLocked notification may have raced us here; if so the session
        // event handler already moved us to .locked under a newer epoch.
        guard epoch == expectedEpoch else { return }
        if confirmed {
            pollTask?.cancel()
            state = .locked
            Log.monitor.notice("screen lock confirmed; polling suspended")
        } else {
            state = .error(.lockFailed)
            Log.monitor.error("screen lock could not be confirmed; failing open")
            scheduleCheck(after: config.pollInterval)
        }
        publish()
    }

    private func publish() {
        onSnapshot?(MonitorSnapshot(state: state, lastCheckAt: lastCheckAt))
    }
}

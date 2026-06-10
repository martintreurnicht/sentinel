import Foundation
import Testing
@testable import Sentinel

// MARK: - Mocks

/// Default mode suspends forever so scheduled background checks never mutate state
/// underneath a test; transition tests drive `applyCheckResult` directly.
actor MockChecker: PresenceChecking {
    enum Mode {
        case result(CheckResult)
        case suspend
    }

    private var mode: Mode
    private(set) var calls = 0

    init(mode: Mode = .suspend) {
        self.mode = mode
    }

    func set(mode: Mode) {
        self.mode = mode
    }

    func checkPresence() async -> CheckResult {
        calls += 1
        switch mode {
        case .result(let result):
            return result
        case .suspend:
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return .inconclusive(.captureFailed("suspended"))
        }
    }
}

actor MockLocker: ScreenLocking {
    private var succeeds: Bool
    private(set) var calls = 0

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func set(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func lock() async -> Bool {
        calls += 1
        return succeeds
    }
}

final class MockPower: PowerAsserting, @unchecked Sendable {
    private let lock = NSLock()
    private var presentCalls: [Bool] = []
    private var declareCalls = 0

    func setPresent(_ present: Bool) {
        lock.withLock { presentCalls.append(present) }
    }

    func declareUserActivity() {
        lock.withLock { declareCalls += 1 }
    }

    var setPresentLog: [Bool] {
        lock.withLock { presentCalls }
    }

    var declareCount: Int {
        lock.withLock { declareCalls }
    }
}

/// Suspends forever: scheduled polls and auto-resume timers never fire during tests.
struct ForeverSleeper: Sleeper {
    func sleep(for duration: Duration) async throws {
        await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    }
}

struct TestConfig: MonitorConfig {
    var pollInterval: Duration = .seconds(30)
    var absenceGrace: Duration = .seconds(30)
}

final class LockStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false

    var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }
}

struct Harness {
    let monitor: PresenceMonitor
    let checker: MockChecker
    let locker: MockLocker
    let power: MockPower
    let lockState: LockStateBox

    init(config: TestConfig = TestConfig(), checkerMode: MockChecker.Mode = .suspend) {
        let checker = MockChecker(mode: checkerMode)
        let locker = MockLocker()
        let power = MockPower()
        let lockState = LockStateBox()
        self.checker = checker
        self.locker = locker
        self.power = power
        self.lockState = lockState
        self.monitor = PresenceMonitor(
            checker: checker,
            locker: locker,
            power: power,
            config: config,
            sleeper: ForeverSleeper(),
            isScreenLocked: { lockState.isLocked }
        )
    }
}

func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

// MARK: - Check result transitions

@Test func faceWhileInitializingBecomesPresent() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    #expect(await h.monitor.state == .present)
    #expect(h.power.setPresentLog == [true])
    #expect(h.power.declareCount == 1)
    #expect(await h.locker.calls == 0)
}

@Test func noFaceEntersGraceAndHoldsAssertion() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    await h.monitor.applyCheckResult(.noFace)
    #expect(await h.monitor.state == .graceAbsence)
    #expect(h.power.setPresentLog.last == true)
    #expect(await h.locker.calls == 0)
}

@Test func faceDuringGraceReturnsToPresent() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.noFace)
    #expect(await h.monitor.state == .graceAbsence)
    await h.monitor.applyCheckResult(.face)
    #expect(await h.monitor.state == .present)
    #expect(await h.locker.calls == 0)
}

@Test func noFaceAfterGraceLocks() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.noFace)
    await h.monitor.applyCheckResult(.noFace)
    #expect(await h.locker.calls == 1)
    #expect(await h.monitor.state == .locked)
    #expect(h.power.setPresentLog.last == false)
}

@Test func zeroGraceLocksOnFirstMiss() async {
    let h = Harness(config: TestConfig(absenceGrace: .zero))
    await h.monitor.applyCheckResult(.noFace)
    #expect(await h.locker.calls == 1)
    #expect(await h.monitor.state == .locked)
}

@Test func lockFailureFailsOpenToError() async {
    let h = Harness(config: TestConfig(absenceGrace: .zero))
    await h.locker.set(succeeds: false)
    await h.monitor.applyCheckResult(.noFace)
    #expect(await h.monitor.state == .error(.lockFailed))
}

@Test func inconclusiveFailsOpenWithoutLocking() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    await h.monitor.applyCheckResult(.inconclusive(.tooDark))
    #expect(await h.monitor.state == .error(.tooDark))
    #expect(h.power.setPresentLog.last == false)
    #expect(await h.locker.calls == 0)
}

@Test func inconclusiveDuringGraceDoesNotLock() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.noFace)
    await h.monitor.applyCheckResult(.inconclusive(.cameraUnavailable))
    #expect(await h.monitor.state == .error(.cameraUnavailable))
    #expect(await h.locker.calls == 0)
}

@Test func faceRecoversFromError() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.inconclusive(.cameraUnavailable))
    await h.monitor.applyCheckResult(.face)
    #expect(await h.monitor.state == .present)
    #expect(h.power.setPresentLog.last == true)
}

@Test func checkResultsIgnoredWhileLockedOrPaused() async {
    let h = Harness()
    await h.monitor.handleSessionEvent(.screenLocked)
    await h.monitor.applyCheckResult(.face)
    #expect(await h.monitor.state == .locked)

    let paused = Harness()
    await paused.monitor.pause(for: nil)
    await paused.monitor.applyCheckResult(.noFace)
    #expect(await paused.monitor.state == .paused(until: nil))
    #expect(await paused.locker.calls == 0)
}

// MARK: - Session events

@Test func manualLockSuspendsMonitoring() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    await h.monitor.handleSessionEvent(.screenLocked)
    #expect(await h.monitor.state == .locked)
    #expect(h.power.setPresentLog.last == false)
}

@Test func unlockProvesPresence() async {
    let h = Harness()
    await h.monitor.handleSessionEvent(.screenLocked)
    await h.monitor.handleSessionEvent(.screenUnlocked)
    #expect(await h.monitor.state == .present)
    #expect(h.power.setPresentLog.last == true)
}

@Test func spuriousUnlockWhilePresentIsIgnored() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    await h.monitor.handleSessionEvent(.screenUnlocked)
    #expect(await h.monitor.state == .present)
}

@Test func sleepSuspendsAndWakeUnlockedResumesChecking() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    await h.monitor.handleSessionEvent(.willSleep)
    #expect(await h.monitor.state == .locked)

    h.lockState.isLocked = false
    await h.monitor.handleSessionEvent(.didWake)
    #expect(await h.monitor.state == .initializing)
    #expect(await eventually { await h.checker.calls >= 1 })
}

@Test func wakeWhileStillLockedStaysLocked() async {
    let h = Harness()
    await h.monitor.handleSessionEvent(.willSleep)
    h.lockState.isLocked = true
    await h.monitor.handleSessionEvent(.didWake)
    #expect(await h.monitor.state == .locked)
}

@Test func startWhileScreenLockedWaitsForUnlock() async {
    let h = Harness()
    h.lockState.isLocked = true
    await h.monitor.start()
    #expect(await h.monitor.state == .locked)
    #expect(await h.checker.calls == 0)
}

@Test func startUnlockedSchedulesImmediateCheck() async {
    let h = Harness()
    await h.monitor.start()
    #expect(await eventually { await h.checker.calls >= 1 })
}

// MARK: - Pause / resume

@Test func pauseReleasesAssertionAndBlocksEvents() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    await h.monitor.pause(for: nil)
    #expect(await h.monitor.state == .paused(until: nil))
    #expect(h.power.setPresentLog.last == false)

    await h.monitor.handleSessionEvent(.screenLocked)
    #expect(await h.monitor.state == .paused(until: nil))
    await h.monitor.handleSessionEvent(.screenUnlocked)
    #expect(await h.monitor.state == .paused(until: nil))
}

@Test func timedPauseRecordsDeadline() async {
    let h = Harness()
    await h.monitor.pause(for: 900)
    guard case .paused(let until) = await h.monitor.state else {
        Issue.record("expected paused state")
        return
    }
    #expect(until != nil)
}

@Test func resumeTriggersImmediateCheck() async {
    let h = Harness()
    await h.monitor.pause(for: nil)
    await h.monitor.resume()
    #expect(await h.monitor.state == .initializing)
    #expect(await eventually { await h.checker.calls >= 1 })
}

@Test func resumeIgnoredWhenNotPaused() async {
    let h = Harness()
    await h.monitor.applyCheckResult(.face)
    await h.monitor.resume()
    #expect(await h.monitor.state == .present)
}

// MARK: - End-to-end through performCheck

@Test func scheduledCheckAppliesCheckerResult() async {
    let h = Harness(checkerMode: .result(.face))
    await h.monitor.start()
    #expect(await eventually { await h.monitor.state == .present })
    #expect(h.power.setPresentLog.last == true)
}

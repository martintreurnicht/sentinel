import Foundation
import IOKit.pwr_mgt

/// Owns the IOKit power assertions that keep the display awake while the user is present.
///
/// Two mechanisms are needed:
/// - `PreventUserIdleDisplaySleep` blocks idle display sleep while held.
/// - `IOPMAssertionDeclareUserActivity` resets the user-idle timers that drive the
///   screensaver / lock-after-inactivity path, which the assertion alone does not cover.
final class PowerAssertionController: PowerAsserting, @unchecked Sendable {
    private let lock = NSLock()
    private var displayAssertionID = IOPMAssertionID(0)
    private var holdsAssertion = false
    private var userActivityID = IOPMAssertionID(0)

    func setPresent(_ present: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if present, !holdsAssertion {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Sentinel: user present at webcam" as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                displayAssertionID = assertionID
                holdsAssertion = true
                Log.power.notice("display sleep assertion created")
            } else {
                Log.power.error("failed to create display sleep assertion (IOReturn \(result))")
            }
        } else if !present, holdsAssertion {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
            holdsAssertion = false
            Log.power.notice("display sleep assertion released")
        }
    }

    func declareUserActivity() {
        lock.lock()
        defer { lock.unlock() }
        // Passing the previous ID back in extends the same activity assertion.
        var assertionID = userActivityID
        let result = IOPMAssertionDeclareUserActivity(
            "Sentinel presence check" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
        if result == kIOReturnSuccess {
            userActivityID = assertionID
        } else {
            Log.power.error("failed to declare user activity (IOReturn \(result))")
        }
    }
}

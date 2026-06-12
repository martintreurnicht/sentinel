import Foundation
import IOKit.ps

/// Whether the Mac is currently drawing AC power. Mockable for tests.
protocol PowerSourceMonitoring: Sendable {
    /// True when the providing power source is AC. Desktops with no battery report AC.
    /// UPS power counts as not-AC (conserve while utility power is out).
    var isOnACPower: Bool { get }
}

/// Live IOKit reads of the providing power source, plus change notifications
/// delivered on the main run loop.
final class PowerSourceObserver: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var runLoopSource: CFRunLoopSource?

    var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return true // no power source info at all means a desktop on wall power
        }
        return type as String == kIOPSACPowerValue
    }

    /// Set separately from init so the observer can be constructed before whatever
    /// consumes its change events.
    func setChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { self.handler = handler }
    }

    func start() {
        // The C callback cannot capture; the observer is held by the app delegate
        // for the process lifetime, so an unretained context pointer is safe.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<PowerSourceObserver>.fromOpaque(context).takeUnretainedValue().powerSourcesChanged()
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            Log.power.error("failed to create power source notification run loop source")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = nil
    }

    private func powerSourcesChanged() {
        Log.power.info("power source changed (on AC: \(self.isOnACPower))")
        lock.withLock { handler }?()
    }
}

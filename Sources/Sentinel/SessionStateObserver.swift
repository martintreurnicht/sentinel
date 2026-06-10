import AppKit
import Foundation

/// Forwards screen lock/unlock, system sleep/wake, and fast-user-switch transitions
/// into the monitor. The lock/unlock notification names are undocumented but have been
/// stable for over a decade; startup state is additionally seeded from
/// `CGSessionCopyCurrentDictionary`, so a missed notification self-corrects.
final class SessionStateObserver: @unchecked Sendable {
    private let handler: @Sendable (SessionEvent) -> Void
    private var observations: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(handler: @escaping @Sendable (SessionEvent) -> Void) {
        self.handler = handler
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        observe(.init("com.apple.screenIsLocked"), on: distributed, as: .screenLocked)
        observe(.init("com.apple.screenIsUnlocked"), on: distributed, as: .screenUnlocked)

        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, on: workspace, as: .willSleep)
        observe(NSWorkspace.didWakeNotification, on: workspace, as: .didWake)
        observe(NSWorkspace.sessionDidResignActiveNotification, on: workspace, as: .sessionResignedActive)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, on: workspace, as: .sessionBecameActive)
    }

    func stop() {
        for (center, token) in observations {
            center.removeObserver(token)
        }
        observations.removeAll()
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, as event: SessionEvent) {
        let handler = handler
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            Log.app.info("session notification: \(name.rawValue, privacy: .public)")
            handler(event)
        }
        observations.append((center, token))
    }
}

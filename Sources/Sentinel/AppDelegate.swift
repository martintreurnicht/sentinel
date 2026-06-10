import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var monitor: PresenceMonitor?
    private var sessionObserver: SessionStateObserver?
    private var updaterController: SPUStandardUpdaterController?
    private let power = PowerAssertionController()
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Settings.registerDefaults()
        Log.app.notice("Sentinel launched (bundle: \(Bundle.main.bundlePath, privacy: .public))")

        // Sparkle checks daily and downloads silently (SUAutomaticallyUpdate);
        // staged updates install on quit/relaunch. Scheduled updates surface in
        // the menu via the gentle-reminders delegate below, never as dialogs.
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.updaterController = updaterController

        // Defeat App Nap so the 30s poll cadence holds, without preventing idle
        // system sleep — when the user is absent the machine may sleep normally.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Webcam presence polling"
        )

        let settings = Settings()
        let checker = CameraPresenceChecker(camera: CameraService(), detector: FaceDetector(), settings: settings)
        let locker = ScreenLocker(settings: settings)
        let monitor = PresenceMonitor(
            checker: checker,
            locker: locker,
            power: power,
            config: settings,
            isScreenLocked: { ScreenLocker.isScreenLocked() }
        )
        self.monitor = monitor

        let observer = SessionStateObserver { event in
            Task { await monitor.handleSessionEvent(event) }
        }
        observer.start()
        self.sessionObserver = observer

        let statusController = StatusItemController(monitor: monitor, settings: settings, updater: updaterController)
        self.statusController = statusController

        Task {
            await monitor.setSnapshotHandler { snapshot in
                Task { @MainActor in
                    statusController.update(with: snapshot)
                }
            }
            await monitor.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Assertions die with the process anyway, but release deterministically.
        power.setPresent(false)
        sessionObserver?.stop()
        Log.app.notice("Sentinel terminating")
    }
}

// Sparkle invokes these on the main thread, but the protocol is not
// MainActor-annotated — hence nonisolated + assumeIsolated.
extension AppDelegate: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Scheduled updates surface in the menu, never as a dialog.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            if state.userInitiated {
                // A user-initiated check shows Sparkle's window; an accessory
                // app must activate for it to come to the front.
                NSApp.activate()
            } else {
                statusController?.setPendingUpdate(version: "v\(update.displayVersionString)")
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            statusController?.setPendingUpdate(version: nil)
        }
    }
}

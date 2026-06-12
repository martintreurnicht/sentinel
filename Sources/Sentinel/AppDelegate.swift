import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var monitor: PresenceMonitor?
    private var sessionObserver: SessionStateObserver?
    private var updaterController: SPUStandardUpdaterController?
    private let power = PowerAssertionController()
    private let powerSource = PowerSourceObserver()
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
        let camera = CameraService()
        let checker = CameraPresenceChecker(camera: camera, detector: PresenceDetector(), settings: settings)
        let locker = ScreenLocker(settings: settings)
        let cameraControl = CameraModeController(camera: camera, settings: settings, powerSource: powerSource)
        powerSource.setChangeHandler { cameraControl.refresh() }
        powerSource.start()
        let monitor = PresenceMonitor(
            checker: checker,
            locker: locker,
            power: power,
            cameraControl: cameraControl,
            config: settings,
            isScreenLocked: { ScreenLocker.isScreenLocked() }
        )
        self.monitor = monitor

        let observer = SessionStateObserver { event in
            Task { await monitor.handleSessionEvent(event) }
        }
        observer.start()
        self.sessionObserver = observer

        let statusController = StatusItemController(
            monitor: monitor,
            settings: settings,
            updater: updaterController,
            cameraControl: cameraControl
        )
        self.statusController = statusController

        Task {
            // start() before the snapshot handler: launching at a locked screen must
            // settle on .locked before the camera controller hears anything, or the
            // continuous session would blink on and off once at the lock screen.
            await monitor.start()
            await monitor.setSnapshotHandler { snapshot in
                Task { @MainActor in
                    statusController.update(with: snapshot)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Assertions die with the process anyway, but release deterministically.
        // (The camera session needs no explicit stop: it dies with the process.)
        power.setPresent(false)
        powerSource.stop()
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
